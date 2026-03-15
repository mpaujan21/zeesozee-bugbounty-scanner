#!/usr/bin/env bash
# shellcheck shell=bash

# Screenshot capture using gowitness

screenshots_step() {
    local outdir="$1" threads="${2:-10}"
    local ss_dir="$outdir/screenshots"
    local url_list="$outdir/.screenshot_urls.txt"

    info "Starting screenshot capture..."

    if ! command -v gowitness >/dev/null 2>&1; then
        warn "gowitness not installed, skipping screenshots"
        return 0
    fi

    # Build URL list from live hosts
    > "$url_list"

    if [[ -s "$outdir/clean_httpx.txt" ]]; then
        cat "$outdir/clean_httpx.txt" >> "$url_list"
    fi

    # Include port scan results if available
    if [[ -s "$outdir/ports/httpx_ports.txt" ]]; then
        cat "$outdir/ports/httpx_ports.txt" >> "$url_list"
    fi

    # Deduplicate
    sort -u -o "$url_list" "$url_list"

    if [[ ! -s "$url_list" ]]; then
        warn "No URLs found for screenshots"
        rm -f "$url_list"
        return 0
    fi

    local url_count
    url_count=$(wc -l < "$url_list")
    info "Capturing screenshots for $url_count URLs..."

    ensure_dir "$ss_dir"

    # Run gowitness
    gowitness scan file -f "$url_list" \
        --screenshot-path "$ss_dir" \
        --threads "$threads" \
        --timeout 15 \
        2>/dev/null || warn "gowitness had some errors (partial results may be available)"

    # Generate report if gowitness supports it
    if gowitness report generate --help >/dev/null 2>&1; then
        gowitness report generate \
            --screenshot-path "$ss_dir" \
            2>/dev/null || true
    fi

    # Clean up temp file
    rm -f "$url_list"

    # Count results
    local ss_count=0
    if [[ -d "$ss_dir" ]]; then
        ss_count=$(find "$ss_dir" -name "*.png" 2>/dev/null | wc -l)
    fi

    ok "Screenshots captured: $ss_count images saved to $ss_dir"
}
