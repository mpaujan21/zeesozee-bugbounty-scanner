#!/usr/bin/env bash
# shellcheck shell=bash

urls_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Discovering URLs..."
    ensure_dir "$outdir/urls"
    [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live subdomains; skipping URL discovery."; return; }
    
    (
        command -v waybackurls >/dev/null && { info "Running waybackurls"; cat "$outdir/clean_httpx.txt" | waybackurls | sort -u > "$outdir/urls/waybackurls.txt" & }
        command -v gau >/dev/null && { info "Running gau"; cat "$outdir/clean_httpx.txt" | gau --threads "$threads" --blacklist png,jpg,gif,jpeg,css,tif,tiff,ttf,woff,woff2,ico > "$outdir/urls/gau.txt" & }
        command -v katana >/dev/null && { info "Running katana"; katana -silent -nc -jc -fs fqdn -list "$outdir/clean_httpx.txt" -f url -ef jpg,jpeg,gif,css,tif,tiff,png,ttf,woff,woff2,ico -H "$HEADER" -o "$outdir/urls/katana.txt" & }
        wait
    ) 2>/dev/null
    
    cat "$outdir"/urls/*.txt 2>/dev/null | sort -u > "$outdir/urls.txt"
    ok "Found $(wc -l < "$outdir/urls.txt" 2>/dev/null || echo 0) unique URLs"
    
    info "Cleaning and optimizing URLs..."
    uro -i "$outdir/urls.txt" -o "$outdir/uro.txt"
}
