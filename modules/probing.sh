#!/usr/bin/env bash
# shellcheck shell=bash

probe_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Probing live subdomains..."
    
    if [[ ! -s "$outdir/subdomains.txt" ]]; then
        warn "No subdomains list found, skipping probe."
        return
    fi
    
    # Run httpx once with JSON output
    httpx -l "$outdir/subdomains.txt" \
    -silent -nc \
    -location -ip -title -tech-detect -status-code -td \
    -favicon -cdn -web-server -cname -asn \
    -include-response-header \
    -timeout 10 -retries 2 -rl 150 \
    -H "$HEADER" -threads "$threads" \
    -json -o "$outdir/httpx.json" > /dev/null 2>&1

    # Validate JSON output
    if ! validate_json "$outdir/httpx.json" "httpx results"; then
        warn "httpx did not produce valid JSON output"
        return 1
    fi

    # Generate human-readable format from JSON
    if ! jq -r '[.url, "[\(.status_code)]", "[\(.title // "")]", "[\(.webserver // "")]", "[\(.tech // [] | join(","))]", "[\(.host // "")]"] | join(" ")' \
        "$outdir/httpx.json" > "$outdir/httpx.txt" 2>/dev/null; then
        err "Failed to generate human-readable httpx output"
        return 1
    fi

    # Extract clean URL list (all status codes — downstream modules filter as needed)
    if ! jq -r '.url' "$outdir/httpx.json" > "$outdir/clean_httpx.txt" 2>/dev/null; then
        err "Failed to extract URLs from httpx output"
        return 1
    fi

    # Keep httpx.json for downstream modules (ports.sh needs it for CDN filtering)
    ok "Found $(wc -l < "$outdir/clean_httpx.txt" 2>/dev/null || echo 0) live hosts"
}
