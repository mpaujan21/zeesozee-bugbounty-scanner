#!/usr/bin/env bash
# shellcheck shell=bash

report_step() {
    local outdir="$1" domain="$2"
    ok "Generating summary report..."
    
    echo "# Bug Bounty Scan Summary for $domain"
    echo
    echo "- Total Subdomains Found: $( [[ -f $outdir/subdomains.txt ]] && wc -l < "$outdir/subdomains.txt" || echo 0 )"
    echo "- Live Subdomains: $( [[ -f $outdir/clean_httpx.txt ]] && wc -l < "$outdir/clean_httpx.txt" || echo 0 )"
    echo "- Total URLs Discovered: $( [[ -f $outdir/urls.txt ]] && wc -l < "$outdir/urls.txt" || echo 0 )"
    echo "- JavaScript Files: $( [[ -f $outdir/js.txt ]] && wc -l < "$outdir/js.txt" || echo 0 )"
}
