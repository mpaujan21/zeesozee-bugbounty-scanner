#!/usr/bin/env bash
# shellcheck shell=bash

# Blacklist extensions (customize as needed)
BLACKLIST="png,jpg,gif,jpeg,css,tif,tiff,ttf,woff,woff2,ico,svg,webp,mp4,mp3,avi,mov,eot,cur,otf,wav,ogg,flac"
BLACKLIST_REGEX="\.(png|jpg|gif|jpeg|css|tif|tiff|ttf|woff|woff2|ico|svg|webp|mp4|mp3|avi|mov|eot|cur|otf|wav|ogg|flac)(\?|$)"

urls_step() {
    local outdir="$1" threads="${2:-50}" domain="$3"
    ok "Discovering URLs..."

    [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live subdomains; skipping URL discovery."; return; }

    local tmpdir
    tmpdir=$(mktemp -d)

    # Passive URL discovery (parallel)
    (
        if is_tool_enabled "ENABLE_WAYBACKURLS"; then
            info "Running waybackurls"
            { waybackurls < "$outdir/clean_httpx.txt" 2>/dev/null | sort -u > "$tmpdir/waybackurls.txt"; } || true &
        else
            touch "$tmpdir/waybackurls.txt"
        fi

        if is_tool_enabled "ENABLE_WAYMORE"; then
            info "Running waymore"
            { waymore -i "$outdir/clean_httpx.txt" -n -mode U -oU "$tmpdir/waymore.txt" >/dev/null 2>&1; } || true &
        else
            touch "$tmpdir/waymore.txt"
        fi

        wait_jobs "passive-urls"
    )

    info "waybackurls: $(wc -l < "$tmpdir/waybackurls.txt" 2>/dev/null || echo 0) URLs"
    info "waymore: $(wc -l < "$tmpdir/waymore.txt" 2>/dev/null || echo 0) URLs"

    # Active crawling (parallel)
    (
        if is_tool_enabled "ENABLE_KATANA"; then
            info "Running katana"
            katana -silent -nc -jc -fs fqdn \
            -list "$outdir/clean_httpx.txt" \
            -f url -ef "$BLACKLIST" \
            -H "$HEADER" -c "$threads" 2>/dev/null \
            | sort -u > "$tmpdir/katana.txt" &
        else
            touch "$tmpdir/katana.txt"
        fi

        wait_jobs "active-urls"
    )

    info "katana: $(wc -l < "$tmpdir/katana.txt" 2>/dev/null || echo 0) URLs"

    # Combine + scope filter
    local raw_urls="$tmpdir/all_urls.txt"
    if [[ -n "$domain" ]]; then
        local escaped_domain
        escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
        sort -u "$tmpdir"/*.txt 2>/dev/null \
            | grep -E "https?://([^/]*\.)?${escaped_domain}(/|$|:)" \
            > "$raw_urls"
    else
        sort -u "$tmpdir"/*.txt 2>/dev/null > "$raw_urls"
    fi

    local raw_count
    raw_count=$(wc -l < "$raw_urls" 2>/dev/null || echo 0)
    info "Collected $raw_count raw URLs, probing liveness..."

    # Filter to live URLs only
    httpx -silent -mc 200,301,302,401,403 \
        -l "$raw_urls" \
        -threads "$threads" \
        -o "$outdir/urls.txt" 2>/dev/null || true

    rm -rf "$tmpdir"

    sort -u "$outdir/urls.txt" -o "$outdir/urls.txt"

    ok "Found $(wc -l < "$outdir/urls.txt" 2>/dev/null || echo 0) live URLs"

    # Deduplicate by path (strip query string) via unfurl
    info "Optimizing URLs with unfurl..."
    unfurl format '%s://%d%p' < "$outdir/urls.txt" 2>/dev/null | sort -u > "$outdir/urls_optimized.txt"

    ok "Optimized to $(wc -l < "$outdir/urls_optimized.txt" 2>/dev/null || echo 0) unique paths"
}
