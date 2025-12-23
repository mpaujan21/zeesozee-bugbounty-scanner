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
        -timeout 10 -retries 2 -rl 150 \
        -H "$HEADER" -threads "$threads" \
        -json -o "$outdir/httpx.json"

    # Generate human-readable format from JSON
    jq -r '[.url, "[\(.status_code)]", "[\(.title // "")]", "[\(.webserver // "")]", "[\(.tech // [] | join(","))]", "[\(.host // "")]"] | join(" ")' \
        "$outdir/httpx.json" > "$outdir/httpx.txt" 2>/dev/null

    # Extract clean URL list
    jq -r '.url' "$outdir/httpx.json" > "$outdir/clean_httpx.txt" 2>/dev/null

    ok "Found $(wc -l < "$outdir/clean_httpx.txt" 2>/dev/null || echo 0) live hosts"
}
