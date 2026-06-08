#!/usr/bin/env bash
# shellcheck shell=bash

js_step() {
    local outdir="$1" threads="${2:-50}" domain="${3:-}"

    local MAX_PARALLEL="${MAX_PARALLEL_JS:-10}"
    local MAX_JS_FILES="${MAX_JS_FILES:-0}"

    [[ -s "$outdir/js.txt" ]] || { warn "No JS URLs collected; skipping JS analysis."; return; }

    ok "Starting JavaScript analysis..."
    ensure_dir "$outdir/js/files"
    ensure_dir "$outdir/js/analysis"

    local js_count
    js_count=$(wc -l < "$outdir/js.txt")

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
    info "Downloading and scanning $js_count JavaScript files ($MAX_PARALLEL_DOWNLOAD hosts parallel)..."

    # Temp dirs for per-file scan results (avoid write races between parallel workers)
    local jsl_urls_dir="$outdir/js/analysis/.jsl_urls"
    local jsl_sec_dir="$outdir/js/analysis/.jsl_sec"
    local lf_dir="$outdir/js/analysis/.lf_tmp"
    ensure_dir "$jsl_urls_dir"
    ensure_dir "$jsl_sec_dir"
    ensure_dir "$lf_dir"

    # Atomic progress counter via flock
    local counter_file="$outdir/js/.progress_count"
    local lock_file="$outdir/js/.progress.lock"
    echo 0 > "$counter_file"
    local total=$js_count

    # Bucket URLs by host — sequential within each host avoids CF/rate-limit blocks
    local hosts_dir="$outdir/js/.by_host"
    ensure_dir "$hosts_dir"
    while read -r js_url; do
        [[ -z "$js_url" ]] && continue
        local host_key
        host_key=$(printf '%s' "$js_url" | sed -E 's|https?://([^/]+).*|\1|' | tr '/:' '__')
        printf '%s\n' "$js_url" >> "$hosts_dir/$host_key.list"
    done < "$js_download_input"

    # Per-host worker: download then scan each file immediately (no wait-all-then-scan)
    for host_file in "$hosts_dir"/*.list; do
        [[ -f "$host_file" ]] || continue
        (
            while read -r js_url; do
                [[ -z "$js_url" ]] && continue
                local js_domain js_basename js_hash js_filename js_path
                js_domain=$(echo "$js_url" | sed -E 's|https?://([^/]+).*|\1|' | tr '.:' '_')
                js_basename=$(echo "$js_url" | sed 's/\?.*//; s|.*/||')
                [[ "$js_basename" != *.* ]] && js_basename="${js_basename:-index}.js"
                js_hash=$(echo "$js_url" | md5sum | cut -c1-8)
                js_filename="${js_domain}_${js_hash}_${js_basename}"
                js_path="$outdir/js/files/$js_filename"

                curl --max-time 30 -sL -H "$HEADER" "$js_url" -o "$js_path" 2>/dev/null

                local jsl_urls=0 jsl_sec=0 lf_count=0

                if [[ -s "$js_path" ]]; then
                    # jsluice — scan immediately after download
                    if command -v jsluice >/dev/null 2>&1; then
                        jsluice urls "$js_path" 2>/dev/null \
                            | jq -r '.url // empty' 2>/dev/null \
                            > "$jsl_urls_dir/${js_hash}.txt"
                        jsluice secrets "$js_path" 2>/dev/null \
                            > "$jsl_sec_dir/${js_hash}.txt"
                        jsl_urls=$(wc -l < "$jsl_urls_dir/${js_hash}.txt" 2>/dev/null || echo 0)
                        jsl_sec=$(wc -l < "$jsl_sec_dir/${js_hash}.txt" 2>/dev/null || echo 0)
                        [[ $jsl_urls -eq 0 ]] && rm -f "$jsl_urls_dir/${js_hash}.txt"
                        [[ $jsl_sec  -eq 0 ]] && rm -f "$jsl_sec_dir/${js_hash}.txt"
                    fi

                    # LinkFinder — scan immediately after download
                    python3 "${TOOLS:-$HOME/tools}/LinkFinder/linkfinder.py" \
                        -i "$js_path" -o cli \
                        > "$lf_dir/${js_hash}.txt" 2>/dev/null
                    lf_count=$(wc -l < "$lf_dir/${js_hash}.txt" 2>/dev/null || echo 0)
                    [[ $lf_count -eq 0 ]] && rm -f "$lf_dir/${js_hash}.txt"
                fi

                # Atomic counter increment + progress bar (serialized by lock)
                (
                    flock -x 9
                    local v width filled empty bar
                    v=$(cat "$counter_file" 2>/dev/null || echo 0)
                    v=$((v + 1))
                    echo "$v" > "$counter_file"
                    width=40
                    filled=$(( v * width / total ))
                    empty=$(( width - filled ))
                    bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
                    printf '\r\033[KJS: [%s] %d/%d' "$bar" "$v" "$total" >&2
                ) 9>"$lock_file"

            done < "$host_file"
        ) &
        [[ $(jobs -r -p | wc -l) -ge $MAX_PARALLEL_DOWNLOAD ]] && wait -n 2>/dev/null
    done
    wait_jobs "js-download-scan"
    printf '\n' >&2
    rm -rf "$hosts_dir"

    # Append newly processed URLs to manifest
    sort -u "$js_download_input" >> "$seen_manifest"
    sort -u "$seen_manifest" -o "$seen_manifest"
    rm -f "$outdir/js/js_new.txt" "$counter_file" "$lock_file"

    local downloaded
    downloaded=$(find "$outdir/js/files" -name "*.js" -size +0 2>/dev/null | wc -l)
    ok "Downloaded and scanned $downloaded JavaScript files"

    # Source maps
    info "Checking for source maps..."
    if [[ -s "$outdir/categorized/sourcemaps.txt" ]]; then
        local map_count
        map_count=$(wc -l < "$outdir/categorized/sourcemaps.txt")
        warn "Found $map_count source map files (may contain original source code)"
        cp "$outdir/categorized/sourcemaps.txt" "$outdir/js/analysis/sourcemaps.txt"
    fi

    # Combine jsluice results from per-file temp dirs
    if command -v jsluice >/dev/null 2>&1; then
        cat "$jsl_urls_dir"/*.txt 2>/dev/null | sort -u > "$outdir/js/analysis/jsluice_urls.txt"
        cat "$jsl_sec_dir"/*.txt  2>/dev/null          > "$outdir/js/analysis/jsluice_secrets.txt"
        rm -rf "$jsl_urls_dir" "$jsl_sec_dir"

        if [[ -n "$domain" && -s "$outdir/js/analysis/jsluice_urls.txt" ]]; then
            local escaped_domain
            escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
            grep -E "https?://([^/]*\.)?${escaped_domain}(/|$|:)" \
                "$outdir/js/analysis/jsluice_urls.txt" \
                | sort -u > "$outdir/js/analysis/jsluice_urls_scope.txt"
            mv "$outdir/js/analysis/jsluice_urls_scope.txt" "$outdir/js/analysis/jsluice_urls.txt"
        fi

        [[ ! -s "$outdir/js/analysis/jsluice_urls.txt" ]]    && rm -f "$outdir/js/analysis/jsluice_urls.txt"
        if [[ -s "$outdir/js/analysis/jsluice_secrets.txt" ]]; then
            warn "jsluice: $(wc -l < "$outdir/js/analysis/jsluice_secrets.txt") potential secrets found"
        else
            rm -f "$outdir/js/analysis/jsluice_secrets.txt"
        fi
        ok "jsluice found $(wc -l < "$outdir/js/analysis/jsluice_urls.txt" 2>/dev/null || echo 0) in-scope URLs"
    fi

    # Combine LinkFinder results from per-file temp dirs
    cat "$lf_dir"/*.txt 2>/dev/null | sort -fu > "$outdir/js/analysis/linkfinder.txt"
    rm -rf "$lf_dir"
    [[ ! -s "$outdir/js/analysis/linkfinder.txt" ]] && rm -f "$outdir/js/analysis/linkfinder.txt"
    ok "LinkFinder found $(wc -l < "$outdir/js/analysis/linkfinder.txt" 2>/dev/null || echo 0) endpoints"

    # Trufflehog — directory scan, runs after all files downloaded
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

    # Titus — secrets scan with 487 rules + risk scoring (alongside trufflehog)
    if command -v titus >/dev/null 2>&1 && is_tool_enabled ENABLE_TITUS; then
        info "Scanning for secrets (titus, 487 rules)..."
        local titus_ds="$outdir/js/analysis/titus.ds"
        local titus_validate=()
        is_tool_enabled ENABLE_TITUS_VALIDATE && titus_validate=(--validate)

        # scan --format json dumps raw matches (no Score/file_path); severity lives
        # on Finding.Score, only surfaced via `report --format json` — so two steps.
        titus scan "$outdir/js/files" \
            --datastore "$titus_ds" \
            "${titus_validate[@]}" \
            2>/dev/null >/dev/null
        titus report --datastore "$titus_ds" --format json \
            2>/dev/null > "$outdir/js/analysis/titus.json"

        if [[ -s "$outdir/js/analysis/titus.json" ]]; then
            jq -r '.[] |
                (.Score.SuggestedSeverity // "unknown") as $sev |
                (.Score.Final // 0) as $score |
                (.Matches[0].RuleName // .RuleID) as $rule |
                (.Matches[0].FilePath // "unknown") as $file |
                (.Matches[0].validation_result.status // "unvalidated") as $val |
                "\($rule): \($sev)/\($score) in \($file) [\($val)]"' \
                "$outdir/js/analysis/titus.json" 2>/dev/null \
                | sort -u > "$outdir/js/analysis/titus.txt"
            [[ ! -s "$outdir/js/analysis/titus.txt" ]] && rm -f "$outdir/js/analysis/titus.txt"
            local titus_count
            titus_count=$(wc -l < "$outdir/js/analysis/titus.txt" 2>/dev/null || echo 0)
            [[ $titus_count -gt 0 ]] && warn "Titus: $titus_count potential secrets found!" \
                                     || ok "Titus: no secrets found"
        else
            rm -f "$outdir/js/analysis/titus.json"
            ok "Titus: no secrets found"
        fi
        rm -rf "$titus_ds"
    fi

    # JShunter — URL-list based, runs after all downloads complete
    if [[ "${ENABLE_JSHUNTER:-true}" == "true" ]] && command -v jshunter >/dev/null 2>&1; then
        info "Running JShunter (JWT/Firebase/GraphQL/params)..."
        local jh_raw="$outdir/js/analysis/jshunter_raw.json"

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

        jshunter -l "$js_input" \
            -fo -q -k \
            -t "$threads" -R 100 -T 30 -y 2 \
            -H "$HEADER" \
            -P \
            2>/dev/null | sort -u > "$outdir/js/analysis/jshunter_params.txt"
        [[ ! -s "$outdir/js/analysis/jshunter_params.txt" ]] && rm -f "$outdir/js/analysis/jshunter_params.txt"

        local jh_jwt jh_fb jh_gql jh_params
        jh_jwt=$(wc -l "$outdir/js/analysis/jshunter_jwt.txt" 2>/dev/null | awk '{print $1}'); jh_jwt=${jh_jwt:-0}
        jh_fb=$(wc -l "$outdir/js/analysis/jshunter_firebase.txt" 2>/dev/null | awk '{print $1}'); jh_fb=${jh_fb:-0}
        jh_gql=$(wc -l "$outdir/js/analysis/jshunter_graphql.txt" 2>/dev/null | awk '{print $1}'); jh_gql=${jh_gql:-0}
        jh_params=$(wc -l "$outdir/js/analysis/jshunter_params.txt" 2>/dev/null | awk '{print $1}'); jh_params=${jh_params:-0}
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

    rm -rf "$outdir/js/files" "$outdir/js_limited.txt"
    ok "Cleaned up raw JS files to save storage"
}
