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
            { waymore -i "$domain" -n -mode U -oU "$tmpdir/waymore.txt" >/dev/null 2>&1; } || true &
        else
            touch "$tmpdir/waymore.txt"
        fi

        if is_tool_enabled "ENABLE_GAU"; then
            info "Running gau"
            { awk -F/ '/^https?:/{split($3, a, ":"); print a[1]}' "$outdir/clean_httpx.txt" | sort -u \
                | gau --subs --threads "$threads" --blacklist "$BLACKLIST" 2>/dev/null \
                | sort -u > "$tmpdir/gau.txt"; } || true &
        else
            touch "$tmpdir/gau.txt"
        fi

        wait_jobs "passive-urls"
    )

    info "waybackurls: $(wc -l < "$tmpdir/waybackurls.txt" 2>/dev/null || echo 0) URLs"
    info "waymore: $(wc -l < "$tmpdir/waymore.txt" 2>/dev/null || echo 0) URLs"
    info "gau: $(wc -l < "$tmpdir/gau.txt" 2>/dev/null || echo 0) URLs"

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

        if is_tool_enabled "ENABLE_GOSPIDER"; then
            info "Running gospider"
            (
                local gs_out="$tmpdir/gospider_raw"
                gospider -S "$outdir/clean_httpx.txt" \
                    -c "$threads" -d 2 \
                    --blacklist "$BLACKLIST_REGEX" \
                    -q -o "$gs_out" 2>/dev/null
                find "$gs_out" -type f -exec grep -hoE 'https?://[^ "]+' {} + 2>/dev/null \
                    | sort -u > "$tmpdir/gospider.txt"
                rm -rf "$gs_out"
            ) &
        else
            touch "$tmpdir/gospider.txt"
        fi

        wait_jobs "active-urls"
    )

    info "katana: $(wc -l < "$tmpdir/katana.txt" 2>/dev/null || echo 0) URLs"
    info "gospider: $(wc -l < "$tmpdir/gospider.txt" 2>/dev/null || echo 0) URLs"

    # Combine + scope filter in single pipeline
    if [[ -n "$domain" ]]; then
        local escaped_domain
        escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
        sort -u "$tmpdir"/*.txt 2>/dev/null \
            | grep -E "https?://([^/]*\.)?${escaped_domain}(/|$|:)" \
            > "$outdir/urls.txt"
        info "Filtered to $(wc -l < "$outdir/urls.txt") in-scope URLs"
    else
        sort -u "$tmpdir"/*.txt 2>/dev/null > "$outdir/urls.txt"
    fi

    rm -rf "$tmpdir"

    ok "Found $(wc -l < "$outdir/urls.txt" 2>/dev/null || echo 0) unique URLs"

    # Optimize with uro
    info "Optimizing URLs with uro..."
    uro -i "$outdir/urls.txt" -o "$outdir/urls_optimized.txt" 2>/dev/null

    ok "Optimized to $(wc -l < "$outdir/urls_optimized.txt" 2>/dev/null || echo 0) URLs"
}
