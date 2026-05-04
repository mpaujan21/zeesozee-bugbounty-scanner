#!/usr/bin/env bash
# shellcheck shell=bash

probe_step() {
    local outdir="$1" threads="${2:-50}" domain="${3:-}"
    ok "Probing live subdomains..."

    if [[ ! -s "$outdir/subdomains.txt" ]]; then
        warn "No subdomains list found, skipping probe."
        return
    fi

    local ndjson_tmp
    ndjson_tmp=$(mktemp)

    httpx -l "$outdir/subdomains.txt" \
        -silent -nc \
        -ports "${HTTPX_PORTS:-80,443,8080,8443,8000,3000,8888,9090,4443,5000}" \
        -follow-redirects \
        -location -ip -title -tech-detect -status-code \
        -favicon -cdn -web-server -cname -asn \
        -hash sha256 \
        -include-response-header \
        -timeout 10 -retries 2 -rl 150 \
        -H "$HEADER" -threads "$threads" \
        -json -o "$ndjson_tmp" > /dev/null 2>&1

    if ! validate_json "$ndjson_tmp" "httpx results"; then
        warn "httpx did not produce valid JSON output"
        rm -f "$ndjson_tmp"
        return 1
    fi

    # Extract clean URL list
    if ! jq -r '.url' "$ndjson_tmp" > "$outdir/clean_httpx.txt" 2>/dev/null; then
        err "Failed to extract URLs from httpx output"
        rm -f "$ndjson_tmp"
        return 1
    fi

    # Convert NDJSON → pretty JSON array (single source of truth)
    jq -s '.' "$ndjson_tmp" > "$outdir/httpx_pretty.json" 2>/dev/null
    rm -f "$ndjson_tmp"

    # CDN hosts (de-prioritize for testing)
    jq -r '.[] | select(.cdn == true) | .url' "$outdir/httpx_pretty.json" \
        2>/dev/null | sort -u > "$outdir/cdn_hosts.txt"
    [[ ! -s "$outdir/cdn_hosts.txt" ]] && rm -f "$outdir/cdn_hosts.txt"

    # Shared IPs (≥2 non-CDN subdomains → same IP = vhost candidates)
    jq -r '.[] | select(.cdn == null or .cdn == false) | .a[0] // .ip // empty' \
        "$outdir/httpx_pretty.json" 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort | uniq -c | sort -rn \
        | awk '$1 >= 2 {print $2, $1}' > "$outdir/shared_ips.txt"
    [[ ! -s "$outdir/shared_ips.txt" ]] && rm -f "$outdir/shared_ips.txt"

    ok "Found $(wc -l < "$outdir/clean_httpx.txt" 2>/dev/null || echo 0) live hosts"

    # VHost sweep — only if ffuf available, shared IPs exist, and domain known
    if is_tool_enabled "ENABLE_VHOST" \
        && command -v ffuf >/dev/null 2>&1 \
        && [[ -s "$outdir/shared_ips.txt" && -n "$domain" ]]; then

        info "Running vhost discovery on shared IPs..."
        mkdir -p "$outdir/vhost"

        # Wordlist from leftmost subdomain labels
        awk -F. '{print $1}' "$outdir/subdomains.txt" | sort -u > "$outdir/vhost/wordlist.txt"

        local max_ips="${VHOST_MAX_IPS:-5}" i=0
        while IFS=' ' read -r ip _; do
            [[ $i -ge $max_ips ]] && break
            local safe_ip="${ip//\//_}"
            ffuf -u "http://${ip}/" \
                -H "Host: FUZZ.${domain}" \
                -w "$outdir/vhost/wordlist.txt" \
                -mc all -fc 404 \
                -ac \
                -t "$threads" -timeout 10 -rate 100 \
                -of json -o "$outdir/vhost/${safe_ip}.json" \
                -s 2>/dev/null &
            i=$((i + 1))
        done < "$outdir/shared_ips.txt"
        wait_jobs "vhost"

        # Aggregate hits
        local discovered="$outdir/vhost/discovered.txt"
        for f in "$outdir/vhost"/*.json; do
            [[ -f "$f" ]] || continue
            local tmp_out
            tmp_out=$(mktemp)
            extract_ffuf_results "$f" "$tmp_out" 2>/dev/null && cat "$tmp_out"
            rm -f "$tmp_out"
        done | sort -u > "$discovered"
        [[ ! -s "$discovered" ]] && rm -f "$discovered"

        local vhost_count
        vhost_count=$(wc -l < "$discovered" 2>/dev/null || echo 0)
        ok "VHost sweep: $vhost_count vhosts discovered"
    fi
}
