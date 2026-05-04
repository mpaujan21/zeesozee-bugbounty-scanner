#!/usr/bin/env bash
# shellcheck shell=bash

detect_wildcard() {
    local domain="$1"
    local ips=() i rand resolved

    for i in $(seq 1 5); do
        rand="$(head /dev/urandom | tr -dc a-z0-9 | head -c 16)"
        resolved="$(dig +short "${rand}.${domain}" A 2>/dev/null | head -1)"
        [[ -n "$resolved" ]] && ips+=("$resolved")
    done

    if [[ ${#ips[@]} -ge 2 ]]; then
        local first="${ips[0]}" all_match=true
        for ip in "${ips[@]}"; do
            [[ "$ip" != "$first" ]] && all_match=false && break
        done
        if $all_match; then
            echo "$first"
            return
        fi
    fi

    # Per-depth check: random names under a random second-level zone
    local sub_part r1 r2 ip1 ip2
    sub_part="$(head /dev/urandom | tr -dc a-z0-9 | head -c 8)"
    r1="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
    r2="$(head /dev/urandom | tr -dc a-z0-9 | head -c 12)"
    ip1="$(dig +short "${r1}.${sub_part}.${domain}" A 2>/dev/null | head -1)"
    ip2="$(dig +short "${r2}.${sub_part}.${domain}" A 2>/dev/null | head -1)"
    if [[ -n "$ip1" && "$ip1" == "$ip2" ]]; then
        echo "$ip1"
    fi
}

# Remove subdomains that resolve to the wildcard IP using dnsx for speed
filter_wildcards() {
    local file="$1" wildcard_ip="$2"
    [[ -z "$wildcard_ip" || ! -f "$file" ]] && return
    local tmp
    tmp=$(mktemp)
    dnsx -l "$file" -silent -a -resp 2>/dev/null \
        | grep -v "\[${wildcard_ip}\]" \
        | awk '{print $1}' > "$tmp"
    mv "$tmp" "$file"
}

subdomains_step() {
    local domain="$1" outdir="$2"
    local wildcard_ip tmpdir
    tmpdir=$(mktemp -d)

    ok "Starting Subdomain Enumeration..."

    # Passive Enumeration (parallel)
    (
        if is_tool_enabled "ENABLE_SUBFINDER"; then
            info "Running subfinder (all sources)"
            subfinder -all -silent -d "$domain" 2>&1 | grep -v "^$" | sed 's/^/[subfinder] /' | sort -u > "$tmpdir/subfinder.txt" &
        else
            info "Skipping subfinder (disabled in config)"
            touch "$tmpdir/subfinder.txt"
        fi

        if is_tool_enabled "ENABLE_ASSETFINDER"; then
            info "Running assetfinder"
            assetfinder --subs-only "$domain" 2>&1 | grep -v "^$" | sed 's/^/[assetfinder] /' | sort -u > "$tmpdir/assetfinder.txt" &
        else
            info "Skipping assetfinder (disabled in config)"
            touch "$tmpdir/assetfinder.txt"
        fi

        if is_tool_enabled "ENABLE_FINDOMAIN"; then
            info "Running findomain"
            findomain -t "$domain" -q 2>&1 | grep -v "^$" | sed 's/^/[findomain] /' | sort -u > "$tmpdir/findomain.txt" &
        else
            info "Skipping findomain (disabled in config)"
            touch "$tmpdir/findomain.txt"
        fi

        if is_tool_enabled "ENABLE_AMASS"; then
            info "Running amass (passive)"
            amass enum -passive -d "$domain" 2>/dev/null | sort -u > "$tmpdir/amass.txt" &
        else
            info "Skipping amass (disabled in config)"
            touch "$tmpdir/amass.txt"
        fi

        if is_tool_enabled "ENABLE_CHAOS"; then
            if [[ -n "${CHAOS_PDCP_API_KEY:-}" ]]; then
                info "Querying Chaos dataset"
                chaos -d "$domain" -silent -key "$CHAOS_PDCP_API_KEY" 2>/dev/null \
                    | grep -v "^$" | sed 's/^/[chaos] /' | sort -u > "$tmpdir/chaos.txt" &
            else
                warn "Skipping Chaos (CHAOS_PDCP_API_KEY not set)"
                touch "$tmpdir/chaos.txt"
            fi
        else
            touch "$tmpdir/chaos.txt"
        fi

        wait_jobs "subdomains"
    )

    # Combine all results
    local escaped_domain
    escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
    grep -hE "(^|\.| )${escaped_domain}$" "$tmpdir"/*.txt 2>/dev/null \
        | sed 's/^\[.*\] //' \
        | sort -fu > "$outdir/subdomains.txt"

    rm -rf "$tmpdir"

    # Wildcard Detection
    info "Checking for wildcard DNS..."
    wildcard_ip=$(detect_wildcard "$domain")

    if [[ -n "$wildcard_ip" ]]; then
        warn "Wildcard DNS detected: *.${domain} -> ${wildcard_ip}"
        echo "$wildcard_ip" > "$outdir/wildcard_ip.txt"
        info "Filtering wildcard-resolving subdomains..."
        filter_wildcards "$outdir/subdomains.txt" "$wildcard_ip"
    else
        ok "No wildcard DNS detected"
    fi

    # Targeted recursive enum on high-value zones
    if is_tool_enabled "ENABLE_RECURSIVE_ENUM" && is_tool_enabled "ENABLE_SUBFINDER"; then
        local max_zones="${RECURSIVE_ENUM_MAX_ZONES:-5}"
        local zones
        mapfile -t zones < <(
            grep -E "^(dev|staging|stg|internal|corp|admin|api|test|qa|uat|preprod)\.${escaped_domain}$" \
                "$outdir/subdomains.txt" 2>/dev/null \
                | sort -u | head -n "$max_zones"
        )

        if [[ ${#zones[@]} -gt 0 ]]; then
            info "Recursive enum on ${#zones[@]} high-value zones: ${zones[*]}"
            local rectmp i=0
            rectmp=$(mktemp -d)
            for zone in "${zones[@]}"; do
                subfinder -all -silent -d "$zone" 2>/dev/null \
                    | grep -v "^$" | sort -u > "$rectmp/rec_${i}.txt" &
                i=$((i + 1))
            done
            wait_jobs "recursive_enum"

            grep -hE "(^|\.)${escaped_domain}$" "$rectmp"/*.txt 2>/dev/null \
                | sort -u >> "$outdir/subdomains.txt"
            sort -fu "$outdir/subdomains.txt" -o "$outdir/subdomains.txt"
            rm -rf "$rectmp"

            [[ -n "$wildcard_ip" ]] && filter_wildcards "$outdir/subdomains.txt" "$wildcard_ip"
        fi
    fi

    ok "Found $(wc -l < "$outdir/subdomains.txt" 2>/dev/null || echo 0) unique subdomains"
}
