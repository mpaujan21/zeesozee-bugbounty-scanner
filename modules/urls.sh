#!/usr/bin/env bash
# shellcheck shell=bash

# Blacklist extensions (customize as needed)
BLACKLIST="png,jpg,gif,jpeg,css,tif,tiff,ttf,woff,woff2,ico,svg,webp,mp4,mp3,avi,mov"

urls_step() {
    local outdir="$1" threads="${2:-50}" domain="$3"
    ok "Discovering URLs..."
    ensure_dir "$outdir/urls"

    [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live subdomains; skipping URL discovery."; return; }

    # Passive URL discovery (parallel)
    (
        info "Running waybackurls"
        waybackurls < "$outdir/clean_httpx.txt" > "$outdir/urls/waybackurls.txt" 2>/dev/null &

        info "Running waymore"
        waymore -i "$domain" -mode U -oU "$outdir/urls/waymore.txt" 2>/dev/null &

        info "Running gau"
        gau -l "$outdir/clean_httpx.txt" --threads "$threads" --blacklist "$BLACKLIST" \
            -o "$outdir/urls/gau.txt" 2>/dev/null &

        wait
    )

    # Active crawling (parallel)
    (
        info "Running katana"
        katana -silent -nc -jc -fs fqdn \
            -list "$outdir/clean_httpx.txt" \
            -f url -ef "$BLACKLIST" \
            -H "$HEADER" -c "$threads" \
            -o "$outdir/urls/katana.txt" 2>/dev/null &

        info "Running gospider"
        gospider -S "$outdir/clean_httpx.txt" \
            -c "$threads" -d 2 --blacklist "$BLACKLIST" \
            -q -o "$outdir/urls/gospider_raw" 2>/dev/null && \
            cat "$outdir/urls/gospider_raw"/* 2>/dev/null | grep -oE 'https?://[^ ]+' | sort -u > "$outdir/urls/gospider.txt" &

        wait
    )

    # Combine all URLs
    cat "$outdir"/urls/waybackurls.txt \
        "$outdir"/urls/waymore.txt \
        "$outdir"/urls/gau.txt \
        "$outdir"/urls/katana.txt \
        "$outdir"/urls/gospider.txt 2>/dev/null \
        | sort -u > "$outdir/urls/all_urls.txt"

    # Scope filtering (keep only target domain)
    if [[ -n "$domain" ]]; then
        grep -E "https?://[^/]*\.?${domain}(/|$|:)" "$outdir/urls/all_urls.txt" \
            | sort -u > "$outdir/urls.txt"
        info "Filtered to $(wc -l < "$outdir/urls.txt") in-scope URLs"
    else
        cp "$outdir/urls/all_urls.txt" "$outdir/urls.txt"
    fi

    ok "Found $(wc -l < "$outdir/urls.txt" 2>/dev/null || echo 0) unique URLs"

    # Optimize with uro
    info "Optimizing URLs with uro..."
    uro -i "$outdir/urls.txt" -o "$outdir/uro.txt" 2>/dev/null

    ok "Optimized to $(wc -l < "$outdir/uro.txt" 2>/dev/null || echo 0) URLs"
}
