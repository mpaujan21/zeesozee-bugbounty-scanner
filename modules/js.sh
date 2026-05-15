#!/usr/bin/env bash
# shellcheck shell=bash

js_step() {
    local outdir="$1" threads="${2:-50}" domain="${3:-}"

    # Use config values (set by scan.sh)
    local MAX_PARALLEL="${MAX_PARALLEL_JS:-10}"
    local MAX_JS_FILES="${MAX_JS_FILES:-0}"

    [[ -s "$outdir/js.txt" ]] || { warn "No JS URLs collected; skipping JS analysis."; return; }

    ok "Starting JavaScript analysis..."
    ensure_dir "$outdir/js/files"
    ensure_dir "$outdir/js/analysis"

    local js_count
    js_count=$(wc -l < "$outdir/js.txt")

    # Point to limited subset if needed, otherwise use js.txt directly
    local js_input="$outdir/js.txt"
    if [[ $MAX_JS_FILES -gt 0 && $js_count -gt $MAX_JS_FILES ]]; then
        warn "Too many JS files ($js_count), limiting to $MAX_JS_FILES"
        head -n "$MAX_JS_FILES" "$outdir/js.txt" > "$outdir/js_limited.txt"
        js_input="$outdir/js_limited.txt"
        js_count=$MAX_JS_FILES
    fi

    # Filter out already-processed URLs via persistent manifest
    local seen_manifest="$outdir/js/.seen_urls.txt"
    local js_download_input="$js_input"
    if [[ -s "$seen_manifest" ]]; then
        local js_new="$outdir/js/js_new.txt"
        comm -23 <(sort "$js_input") <(sort "$seen_manifest") > "$js_new"
        local new_count already_count
        new_count=$(wc -l < "$js_new")
        already_count=$((js_count - new_count))
        if [[ $new_count -eq 0 ]]; then
            info "All $js_count JS URLs already processed; skipping download."
            rm -f "$js_new" "$outdir/js_limited.txt"
            return
        fi
        info "JS manifest: $already_count already seen, $new_count new"
        js_download_input="$js_new"
        js_count=$new_count
    fi

    local MAX_PARALLEL_DOWNLOAD="${MAX_PARALLEL_JS_DOWNLOAD:-5}"
    info "Downloading $js_count JavaScript files (per-host serial, $MAX_PARALLEL_DOWNLOAD hosts parallel)..."

    # Bucket URLs by host so each host is downloaded sequentially (avoids CF blocks)
    local hosts_dir="$outdir/js/.by_host"
    ensure_dir "$hosts_dir"
    while read -r js_url; do
        [[ -z "$js_url" ]] && continue
        local host_key
        host_key=$(printf '%s' "$js_url" | sed -E 's|https?://([^/]+).*|\1|' | tr '/:' '__')
        printf '%s\n' "$js_url" >> "$hosts_dir/$host_key.list"
    done < "$js_download_input"

    # One worker per host — sequential curl within each worker
    for host_file in "$hosts_dir"/*.list; do
        [[ -f "$host_file" ]] || continue
        (
            while read -r js_url; do
                [[ -z "$js_url" ]] && continue
                local js_domain js_basename js_hash js_filename
                js_domain=$(echo "$js_url" | sed -E 's|https?://([^/]+).*|\1|' | tr '.:' '_')
                js_basename=$(echo "$js_url" | sed 's/\?.*//; s|.*/||')
                [[ "$js_basename" != *.* ]] && js_basename="${js_basename:-index}.js"
                js_hash=$(echo "$js_url" | md5sum | cut -c1-8)
                js_filename="${js_domain}_${js_hash}_${js_basename}"
                curl --max-time 30 -sL -H "$HEADER" "$js_url" -o "$outdir/js/files/$js_filename" 2>/dev/null
            done < "$host_file"
        ) &
        [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL_DOWNLOAD ]] && wait -n 2>/dev/null
    done
    wait_jobs "js-download"
    rm -rf "$hosts_dir"

    # Append newly processed URLs to manifest
    sort -u "$js_download_input" >> "$seen_manifest"
    sort -u "$seen_manifest" -o "$seen_manifest"
    rm -f "$outdir/js/js_new.txt"

    # Count downloaded files
    local downloaded
    downloaded=$(find "$outdir/js/files" -name "*.js" -size +0 2>/dev/null | wc -l)
    ok "Downloaded $downloaded JavaScript files"

    # Check for source maps (populated by categorize_step)
    info "Checking for source maps..."
    if [[ -s "$outdir/categorized/sourcemaps.txt" ]]; then
        local map_count
        map_count=$(wc -l < "$outdir/categorized/sourcemaps.txt")
        warn "Found $map_count source map files (may contain original source code)"
        cp "$outdir/categorized/sourcemaps.txt" "$outdir/js/analysis/sourcemaps.txt"
    fi

    # Extract endpoints and secrets with jsluice (parallel)
    info "Extracting endpoints and secrets..."
    if command -v jsluice >/dev/null 2>&1; then
        info "Running jsluice..."

        find "$outdir/js/files" -name "*.js" -size +0 -print0 2>/dev/null \
            | xargs -0 -P "$MAX_PARALLEL" -I{} jsluice urls {} 2>/dev/null \
            | jq -r '.url // empty' 2>/dev/null \
            | sort -u > "$outdir/js/analysis/jsluice_urls.txt"

        find "$outdir/js/files" -name "*.js" -size +0 -print0 2>/dev/null \
            | xargs -0 -P "$MAX_PARALLEL" -I{} jsluice secrets {} 2>/dev/null \
            > "$outdir/js/analysis/jsluice_secrets.txt"

        [[ ! -s "$outdir/js/analysis/jsluice_urls.txt" ]] && rm -f "$outdir/js/analysis/jsluice_urls.txt"

        if [[ -s "$outdir/js/analysis/jsluice_secrets.txt" ]]; then
            local jsluice_sec
            jsluice_sec=$(wc -l < "$outdir/js/analysis/jsluice_secrets.txt")
            warn "jsluice: $jsluice_sec potential secrets found"
        else
            rm -f "$outdir/js/analysis/jsluice_secrets.txt"
        fi

        # Scope-filter jsluice URLs to target domain
        if [[ -n "$domain" && -s "$outdir/js/analysis/jsluice_urls.txt" ]]; then
            local escaped_domain
            escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
            grep -E "https?://([^/]*\.)?${escaped_domain}(/|$|:)" \
                "$outdir/js/analysis/jsluice_urls.txt" \
                | sort -u > "$outdir/js/analysis/jsluice_urls_scope.txt"
            mv "$outdir/js/analysis/jsluice_urls_scope.txt" "$outdir/js/analysis/jsluice_urls.txt"
            [[ ! -s "$outdir/js/analysis/jsluice_urls.txt" ]] && rm -f "$outdir/js/analysis/jsluice_urls.txt"
        fi

        ok "jsluice found $(wc -l < "$outdir/js/analysis/jsluice_urls.txt" 2>/dev/null || echo 0) in-scope URLs"
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

        # Pass 1: JSON mode — JWT, Firebase, GraphQL
        jshunter -l "$js_input" \
            -j -fo -q -k \
            -t "$threads" -R 100 -T 30 -y 2 \
            -H "$HEADER" \
            -x -F -g \
            2>/dev/null > "$jh_raw"

        if [[ -s "$jh_raw" ]]; then
            jq -rs '[.[].matches["JWT Token"]? | arrays | .[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_jwt.txt"
            jq -rs '[.[] | .matches | ((.["Firebase"]? // []), (.["Firebase Url"]? // [])) | .[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_firebase.txt"
            jq -rs '[.[].matches | to_entries[] | select(.key | startswith("GraphQL")) | .value[]] | unique[]' \
                "$jh_raw" 2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_graphql.txt"
            find "$outdir/js/analysis" -name "jshunter_*.txt" -size 0 -delete 2>/dev/null
        fi
        rm -f "$jh_raw"

        # Pass 2: plain text — hidden params
        jshunter -l "$js_input" \
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
