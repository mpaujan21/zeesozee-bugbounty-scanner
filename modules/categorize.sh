#!/usr/bin/env bash
# shellcheck shell=bash

categorize_step() {
    local outdir="$1"
    ok "Categorizing URLs..."

    [[ -s "$outdir/uro.txt" ]] || { warn "No URLs found; skipping categorization."; return; }

    ensure_dir "$outdir/categorized"

    # GF patterns
    info "Running GF patterns..."
    gf php-errors < "$outdir/uro.txt" > "$outdir/categorized/php_errors.txt" 2>/dev/null

    # Extract URL components with unfurl
    info "Extracting URL components..."
    unfurl --unique keypairs < "$outdir/urls.txt" | sort -u > "$outdir/categorized/keypairs.txt" 2>/dev/null
    unfurl --unique format %d%p < "$outdir/urls.txt" | sort -u > "$outdir/categorized/paths.txt" 2>/dev/null

    # Extract JS and JSON file URLs
    info "Extracting JS and JSON file URLs..."
    awk -F'?' '
        tolower($0) ~ /\.js($|\?)/ { js[tolower($0)] = $0 }
        tolower($0) ~ /\.json($|\?)/ { json[tolower($0)] = $0 }
        END {
            for (url in js) print js[url] > "'"$outdir"'/js_unsorted.txt"
            for (url in json) print json[url] > "'"$outdir"'/categorized/json_files.txt"
        }
    ' "$outdir/urls.txt" 2>/dev/null
    sort -u "$outdir/js_unsorted.txt" > "$outdir/js.txt" 2>/dev/null
    rm -f "$outdir/js_unsorted.txt"

    # Remove empty output files
    find "$outdir/categorized" -maxdepth 1 -type f -empty -delete

    ok "Categorization completed"
}
