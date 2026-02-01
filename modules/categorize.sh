#!/usr/bin/env bash
# shellcheck shell=bash

categorize_step() {
    local outdir="$1"
    ok "Categorizing URLs..."
    
    [[ -s "$outdir/uro.txt" ]] || { warn "No URLs found; skipping categorization."; return; }
    
    ensure_dir "$outdir/categorized"
    
    # GF patterns (parallel)
    info "Running GF patterns..."
    (
        gf sqli < "$outdir/uro.txt" > "$outdir/categorized/sqli.txt" &
        gf xss < "$outdir/uro.txt" > "$outdir/categorized/xss.txt" &
        gf ssrf < "$outdir/uro.txt" > "$outdir/categorized/ssrf.txt" &
        gf redirect < "$outdir/uro.txt" > "$outdir/categorized/redirect.txt" &
        gf rce < "$outdir/uro.txt" > "$outdir/categorized/rce.txt" &
        gf lfi < "$outdir/uro.txt" > "$outdir/categorized/lfi.txt" &
        gf idor < "$outdir/uro.txt" > "$outdir/categorized/idor.txt" &
        gf ssti < "$outdir/uro.txt" > "$outdir/categorized/ssti.txt" &
        gf interestingparams < "$outdir/uro.txt" > "$outdir/categorized/params.txt" &
        gf debug_logic < "$outdir/uro.txt" > "$outdir/categorized/debug.txt" &
        gf upload-fields < "$outdir/uro.txt" > "$outdir/categorized/upload.txt" &
        gf cors < "$outdir/uro.txt" > "$outdir/categorized/cors.txt" &
        gf aws-keys < "$outdir/uro.txt" > "$outdir/categorized/aws.txt" &
        gf php-errors < "$outdir/uro.txt" > "$outdir/categorized/php_errors.txt" &
        wait
    ) 2>/dev/null
    
    # Report counts
    info "GF pattern results:"
    for f in "$outdir/categorized"/*.txt; do
        [[ -s "$f" ]] && {
            local name count
            name=$(basename "$f" .txt)
            count=$(wc -l < "$f")
            [[ $count -gt 0 ]] && info "  $name: $count URLs"
        }
    done
    
    # Extract URL components with unfurl
    info "Extracting URL components..."
    unfurl --unique keys < "$outdir/urls.txt" > "$outdir/categorized/keys.txt" 2>/dev/null
    unfurl --unique keypairs < "$outdir/urls.txt" > "$outdir/categorized/keypairs.txt" 2>/dev/null
    unfurl --unique values < "$outdir/urls.txt" > "$outdir/categorized/values.txt" 2>/dev/null
    unfurl --unique format %d%p < "$outdir/urls.txt" > "$outdir/categorized/paths.txt" 2>/dev/null
    unfurl --unique domains < "$outdir/urls.txt" > "$outdir/categorized/domains.txt" 2>/dev/null
    
    # Extract JavaScript, JSON, and source map files (optimized: single awk pass)
    info "Extracting JavaScript, JSON, and source map URLs..."
    awk -F'?' '
        tolower($0) ~ /\.js($|\?)/ { js[tolower($0)] = $0 }
        tolower($0) ~ /\.json($|\?)/ { json[tolower($0)] = $0 }
        tolower($0) ~ /\.map($|\?)/ { map[tolower($0)] = $0 }
        END {
            for (url in js) print js[url] > "'"$outdir"'/js.txt"
            for (url in json) print json[url] > "'"$outdir"'/categorized/json_files.txt"
            for (url in map) print map[url] > "'"$outdir"'/categorized/sourcemaps.txt"
        }
    ' "$outdir/urls.txt" 2>/dev/null

    ok "Found $(wc -l < "$outdir/js.txt" 2>/dev/null || echo 0) JavaScript files"
    
    ok "Categorization completed"
}
