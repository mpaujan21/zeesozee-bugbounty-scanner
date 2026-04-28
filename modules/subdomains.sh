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
    local wildcard_ip tmpdir
    tmpdir=$(mktemp -d)

    ok "Starting Subdomain Enumeration..."

    # Passive Enumeration (parallel)
    (
        if is_tool_enabled "ENABLE_SUBFINDER"; then
            info "Running subfinder"
            subfinder -silent -d "$domain" 2>&1 | grep -v "^$" | sed 's/^/[subfinder] /' | sort -u > "$tmpdir/subfinder.txt" &
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

        if is_tool_enabled "ENABLE_CRTSH"; then
            info "Querying crt.sh"
            curl -s "https://crt.sh/?q=%25.${domain}&output=json" 2>/dev/null \
                | jq -r '.[].name_value' 2>/dev/null \
                | sed 's/\*\.//g' \
                | sort -u > "$tmpdir/crtsh.txt" &
        else
            info "Skipping crt.sh (disabled in config)"
            touch "$tmpdir/crtsh.txt"
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

    # Wildcard Detection (informational)
    info "Checking for wildcard DNS..."
    wildcard_ip=$(detect_wildcard "$domain")

    if [[ -n "$wildcard_ip" ]]; then
        warn "Wildcard DNS detected: *.${domain} -> ${wildcard_ip}"
        echo "$wildcard_ip" > "$outdir/wildcard_ip.txt"
    else
        ok "No wildcard DNS detected"
    fi

    ok "Found $(wc -l < "$outdir/subdomains.txt" 2>/dev/null || echo 0) unique subdomains"
}
