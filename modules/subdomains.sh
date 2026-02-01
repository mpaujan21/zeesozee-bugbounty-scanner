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

    # Passive Enumeration (parallel, with pre-deduplication)
    (
        info "Running subfinder"
        subfinder -silent -d "$domain" 2>&1 | grep -v "^$" | sed 's/^/[subfinder] /' | sort -u > "$outdir/subfinder.txt" &

        info "Running assetfinder"
        assetfinder --subs-only "$domain" 2>&1 | grep -v "^$" | sed 's/^/[assetfinder] /' | sort -u > "$outdir/assetfinder.txt" &

        info "Running findomain"
        findomain -t "$domain" -q 2>&1 | grep -v "^$" | sed 's/^/[findomain] /' | sort -u > "$outdir/findomain.txt" &

        info "Running amass (passive)"
        amass enum -passive -d "$domain" 2>/dev/null | sort -u > "$outdir/amass.txt" &

        info "Querying crt.sh"
        curl -s "https://crt.sh/?q=%25.${domain}&output=json" 2>/dev/null \
            | jq -r '.[].name_value' 2>/dev/null \
            | sed 's/\*\.//g' \
            | sort -u > "$outdir/crtsh.txt" &

        wait
    )

    # Combine all results (optimized: direct sort without cat)
    grep -hE "\.${domain}$" \
        "$outdir"/subfinder.txt \
        "$outdir"/assetfinder.txt \
        "$outdir"/findomain.txt \
        "$outdir"/amass.txt \
        "$outdir"/crtsh.txt 2>/dev/null \
        | sort -fu > "$outdir/subdomains_raw.txt"

    # Wildcard Detection (informational)
    info "Checking for wildcard DNS..."
    wildcard_ip=$(detect_wildcard "$domain")

    if [[ -n "$wildcard_ip" ]]; then
        warn "Wildcard DNS detected: *.${domain} -> ${wildcard_ip}"
        echo "$wildcard_ip" > "$outdir/wildcard_ip.txt"
    else
        ok "No wildcard DNS detected"
    fi

    # Finalize subdomain list
    mv "$outdir/subdomains_raw.txt" "$outdir/subdomains.txt"
    ok "Found $(wc -l < "$outdir/subdomains.txt" 2>/dev/null || echo 0) unique subdomains"
}
