#!/usr/bin/env bash
# shellcheck shell=bash

# Blacklist extensions (customize as needed)
BLACKLIST="png,jpg,gif,jpeg,css,tif,tiff,ttf,woff,woff2,ico,svg,webp,mp4,mp3,avi,mov"

urls_step() {
    local outdir="$1" threads="${2:-50}" domain="$3"
    ok "Discovering URLs..."
    ensure_dir "$outdir/urls"
    
    [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live subdomains; skipping URL discovery."; return; }
    
    # Passive URL discovery (parallel, with pre-deduplication)
    (
        if is_tool_enabled "ENABLE_WAYBACKURLS"; then
            info "Running waybackurls"
            waybackurls < "$outdir/clean_httpx.txt" 2>/dev/null | sort -u > "$outdir/urls/waybackurls.txt" &
        else
            info "Skipping waybackurls (disabled in config)"
            touch "$outdir/urls/waybackurls.txt"
        fi

        if is_tool_enabled "ENABLE_WAYMORE"; then
            info "Running waymore"
            waymore -i "$domain" -n -mode U -oU "$outdir/urls/waymore.txt" >/dev/null 2>&1 &
        else
            info "Skipping waymore (disabled in config)"
            touch "$outdir/urls/waymore.txt"
        fi

        if is_tool_enabled "ENABLE_GAU"; then
            info "Running gau"
            gau -l "$outdir/clean_httpx.txt" --threads "$threads" --blacklist "$BLACKLIST" 2>/dev/null \
                | sort -u > "$outdir/urls/gau.txt" &
        else
            info "Skipping gau (disabled in config)"
            touch "$outdir/urls/gau.txt"
        fi

        wait_jobs "passive-urls"
    )

    # Active crawling (parallel, with pre-deduplication)
    (
        if is_tool_enabled "ENABLE_KATANA"; then
            info "Running katana"
            katana -silent -nc -jc -fs fqdn \
            -list "$outdir/clean_httpx.txt" \
            -f url -ef "$BLACKLIST" \
            -H "$HEADER" -c "$threads" 2>/dev/null \
            | sort -u > "$outdir/urls/katana.txt" &
        else
            info "Skipping katana (disabled in config)"
            touch "$outdir/urls/katana.txt"
        fi

        if is_tool_enabled "ENABLE_GOSPIDER"; then
            info "Running gospider"
            gospider -S "$outdir/clean_httpx.txt" \
            -c "$threads" -d 2 --blacklist "$BLACKLIST" \
            -q -o "$outdir/urls/gospider_raw" 2>/dev/null && \
            grep -hoE 'https?://[^ ]+' "$outdir/urls/gospider_raw"/* 2>/dev/null | sort -u > "$outdir/urls/gospider.txt" &
        else
            info "Skipping gospider (disabled in config)"
            touch "$outdir/urls/gospider.txt"
        fi

        wait_jobs "active-urls"
    )

    # Combine all URLs (optimized: direct sort without cat)
    sort -u "$outdir"/urls/waybackurls.txt \
        "$outdir"/urls/waymore.txt \
        "$outdir"/urls/gau.txt \
        "$outdir"/urls/katana.txt \
        "$outdir"/urls/gospider.txt \
        -o "$outdir/urls/all_urls.txt" 2>/dev/null
    
    # Scope filtering (keep only target domain)
    if [[ -n "$domain" ]]; then
        local escaped_domain
        escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
        grep -E "https?://([^/]*\.)?${escaped_domain}(/|$|:)" "$outdir/urls/all_urls.txt" \
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
