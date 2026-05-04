#!/usr/bin/env bash
# shellcheck shell=bash

js_step() {
    local outdir="$1" threads="${2:-50}"

    # Use config values (set by scan.sh)
    local MAX_PARALLEL="${MAX_PARALLEL_JS:-10}"
    local MAX_JS_FILES="${MAX_JS_FILES:-0}"

    [[ -s "$outdir/js.txt" ]] || { warn "No JS URLs collected; skipping JS analysis."; return; }

    ok "Starting JavaScript analysis..."
    ensure_dir "$outdir/js/files"
    ensure_dir "$outdir/js/analysis"

    local js_count
    js_count=$(wc -l < "$outdir/js.txt")

    # Limit JS files if too many
    if [[ $MAX_JS_FILES -gt 0 && $js_count -gt $MAX_JS_FILES ]]; then
        warn "Too many JS files ($js_count), limiting to $MAX_JS_FILES"
        head -n "$MAX_JS_FILES" "$outdir/js.txt" > "$outdir/js_limited.txt"
        js_count=$MAX_JS_FILES
    else
        cp "$outdir/js.txt" "$outdir/js_limited.txt"
    fi

    info "Downloading $js_count JavaScript files (parallel)..."

    # Parallel download with unique filenames
    while read -r js_url; do
        [[ -z "$js_url" ]] && continue

        (
            # Create unique filename: domain_hash_basename
            local domain basename hash filename
            domain=$(echo "$js_url" | sed -E 's|https?://([^/]+).*|\1|' | tr '.:' '_')
            basename=$(echo "$js_url" | sed 's/\?.*//; s|.*/||')
            hash=$(echo "$js_url" | md5sum | cut -c1-8)
            filename="${domain}_${hash}_${basename}"

            # Download only — no prettier here
            curl --max-time 30 -sL -H "$HEADER" "$js_url" -o "$outdir/js/files/$filename" 2>/dev/null
        ) &

        # Limit parallel jobs
        [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL ]] && wait -n 2>/dev/null
    done < "$outdir/js_limited.txt"
    wait_jobs "js-download"

    # Count downloaded files
    local downloaded
    downloaded=$(find "$outdir/js/files" -name "*.js" -size +0 2>/dev/null | wc -l)
    ok "Downloaded $downloaded JavaScript files"


    # Check for source maps
    info "Checking for source maps..."
    if [[ -s "$outdir/categorized/sourcemaps.txt" ]]; then
        local map_count
        map_count=$(wc -l < "$outdir/categorized/sourcemaps.txt")
        warn "Found $map_count source map files (may contain original source code)"
        cp "$outdir/categorized/sourcemaps.txt" "$outdir/js/analysis/sourcemaps.txt"
    fi

    # Extract endpoints with jsluice (preferred, faster)
    info "Extracting endpoints and secrets..."
    if command -v jsluice >/dev/null 2>&1; then
        info "Running jsluice..."
        find "$outdir/js/files" -name "*.js" -size +0 -exec jsluice urls {} \; 2>/dev/null \
            | jq -r '.url // empty' 2>/dev/null \
            | sort -u > "$outdir/js/analysis/jsluice_urls.txt"

        find "$outdir/js/files" -name "*.js" -size +0 -exec jsluice secrets {} \; 2>/dev/null \
            > "$outdir/js/analysis/jsluice_secrets.txt"

        [[ ! -s "$outdir/js/analysis/jsluice_urls.txt" ]] && rm -f "$outdir/js/analysis/jsluice_urls.txt"
        [[ ! -s "$outdir/js/analysis/jsluice_secrets.txt" ]] && rm -f "$outdir/js/analysis/jsluice_secrets.txt"

        ok "jsluice found $(wc -l < "$outdir/js/analysis/jsluice_urls.txt" 2>/dev/null || echo 0) URLs"
    fi

    # Extract endpoints with LinkFinder (parallel)
    info "Running LinkFinder..."
    local lf_tmpdir="$outdir/js/analysis/.lf_tmp"
    ensure_dir "$lf_tmpdir"

    find "$outdir/js/files" -name "*.js" -size +0 2>/dev/null | while read -r jsfile; do
        (
            local fname
            fname=$(basename "$jsfile")
            python3 "${TOOLS:-$HOME/tools}/LinkFinder/linkfinder.py" -i "$jsfile" -o cli \
                > "$lf_tmpdir/$fname.txt" 2>/dev/null
        ) &
        [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL ]] && wait -n 2>/dev/null
    done
    wait_jobs "linkfinder"

    # Combine all LinkFinder results
    cat "$lf_tmpdir"/*.txt 2>/dev/null | sort -fu > "$outdir/js/analysis/linkfinder.txt"
    rm -rf "$lf_tmpdir"
    ok "LinkFinder found $(wc -l < "$outdir/js/analysis/linkfinder.txt" 2>/dev/null || echo 0) endpoints"

    # Scan for secrets with trufflehog
    info "Scanning for secrets (trufflehog)..."
    trufflehog filesystem \
        --directory="$outdir/js/files" \
        --only-verified \
        --json 2>/dev/null > "$outdir/js/analysis/trufflehog.json"

    if [[ -s "$outdir/js/analysis/trufflehog.json" ]]; then
        jq -r 'select(.Raw) | "\(.DetectorName): \(.Raw[:50])... in \(.SourceMetadata.Data.Filesystem.file)"' \
            "$outdir/js/analysis/trufflehog.json" 2>/dev/null \
            > "$outdir/js/analysis/trufflehog.txt"
        [[ ! -s "$outdir/js/analysis/trufflehog.txt" ]] && rm -f "$outdir/js/analysis/trufflehog.txt"
        local secrets_count
        secrets_count=$(wc -l < "$outdir/js/analysis/trufflehog.txt" 2>/dev/null || echo 0)
        [[ $secrets_count -gt 0 ]] && warn "Found $secrets_count potential secrets!" || ok "No verified secrets found"
    else
        rm -f "$outdir/js/analysis/trufflehog.json"
        ok "No verified secrets found"
    fi

    # JShunter — JWT tokens, Firebase configs, GraphQL endpoints, hidden params
    if [[ "${ENABLE_JSHUNTER:-true}" == "true" ]] && command -v jshunter >/dev/null 2>&1; then
        info "Running JShunter (JWT/Firebase/GraphQL/params)..."
        local jh_raw="$outdir/js/analysis/jshunter_raw.json"

        # Pass 1: JSON mode — JWT, Firebase, GraphQL (stdout is JSON, -o writes plain text so avoid it)
        jshunter -l "$outdir/js_limited.txt" \
            -j -fo -q -k \
            -t "$threads" -R 100 -T 30 -y 2 \
            -H "$HEADER" \
            -x -F -g \
            2>/dev/null > "$jh_raw"

        if [[ -s "$jh_raw" ]]; then
            # jq -s slurps multiple JSON objects (one per URL) into array
            jq -rs '[.[].matches["JWT Token"]? | arrays | .[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_jwt.txt"
            jq -rs '[.[] | .matches | ((.["Firebase"]? // []), (.["Firebase Url"]? // [])) | .[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_firebase.txt"
            jq -rs '[.[].matches | to_entries[] | select(.key | startswith("GraphQL")) | .value[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_graphql.txt"
            find "$outdir/js/analysis" -name "jshunter_*.txt" -size 0 -delete 2>/dev/null
        fi
        rm -f "$jh_raw"

        # Pass 2: plain text — hidden params (-P always prints to stdout, ignores -j)
        jshunter -l "$outdir/js_limited.txt" \
            -fo -q -k \
            -t "$threads" -R 100 -T 30 -y 2 \
            -H "$HEADER" \
            -P \
            2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_params.txt"
        [[ ! -s "$outdir/js/analysis/jshunter_params.txt" ]] && rm -f "$outdir/js/analysis/jshunter_params.txt"

        local jh_jwt jh_fb jh_gql jh_params
        jh_jwt=$(wc -l < "$outdir/js/analysis/jshunter_jwt.txt" 2>/dev/null || echo 0)
        jh_fb=$(wc -l < "$outdir/js/analysis/jshunter_firebase.txt" 2>/dev/null || echo 0)
        jh_gql=$(wc -l < "$outdir/js/analysis/jshunter_graphql.txt" 2>/dev/null || echo 0)
        jh_params=$(wc -l < "$outdir/js/analysis/jshunter_params.txt" 2>/dev/null || echo 0)
        ok "JShunter: ${jh_jwt} JWT, ${jh_fb} Firebase, ${jh_gql} GraphQL, ${jh_params} hidden params"
        [[ $jh_fb -gt 0 ]] && warn "Firebase configs found — verify DB rules / API key scope!"
    fi

    # Combine all discovered endpoints
    cat "$outdir/js/analysis/jsluice_urls.txt" \
        "$outdir/js/analysis/linkfinder.txt" 2>/dev/null \
        | sort -u > "$outdir/js/analysis/all_endpoints.txt"
    [[ ! -s "$outdir/js/analysis/all_endpoints.txt" ]] && rm -f "$outdir/js/analysis/all_endpoints.txt"
    rm -f "$outdir/js/analysis/jsluice_urls.txt" "$outdir/js/analysis/linkfinder.txt"

    ok "JavaScript analysis completed - $(wc -l < "$outdir/js/analysis/all_endpoints.txt" 2>/dev/null || echo 0) total endpoints"

    # Remove raw JS files — analysis results are in js/analysis/
    rm -rf "$outdir/js/files" "$outdir/js_limited.txt"
    ok "Cleaned up raw JS files to save storage"
}
