#!/usr/bin/env bash
# shellcheck shell=bash

probe_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Probing live subdomains..."
    
    if [[ ! -s "$outdir/subdomains.txt" ]]; then
        warn "No subdomains list found, skipping probe."
        return
    fi
    
    local ndjson_tmp
    ndjson_tmp=$(mktemp)

    # Run httpx with NDJSON output to tmp
    httpx -l "$outdir/subdomains.txt" \
    -silent -nc \
    -location -ip -title -tech-detect -status-code -td \
    -favicon -cdn -web-server -cname -asn \
    -include-response-header \
    -timeout 10 -retries 2 -rl 150 \
    -H "$HEADER" -threads "$threads" \
    -json -o "$ndjson_tmp" > /dev/null 2>&1

    if ! validate_json "$ndjson_tmp" "httpx results"; then
        warn "httpx did not produce valid JSON output"
        rm -f "$ndjson_tmp"
        return 1
    fi

    # Generate human-readable txt from NDJSON
    if ! jq -r '[.url, "[\(.status_code)]", "[\(.title // "")]", "[\(.webserver // "")]", "[\(.tech // [] | join(","))]", "[\(.host // "")]"] | join(" ")' \
        "$ndjson_tmp" > "$outdir/httpx.txt" 2>/dev/null; then
        err "Failed to generate human-readable httpx output"
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

    ok "Found $(wc -l < "$outdir/clean_httpx.txt" 2>/dev/null || echo 0) live hosts"
}
