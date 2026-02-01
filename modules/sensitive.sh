#!/usr/bin/env bash
# shellcheck shell=bash

# Sensitive file extensions (customize as needed)
SENSITIVE_EXT='xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg|old|orig|save|swp|swo'

# Common sensitive paths to check
SENSITIVE_PATHS=(
    ".git/config"
    ".git/HEAD"
    ".env"
    ".env.local"
    ".env.production"
    ".env.backup"
    "robots.txt"
    "sitemap.xml"
    "crossdomain.xml"
    "clientaccesspolicy.xml"
    ".well-known/security.txt"
    "swagger.json"
    "swagger.yaml"
    "openapi.json"
    "api-docs"
    "graphql"
    "graphiql"
    "actuator"
    "actuator/health"
    "actuator/env"
    "server-status"
    "server-info"
    "phpinfo.php"
    "info.php"
    "test.php"
    "debug"
    "console"
    "trace.axd"
    "elmah.axd"
    "web.config"
    "web.config.bak"
    "wp-config.php"
    "wp-config.php.bak"
    "config.php"
    "config.php.bak"
    "database.yml"
    "settings.py"
    ".htaccess"
    ".htpasswd"
    "backup.sql"
    "dump.sql"
    "package.json"
    "composer.json"
    ".DS_Store"
    "Thumbs.db"
    ".svn/entries"
    "CVS/Root"
    "WEB-INF/web.xml"
    "META-INF/MANIFEST.MF"
)

sensitive_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Discovering sensitive files..."
    ensure_dir "$outdir/sensitive"

    # Extract sensitive file URLs from all discovered URLs
    if [[ -s "$outdir/urls.txt" ]]; then
        info "Extracting sensitive file URLs..."
        grep -iE "\.($SENSITIVE_EXT)(\?|$)" "$outdir/urls.txt" \
            | sort -fu > "$outdir/sensitive/urls_sensitive.txt"
        ok "Found $(wc -l < "$outdir/sensitive/urls_sensitive.txt" 2>/dev/null || echo 0) sensitive URLs"
    else
        warn "urls.txt missing; skipping sensitive URL extraction."
    fi

    # Probe sensitive URLs to check if they're live
    if [[ -s "$outdir/sensitive/urls_sensitive.txt" ]]; then
        info "Probing sensitive URLs..."
        httpx -l "$outdir/sensitive/urls_sensitive.txt" \
            -silent -nc -mc 200,403 \
            -title -status-code -content-length \
            -H "$HEADER" -threads "$threads" \
            -o "$outdir/sensitive/urls_sensitive_live.txt" 2>/dev/null
        ok "Found $(wc -l < "$outdir/sensitive/urls_sensitive_live.txt" 2>/dev/null || echo 0) live sensitive URLs"
    fi

    # Check common sensitive paths on all live hosts
    if [[ -s "$outdir/clean_httpx.txt" ]]; then
        info "Checking common sensitive paths..."
        ensure_dir "$outdir/sensitive/paths"

        # Create wordlist from sensitive paths
        printf '%s\n' "${SENSITIVE_PATHS[@]}" > "$outdir/sensitive/paths/wordlist.txt"

        # Run ffuf on all hosts in parallel batches
        local host_count
        host_count=$(wc -l < "$outdir/clean_httpx.txt")
        info "Scanning $host_count hosts for sensitive paths..."

        ffuf -w "$outdir/sensitive/paths/wordlist.txt" \
            -w "$outdir/clean_httpx.txt":HOST \
            -u "HOST/FUZZ" \
            -mc 200,403,500 \
            -H "$HEADER" \
            -t "$threads" \
            -sf \
            -o "$outdir/sensitive/paths/ffuf_results.json" \
            -of json 2>/dev/null

        # Extract successful hits
        if [[ -s "$outdir/sensitive/paths/ffuf_results.json" ]]; then
            if validate_ffuf_json "$outdir/sensitive/paths/ffuf_results.json"; then
                if jq -r '.results[] | "\(.url) [\(.status)] [\(.length)]"' \
                    "$outdir/sensitive/paths/ffuf_results.json" \
                    > "$outdir/sensitive/paths/found.txt" 2>/dev/null; then
                    ok "Found $(wc -l < "$outdir/sensitive/paths/found.txt" 2>/dev/null || echo 0) sensitive paths"
                else
                    warn "Failed to parse ffuf results"
                fi
            else
                warn "ffuf did not produce valid JSON output for sensitive paths"
            fi
        fi
    fi

    # Backup file discovery
    if [[ -s "$outdir/clean_httpx.txt" ]]; then
        info "Looking for backup files..."
        ensure_dir "$outdir/sensitive/backups"

        while read -r url; do
            [[ -z "$url" ]] && continue
            local domain
            domain="$(echo "$url" | unfurl format %d 2>/dev/null || echo "$url" | sed 's|https\?://||;s|/.*||')"

            backupfinder -u "$url" --silent 2>/dev/null \
                | ffuf -w /dev/stdin \
                    -u "$url/FUZZ" \
                    -mc 200,403 \
                    -H "$HEADER" \
                    -t "$threads" \
                    -sf \
                    -o "$outdir/sensitive/backups/${domain}.json" \
                    -of json 2>/dev/null &

            # Limit parallel jobs
            [[ $(jobs -r -p | wc -l) -ge 10 ]] && wait -n
        done < "$outdir/clean_httpx.txt"
        wait

        # Combine all backup results
        # Note: Multiple JSON files need to be validated individually
        local backup_count=0
        for json_file in "$outdir/sensitive/backups"/*.json; do
            [[ -f "$json_file" ]] || continue
            # Only process valid JSON files
            if validate_json "$json_file" "backup scan results" 2>/dev/null; then
                jq -r '.results[]? | "\(.url) [\(.status)]"' "$json_file" 2>/dev/null || true
            fi
        done > "$outdir/sensitive/backups/all_backups.txt"

        if [[ -s "$outdir/sensitive/backups/all_backups.txt" ]]; then
            ok "Found $(wc -l < "$outdir/sensitive/backups/all_backups.txt") potential backup files"
        fi
    fi

    ok "Sensitive file discovery completed"
}
