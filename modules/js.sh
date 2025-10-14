#!/usr/bin/env bash
# shellcheck shell=bash

js_step() {
    local outdir="$1"
    [[ -s "$outdir/js.txt" ]] || { warn "No JS URLs collected; skipping JS analysis."; return; }
    
    ok "Starting JavaScript analysis..."
    ensure_dir "$outdir/js"
    
    info "Downloading JavaScript files..."
    while read -r js; do
        [[ -z "$js" ]] && continue
        local name; name="$(basename "$js" | sed 's/\?.*//')"
        info "Downloading: $name"
        curl --max-time 30 -sL -H "$HEADER" -H "$HEADER2" "$js" -o "$outdir/js/$name"
        command -v prettier >/dev/null && prettier --write "$outdir/js/$name" >/dev/null 2>&1 || true
    done < "$outdir/js.txt"
    
    info "Extracting endpoints (LinkFinder)…"
    python3 "$TOOLS/LinkFinder/linkfinder.py" -i "$outdir/js/*.js" -o cli > "$outdir/js/linkfinder.txt" || true
    sort -fu "$outdir/js/linkfinder.txt" -o "$outdir/js/linkfinder.txt" || true
    
    info "Scanning JS for secrets (trufflehog)…"
    trufflehog filesystem --directory="$outdir/js" --log-level=-1 --results=verified,unknown --no-json > "$outdir/js/trufflehog.txt" || true
    
    ok "JavaScript analysis completed"
}
