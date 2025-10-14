#!/usr/bin/env bash
# shellcheck shell=bash

categorize_step() {
    local outdir="$1"
    ok "Categorizing URLs..."
    ensure_dir "$outdir/categorized"
    
    (
        info "GF patterns…"
        cat "$outdir/uro.txt" | gf sqli > "$outdir/categorized/sqli.txt" &
        cat "$outdir/uro.txt" | gf interestingparams > "$outdir/categorized/params.txt" &
        cat "$outdir/uro.txt" | gf redirect > "$outdir/categorized/redirect.txt" &
        cat "$outdir/uro.txt" | gf xss > "$outdir/categorized/xss.txt" &
        cat "$outdir/uro.txt" | gf ssrf > "$outdir/categorized/ssrf.txt" &
        cat "$outdir/uro.txt" | gf rce > "$outdir/categorized/rce.txt" &
        cat "$outdir/uro.txt" | gf lfi > "$outdir/categorized/lfi.txt" &
        wait
    ) 2>/dev/null
    
    info "Extracting URL components…"
    cat "$outdir/urls.txt" | unfurl --unique keypairs > "$outdir/categorized/keypairs.txt"
    cat "$outdir/urls.txt" | unfurl --unique keys > "$outdir/categorized/keys.txt"
    cat "$outdir/urls.txt" | unfurl --unique format %d%p > "$outdir/categorized/paths.txt"
    
    info "Extracting JavaScript URLs…"
    grep -E '\.js(\?|$)' "$outdir/urls.txt" | sort -fu > "$outdir/js.txt" || true
    sed -i '/\.js/d' "$outdir/urls.txt" 2>/dev/null || true
    sed -i '/\.js/d' "$outdir/uro.txt" 2>/dev/null || true
}
