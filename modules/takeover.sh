#!/usr/bin/env bash
# shellcheck shell=bash

# Subdomain takeover detection via dangling CNAME fingerprinting

# Fingerprints: service|cname_pattern|body_fingerprint
TAKEOVER_FINGERPRINTS=(
    "GitHub Pages|.github.io|There isn't a GitHub Pages site here"
    "Heroku|.herokuapp.com|No such app"
    "AWS S3|.s3.amazonaws.com|NoSuchBucket"
    "AWS S3|.s3-website|NoSuchBucket"
    "Shopify|.myshopify.com|Sorry, this shop is currently unavailable"
    "Tumblr|.tumblr.com|There's nothing here"
    "Pantheon|.pantheonsite.io|404 error unknown site"
    "Readme.io|.readme.io|Project doesnt exist"
    "Surge.sh|.surge.sh|project not found"
    "WordPress.com|.wordpress.com|Do you want to register"
    "Fly.io|.fly.dev|404 Not Found"
    "Ghost|.ghost.io|The thing you were looking for is no longer here"
    "Fastly|.fastly.net|Fastly error: unknown domain"
    "Zendesk|.zendesk.com|Help Center Closed"
    "Teamwork|.teamwork.com|Oops - We didn't find your site"
    "Helpjuice|.helpjuice.com|We could not find what you're looking for"
    "Help Scout|.helpscoutdocs.com|No settings were found for this company"
    "Cargo|.cargocollective.com|404 Not Found"
    "Statuspage|.statuspage.io|StatusPage"
    "Intercom|.custom.intercom.help|This page is reserved for artistic dogs"
    "Tilda|.tilda.ws|Please renew your subscription"
    "Unbounce|.unbouncepages.com|The requested URL was not found"
    "Pingdom|.stats.pingdom.com|Public Report Not Activated"
    "Campaignmonitor|.createsend.com|Trying to access your account?"
    "Acquia|.acquia-test.co|Web Site Not Found"
    "Bitbucket|.bitbucket.io|Repository not found"
    "Smartling|.smartling.com|Domain is not configured"
    "Strikingly|.strikinglys.com|page not found"
    "Uptimerobot|.uptimerobot.com|page not found"
    "Frontify|.frontify.com|404 - Page not found"
)

takeover_step() {
    local outdir="$1" domain="$2" threads="${3:-10}"
    local takeover_dir="$outdir/takeover"
    local subs_file="$outdir/subdomains.txt"

    info "Starting subdomain takeover detection..."

    if [[ ! -s "$subs_file" ]]; then
        warn "No subdomains found, skipping takeover detection"
        return 0
    fi

    ensure_dir "$takeover_dir"

    local sub_count
    sub_count=$(wc -l < "$subs_file")
    info "Checking $sub_count subdomains for dangling CNAMEs..."

    # Step 1: Batch CNAME lookup with dnsx
    if command -v dnsx >/dev/null 2>&1; then
        dnsx -l "$subs_file" -cname -resp -silent -t "$threads" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*[mK]//g' \
            > "$takeover_dir/cname_results.txt" || true
    else
        warn "dnsx not found, using dig fallback (slower)"
        > "$takeover_dir/cname_results.txt"
        while IFS= read -r sub; do
            local cname
            cname=$(dig +short CNAME "$sub" 2>/dev/null | head -1)
            [[ -n "$cname" ]] && echo "$sub [${cname%.}]" >> "$takeover_dir/cname_results.txt"
        done < "$subs_file"
    fi

    if [[ ! -s "$takeover_dir/cname_results.txt" ]]; then
        info "No CNAME records found"
        return 0
    fi

    local cname_count
    cname_count=$(wc -l < "$takeover_dir/cname_results.txt")
    info "Found $cname_count CNAME records, checking for takeover fingerprints..."

    # Step 2: Match against fingerprints
    > "$takeover_dir/potential_takeovers.txt"
    local candidates=()

    for fingerprint in "${TAKEOVER_FINGERPRINTS[@]}"; do
        IFS='|' read -r service cname_pattern body_pattern <<< "$fingerprint"

        # Find subdomains with matching CNAME
        while IFS= read -r line; do
            # dnsx output format: "subdomain [cname]"
            local subdomain cname_value
            subdomain=$(echo "$line" | awk '{print $1}')
            cname_value=$(echo "$line" | grep -oP '\[.*?\]' | tr -d '[]')

            if echo "$cname_value" | grep -qi "$cname_pattern"; then
                candidates+=("$service|$subdomain|$cname_value|$body_pattern")
            fi
        done < "$takeover_dir/cname_results.txt"
    done

    # Step 3: HTTP confirmation of candidates
    local confirmed=0
    for candidate in "${candidates[@]}"; do
        IFS='|' read -r service subdomain cname_value body_pattern <<< "$candidate"

        local body
        body=$(curl -sL --max-time 10 -o - "http://$subdomain" 2>/dev/null || true)

        if echo "$body" | grep -qi "$body_pattern"; then
            echo "[VULNERABLE] $subdomain -> $cname_value ($service)" >> "$takeover_dir/potential_takeovers.txt"
            warn "Potential takeover: $subdomain -> $cname_value ($service)"
            confirmed=$((confirmed + 1))
        else
            # Try HTTPS too
            body=$(curl -sL --max-time 10 -o - "https://$subdomain" 2>/dev/null || true)
            if echo "$body" | grep -qi "$body_pattern"; then
                echo "[VULNERABLE] $subdomain -> $cname_value ($service)" >> "$takeover_dir/potential_takeovers.txt"
                warn "Potential takeover: $subdomain -> $cname_value ($service)"
                confirmed=$((confirmed + 1))
            else
                echo "[CANDIDATE] $subdomain -> $cname_value ($service) (body mismatch)" >> "$takeover_dir/potential_takeovers.txt"
            fi
        fi
    done


    if [[ $confirmed -gt 0 ]]; then
        warn "Found $confirmed potential subdomain takeover(s)!"
    else
        ok "No subdomain takeovers detected ($cname_count CNAMEs checked)"
    fi
}
