#!/usr/bin/env bash
# shellcheck shell=bash

sensitive_step() {
    local outdir="$1" threads="${2:-50}"
    ok "Discovering sensitive files..."
    ensure_dir "$outdir/sensitive"
    
    if [[ -s "$outdir/urls/waybackurls.txt" ]]; then
        grep -E '\.(xls|xml|xlsx|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|secret|db|backup|yml|gz|config|csv|yaml|md|md5|tar|xz|p12|pem|key|crt|csr|sh|pl|py|java|class|jar|war|ear|sqlitedb|sqlite3|dbf|db3|accdb|mdb|sqlcipher|gitignore|env|ini|conf|properties|plist|cfg)$' \
        "$outdir/urls/waybackurls.txt" > "$outdir/sensitive/urls_sensitive.txt" || true
    else
        warn "waybackurls.txt missing; skipping sensitive URL extraction."
    fi
    
    info "Looking for backup files…"
    ensure_dir "$outdir/sensitive/backups"
    head -n 10 "$outdir/clean_httpx.txt" 2>/dev/null | while read -r url; do
        [[ -z "$url" ]] && continue
        local domain; domain="$(echo "$url" | unfurl format %d 2>/dev/null || echo "$url")"
        info "Checking backups for $domain"
        backupfinder -u "$url" --silent | ffuf -w /dev/stdin -u "$url/FUZZ" -mc 200,403,500 -fc 404 -t "$threads" \
        -o "$outdir/sensitive/backups/${domain}_backups.txt"
    done
}
