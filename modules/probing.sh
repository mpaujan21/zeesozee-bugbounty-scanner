#!/usr/bin/env bash
# shellcheck shell=bash

probe_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Probing live subdomains..."
    if [[ ! -s "$outdir/subdomains.txt" ]]; then
        warn "No subdomains list found, skipping probe."
        return
    fi
    cat "$outdir/subdomains.txt" | httpx -silent -nc -location -ip -title -tech-detect -status-code -td \
    -mc 200,201,202,203,204,301,302,307,401,403,405,500 \
    -H "$HEADER" -H "$HEADER2" -threads "$threads" -o "$outdir/httpx.txt"
    awk '{print $1}' "$outdir/httpx.txt" > "$outdir/clean_httpx.txt"
    ok "Found $(wc -l < "$outdir/clean_httpx.txt" 2>/dev/null || echo 0) live subdomains"
}
