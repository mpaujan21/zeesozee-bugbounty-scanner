#!/usr/bin/env bash
# shellcheck shell=bash

permutation_step() {
    local outdir="$1" threads="${2:-50}"
    local wildcard_ip=""

    ok "Performing subdomain permutation..."

    # Check for input
    if [[ ! -s "$outdir/subdomains.txt" ]]; then
        warn "No subdomains found; skipping permutations."
        return
    fi

    ensure_dir "$outdir/permutations"

    # Load wildcard IP if detected
    if [[ -s "$outdir/wildcard_ip.txt" ]]; then
        wildcard_ip=$(cat "$outdir/wildcard_ip.txt")
        warn "Wildcard detected ($wildcard_ip) - will filter false positives"
    fi

    # Extract clean domains (not URLs)
    sed -E 's|^https?://||; s|/.*$||; s|:.*$||' "$outdir/subdomains.txt" \
        | sort -u > "$outdir/permutations/input_domains.txt"

    local input_count
    input_count=$(wc -l < "$outdir/permutations/input_domains.txt")
    info "Generating permutations from $input_count domains..."

    # Generate permutations with available tools (parallel)
    (
        if is_tool_enabled "ENABLE_ALTERX"; then
            info "Running alterx"
            alterx -l "$outdir/permutations/input_domains.txt" -silent \
                -o "$outdir/permutations/alterx.txt" 2>/dev/null &
        else
            info "Skipping alterx (disabled in config)"
            touch "$outdir/permutations/alterx.txt"
        fi

        if is_tool_enabled "ENABLE_DNSGEN"; then
            info "Running dnsgen"
            dnsgen "$outdir/permutations/input_domains.txt" \
                > "$outdir/permutations/dnsgen.txt" 2>/dev/null &
        else
            info "Skipping dnsgen (disabled in config)"
            touch "$outdir/permutations/dnsgen.txt"
        fi

        if is_tool_enabled "ENABLE_GOTATOR"; then
            info "Running gotator"
            gotator -sub "$outdir/permutations/input_domains.txt" -perm -silent \
                > "$outdir/permutations/gotator.txt" 2>/dev/null &
        else
            info "Skipping gotator (disabled in config)"
            touch "$outdir/permutations/gotator.txt"
        fi

        wait
    )

    # Combine all permutations (optimized: direct sort without cat)
    sort -u "$outdir/permutations/alterx.txt" \
        "$outdir/permutations/dnsgen.txt" \
        "$outdir/permutations/gotator.txt" \
        -o "$outdir/permutations/all_permutations.txt" 2>/dev/null

    # Dedupe - remove already known subdomains
    if [[ -s "$outdir/permutations/all_permutations.txt" ]]; then
        comm -23 \
            <(sort "$outdir/permutations/all_permutations.txt") \
            <(sort "$outdir/subdomains.txt") \
            > "$outdir/permutations/new_permutations.txt"
    fi

    if [[ ! -s "$outdir/permutations/new_permutations.txt" ]]; then
        info "No new permutations to check"
        return
    fi

    local perm_count
    perm_count=$(wc -l < "$outdir/permutations/new_permutations.txt")
    info "Resolving $perm_count unique new permutations..."

    # DNS resolution with dnsx
    if [[ -n "$wildcard_ip" ]]; then
        # Filter out wildcard IPs
        dnsx -l "$outdir/permutations/new_permutations.txt" \
            -silent -a -resp \
            -rate "$threads" \
            -retry 2 \
            2>/dev/null \
            | grep -v "$wildcard_ip" \
            | awk '{print $1}' \
            | sort -u > "$outdir/permutations/resolved.txt"
    else
        dnsx -l "$outdir/permutations/new_permutations.txt" \
            -silent \
            -rate "$threads" \
            -retry 2 \
            -o "$outdir/permutations/resolved.txt" 2>/dev/null
    fi

    if [[ ! -s "$outdir/permutations/resolved.txt" ]]; then
        info "No permutations resolved"
        return
    fi

    local resolved_count
    resolved_count=$(wc -l < "$outdir/permutations/resolved.txt")
    ok "Found $resolved_count resolved permutations"

    # Probe with httpx (JSON output)
    info "Probing resolved permutations..."
    httpx -l "$outdir/permutations/resolved.txt" \
        -silent -nc \
        -location -ip -title -tech-detect -status-code -td \
        -favicon -cdn -web-server \
        -timeout 10 -retries 2 -rl 150 \
        -threads "$threads" \
        -json -o "$outdir/permutations/httpx.json"

    # Validate JSON and extract results
    if validate_json "$outdir/permutations/httpx.json" "permutation httpx results"; then
        # Generate human-readable format
        jq -r '[.url, "[\(.status_code)]", "[\(.title // "")]", "[\(.webserver // "")]", "[\(.tech // [] | join(","))]"] | join(" ")' \
            "$outdir/permutations/httpx.json" > "$outdir/permutations/httpx.txt" 2>/dev/null

        # Extract URLs using centralized function
        extract_httpx_urls "$outdir/permutations/httpx.json" "$outdir/permutations/live.txt"
    else
        warn "httpx did not produce valid JSON for permutations"
        touch "$outdir/permutations/live.txt"
    fi

    if [[ -s "$outdir/permutations/live.txt" ]]; then
        local live_count
        live_count=$(wc -l < "$outdir/permutations/live.txt")
        ok "Found $live_count NEW live subdomains from permutations"

        # Append new discoveries to main lists
        cat "$outdir/permutations/resolved.txt" >> "$outdir/subdomains.txt"
        sort -u -o "$outdir/subdomains.txt" "$outdir/subdomains.txt"

        cat "$outdir/permutations/live.txt" >> "$outdir/clean_httpx.txt"
        sort -u -o "$outdir/clean_httpx.txt" "$outdir/clean_httpx.txt"
    else
        info "No new live subdomains from permutations"
    fi

    ok "Permutation scanning completed"
}
