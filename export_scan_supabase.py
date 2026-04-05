#!/usr/bin/env python3

import argparse
import json
import os
import sys
import uuid
from pathlib import Path
from datetime import datetime, timezone
from typing import Any
from urllib import error, parse, request


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def load_dotenv(dotenv_path: Path) -> None:
    if not dotenv_path.exists():
        return

    for raw_line in dotenv_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if not key or key in os.environ:
            continue

        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]

        os.environ[key] = value


class SupabaseClient:
    def __init__(self, base_url: str, api_key: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        body: Any = None,
        prefer: str | None = None,
    ) -> Any:
        url = f"{self.base_url}{path}"
        if query:
            url = f"{url}?{parse.urlencode(query)}"

        data = None
        headers = {
            "apikey": self.api_key,
            "Authorization": f"Bearer {self.api_key}",
        }

        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"

        if prefer:
            headers["Prefer"] = prefer

        req = request.Request(url, data=data, headers=headers, method=method)
        try:
            with request.urlopen(req) as resp:
                raw = resp.read()
                if not raw:
                    return None
                return json.loads(raw.decode("utf-8"))
        except error.HTTPError as exc:
            payload = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Supabase {method} {path} failed: {exc.code} {payload}") from exc

    def get_program_by_name(self, program_name: str) -> dict[str, Any] | None:
        rows = self._request(
            "GET",
            "/rest/v1/programs",
            query={
                "select": "id,name",
                "name": f"eq.{program_name}",
                "limit": "1",
            },
        )
        return rows[0] if rows else None

    def create_program(self, program_name: str) -> dict[str, Any]:
        now = utc_now()
        payload = {
            "id": str(uuid.uuid4()),
            "name": program_name,
            "created_at": now,
            "updated_at": now,
        }
        rows = self._request(
            "POST",
            "/rest/v1/programs",
            body=payload,
            prefer="return=representation",
        )
        if not rows:
            raise RuntimeError("Program insert did not return a row")
        return rows[0]

    def upsert_subdomains(self, records: list[dict[str, Any]]) -> None:
        if not records:
            return
        self._request(
            "POST",
            "/rest/v1/subdomains",
            query={"on_conflict": "subdomain"},
            body=records,
            prefer="resolution=merge-duplicates,return=minimal",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Export Zee Scanner results to Supabase")
    parser.add_argument("program_name", help="Program name, matched against programs.name")
    parser.add_argument("--subs", required=True, help="Path to clean_httpx.txt or httpx.txt")
    parser.add_argument("--httpx-json", help="Path to httpx.json for richer metadata")
    parser.add_argument("--batch-size", type=int, default=500, help="Upsert batch size")
    return parser.parse_args()


def normalize_text_list(value: Any) -> list[str] | None:
    if not value:
        return None
    if isinstance(value, list):
        cleaned = [str(item).strip() for item in value if str(item).strip()]
        return cleaned or None
    return [str(value).strip()]


def normalize_json(value: Any) -> Any:
    if value in (None, "", [], {}):
        return None
    return value


def hostname_from_url(value: str) -> str:
    parsed = parse.urlparse(value.strip())
    return (parsed.hostname or value.strip()).lower()


def build_record_from_json(entry: dict[str, Any], program_id: str) -> dict[str, Any] | None:
    url = (entry.get("url") or "").strip()
    subdomain = hostname_from_url(url)
    if not subdomain:
        return None

    response_headers = entry.get("response_headers") or entry.get("header")
    server = entry.get("webserver") or entry.get("server")
    ip_addresses = normalize_text_list(entry.get("a") or entry.get("host") or entry.get("ip"))

    port_value = entry.get("port")
    ports = [port_value] if isinstance(port_value, int) else None

    now = utc_now()
    return {
        "id": str(uuid.uuid4()),
        "program_id": program_id,
        "subdomain": subdomain,
        "full_url": url or None,
        "http_status": entry.get("status_code"),
        "last_checked": now,
        "discovered_at": now,
        "technologies": normalize_json(entry.get("tech")),
        "server_info": server,
        "headers": normalize_json(response_headers),
        "ports": normalize_json(ports),
        "ip_addresses": ip_addresses,
    }


def build_record_from_url(line: str, program_id: str) -> dict[str, Any] | None:
    raw = line.strip()
    if not raw:
        return None

    url = raw.split(" ", 1)[0]
    if not url.startswith(("http://", "https://")):
        url = f"https://{url}"

    subdomain = hostname_from_url(url)
    if not subdomain:
        return None

    now = utc_now()
    return {
        "id": str(uuid.uuid4()),
        "program_id": program_id,
        "subdomain": subdomain,
        "full_url": url,
        "last_checked": now,
        "discovered_at": now,
    }


def load_records(program_id: str, subs_path: str, httpx_json_path: str | None) -> list[dict[str, Any]]:
    records_by_subdomain: dict[str, dict[str, Any]] = {}

    if httpx_json_path and os.path.exists(httpx_json_path) and os.path.getsize(httpx_json_path) > 0:
        with open(httpx_json_path, "r", encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                entry = json.loads(line)
                record = build_record_from_json(entry, program_id)
                if record:
                    records_by_subdomain[record["subdomain"]] = record

    with open(subs_path, "r", encoding="utf-8") as handle:
        for line in handle:
            record = build_record_from_url(line, program_id)
            if not record:
                continue
            existing = records_by_subdomain.get(record["subdomain"])
            if existing:
                existing["full_url"] = existing.get("full_url") or record["full_url"]
                continue
            records_by_subdomain[record["subdomain"]] = record

    return list(records_by_subdomain.values())


def chunked(items: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    return [items[index:index + size] for index in range(0, len(items), size)]


def main() -> int:
    args = parse_args()
    load_dotenv(Path(__file__).with_name(".env"))

    base_url = os.environ.get("SUPABASE_URL")
    api_key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_API_KEY")

    if not base_url:
        eprint("SUPABASE_URL is required")
        return 1
    if not api_key:
        eprint("SUPABASE_SERVICE_ROLE_KEY or SUPABASE_API_KEY is required")
        return 1
    if not os.path.exists(args.subs):
        eprint(f"Input file not found: {args.subs}")
        return 1

    client = SupabaseClient(base_url, api_key)

    program = client.get_program_by_name(args.program_name)
    if program is None:
        eprint(f"Program '{args.program_name}' not found, creating it")
        program = client.create_program(args.program_name)

    program_id = program["id"]
    records = load_records(program_id, args.subs, args.httpx_json)
    if not records:
        eprint("No subdomains to export")
        return 0

    for batch in chunked(records, args.batch_size):
        client.upsert_subdomains(batch)

    print(f"Exported {len(records)} subdomains for program '{args.program_name}' ({program_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
