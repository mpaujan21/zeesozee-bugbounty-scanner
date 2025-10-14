#!/usr/bin/env bash
# shellcheck shell=bash

subdomains_step() {
    local domain="$1" outdir="$2"
    ok "Starting Subdomain Enumeration..."
    (
        command -v subfinder >/dev/null && { info "Running subfinder"; subfinder -silent -d "$domain" -o "$outdir/subfinder.txt" & }
        command -v assetfinder >/dev/null && { info "Running assetfinder"; assetfinder --subs-only "$domain" > "$outdir/assetfinder.txt" & }
        command -v findomain   >/dev/null && { info "Running findomain"; findomain -t "$domain" -q > "$outdir/findomain.txt" & }
        wait
    ) 2>/dev/null
    
    cat "$outdir"/subfinder.txt "$outdir"/assetfinder.txt "$outdir"/findomain.txt 2>/dev/null | sort -fu > "$outdir/subdomains.txt"
    ok "Found $(wc -l < "$outdir/subdomains.txt" 2>/dev/null || echo 0) unique subdomains"
}
