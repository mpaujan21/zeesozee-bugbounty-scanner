#!/usr/bin/env bash
# shellcheck shell=bash

# Detect wildcard DNS by querying random subdomains
detect_wildcard() {
    local domain="$1"
    local random1 random2 ip1 ip2

    random1="$(head /dev/urandom | tr -dc a-z0-9 | head -c 16)"
    random2="$(head /dev/urandom | tr -dc a-z0-9 | head -c 16)"

    ip1="$(dig +short "${random1}.${domain}" A 2>/dev/null | head -1)"
    ip2="$(dig +short "${random2}.${domain}" A 2>/dev/null | head -1)"

    # If both random subdomains resolve to same IP, wildcard exists
    if [[ -n "$ip1" && "$ip1" == "$ip2" ]]; then
        echo "$ip1"
    fi
}

subdomains_step() {
    local domain="$1" outdir="$2"
    local wildcard_ip

    ok "Starting Subdomain Enumeration..."
    ensure_dir "$outdir/subdomains"

    # Passive Enumeration (parallel, with pre-deduplication)
    (
        if is_tool_enabled "ENABLE_SUBFINDER"; then
            info "Running subfinder"
            subfinder -silent -d "$domain" 2>&1 | grep -v "^$" | sed 's/^/[subfinder] /' | sort -u > "$outdir/subdomains/subfinder.txt" &
        else
            info "Skipping subfinder (disabled in config)"
            touch "$outdir/subdomains/subfinder.txt"
        fi

        if is_tool_enabled "ENABLE_ASSETFINDER"; then
            info "Running assetfinder"
            assetfinder --subs-only "$domain" 2>&1 | grep -v "^$" | sed 's/^/[assetfinder] /' | sort -u > "$outdir/subdomains/assetfinder.txt" &
        else
            info "Skipping assetfinder (disabled in config)"
            touch "$outdir/subdomains/assetfinder.txt"
        fi

        if is_tool_enabled "ENABLE_FINDOMAIN"; then
            info "Running findomain"
            findomain -t "$domain" -q 2>&1 | grep -v "^$" | sed 's/^/[findomain] /' | sort -u > "$outdir/subdomains/findomain.txt" &
        else
            info "Skipping findomain (disabled in config)"
            touch "$outdir/subdomains/findomain.txt"
        fi

        if is_tool_enabled "ENABLE_AMASS"; then
            info "Running amass (passive)"
            amass enum -passive -d "$domain" 2>/dev/null | sort -u > "$outdir/subdomains/amass.txt" &
        else
            info "Skipping amass (disabled in config)"
            touch "$outdir/subdomains/amass.txt"
        fi

        if is_tool_enabled "ENABLE_CRTSH"; then
            info "Querying crt.sh"
            curl -s "https://crt.sh/?q=%25.${domain}&output=json" 2>/dev/null \
                | jq -r '.[].name_value' 2>/dev/null \
                | sed 's/\*\.//g' \
                | sort -u > "$outdir/subdomains/crtsh.txt" &
        else
            info "Skipping crt.sh (disabled in config)"
            touch "$outdir/subdomains/crtsh.txt"
        fi

        wait_jobs "subdomains"
    )

    # Combine all results (optimized: direct sort without cat)
    local escaped_domain
    escaped_domain=$(printf '%s' "$domain" | sed 's/[.[\*^$()+?{}|]/\\&/g')
    grep -hE "(^|\.| )${escaped_domain}$" \
        "$outdir"/subdomains/subfinder.txt \
        "$outdir"/subdomains/assetfinder.txt \
        "$outdir"/subdomains/findomain.txt \
        "$outdir"/subdomains/amass.txt \
        "$outdir"/subdomains/crtsh.txt 2>/dev/null \
        | sed 's/^\[.*\] //' \
        | sort -fu > "$outdir/subdomains/subdomains_raw.txt"

    # Wildcard Detection (informational)
    info "Checking for wildcard DNS..."
    wildcard_ip=$(detect_wildcard "$domain")

    if [[ -n "$wildcard_ip" ]]; then
        warn "Wildcard DNS detected: *.${domain} -> ${wildcard_ip}"
        echo "$wildcard_ip" > "$outdir/subdomains/wildcard_ip.txt"
    else
        ok "No wildcard DNS detected"
    fi

    # Finalize subdomain list
    mv "$outdir/subdomains/subdomains_raw.txt" "$outdir/subdomains.txt"
    ok "Found $(wc -l < "$outdir/subdomains.txt" 2>/dev/null || echo 0) unique subdomains"
}
