#!/usr/bin/env bash
# shellcheck shell=bash

# HTTP Response Analysis - flag interesting findings from httpx_pretty.json

response_analysis_step() {
    local outdir="$1"
    local analysis_dir="$outdir/response_analysis"
    local httpx_json="$outdir/httpx_pretty.json"
    local findings_txt="$analysis_dir/findings.txt"
    local findings_json="$analysis_dir/findings.json"

    ok "Analyzing HTTP responses..."

    if [[ ! -s "$httpx_json" ]]; then
        warn "httpx_pretty.json not found; skipping response analysis"
        return 0
    fi

    ensure_dir "$analysis_dir"

    # Build consolidated findings JSON in single jq pass
    jq '
        def header_str: (.header // .headers // "") | tostring;
        def title: .title // "";
        def tech_lc: ((.tech // []) | join(" ") | ascii_downcase);

        {
            interesting_status_codes: [
                .[] | select(.status_code == 401 or .status_code == 403 or .status_code == 405 or
                             .status_code == 500 or .status_code == 502 or .status_code == 503)
                | {url, status: .status_code}
            ],
            tech_stack: [
                .[] | select(.tech != null and (.tech | length > 0))
                | {url, tech}
            ],
            admin_panels: [
                .[] | select(
                    (title | test("(?i)jenkins|grafana|kibana|gitlab|jira|prometheus|swagger|phpmyadmin|adminer|kubernetes dashboard|consul|rabbitmq|jupyter|sonarqube|harbor|\\bvault\\b|openshift|nagios|zabbix|portainer|traefik dashboard|argo cd|airflow"))
                    or
                    (tech_lc | test("jenkins|grafana|kibana|gitlab|jira|prometheus|swagger|phpmyadmin|adminer|kubernetes|consul|rabbitmq|jupyter|sonarqube|harbor|nagios|zabbix|portainer"))
                ) | {url, title, tech: (.tech // [])}
            ],
            auth_pages: [
                .[] | select(title | test("(?i)\\b(login|sign[- ]?in|log[- ]?in|sign[- ]?on|sso|console|dashboard|portal|sign[- ]?up|password|account|register)\\b"))
                | {url, title}
            ],
            default_pages: [
                .[] | select(title | test("(?i)apache2 ubuntu default|welcome to nginx|welcome to centos|test page for|iis windows|apache tomcat|drupal install|setup wizard|welcome to wordpress|^it works!?|plesk default|cpanel|^index of /|default web site|^test$|under construction"))
                | {url, title}
            ],
            outdated_tech: [
                .[] | (header_str) as $h | .url as $u
                | ($h | split("\n") | map(sub("\\r$"; "")) | map(select(test("(?i)^(server|x-powered-by):\\s*\\S+/\\d")))) as $matches
                | select($matches | length > 0)
                | {url: $u, headers: $matches}
            ],
            response_clusters: (
                [.[] | select(.hash != null and .hash.body_sha256 != null) | {url, hash: .hash.body_sha256}]
                | group_by(.hash)
                | map({hash: .[0].hash, count: length, samples: ([.[].url] | .[0:3])})
                | map(select(.count >= 3))
                | sort_by(-.count)
            )
        }
    ' "$httpx_json" > "$findings_json" 2>/dev/null

    if [[ ! -s "$findings_json" ]]; then
        warn "Failed to generate findings.json"
        return 1
    fi

    # Build human-readable findings.txt
    {
        echo "# HTTP Response Analysis"
        echo

        local n
        n=$(jq '.admin_panels | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Admin Panels ($n)"
            jq -r '.admin_panels[] | "  \(.url) — title: \(.title) — tech: \(.tech | join(","))"' "$findings_json"
            echo
        fi

        n=$(jq '.auth_pages | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Auth/Login Pages ($n)"
            jq -r '.auth_pages[] | "  \(.url) — \(.title)"' "$findings_json"
            echo
        fi

        n=$(jq '.default_pages | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Default/Install Pages ($n)"
            jq -r '.default_pages[] | "  \(.url) — \(.title)"' "$findings_json"
            echo
        fi

        n=$(jq '.outdated_tech | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Server / X-Powered-By Versions ($n)"
            jq -r '.outdated_tech[] | "  \(.url) — \(.headers | join(" | "))"' "$findings_json"
            echo
        fi

        n=$(jq '.response_clusters | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Response Clusters (>=3 hosts same body hash) ($n)"
            jq -r '.response_clusters[] | "  hash=\(.hash[0:12]) count=\(.count) samples: \(.samples | join(", "))"' "$findings_json"
            echo
        fi

        n=$(jq '.interesting_status_codes | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Interesting Status Codes ($n)"
            jq -r '.interesting_status_codes[] | "  \(.url) [\(.status)]"' "$findings_json"
            echo
        fi

        n=$(jq '.tech_stack | length' "$findings_json")
        if [[ $n -gt 0 ]]; then
            echo "## Tech Stack ($n)"
            jq -r '.tech_stack[] | "  \(.url) — \(.tech | join(", "))"' "$findings_json"
            echo
        fi
    } > "$findings_txt"

    # Summary log
    local admin_n auth_n def_n tech_v_n cluster_n status_n tech_n
    admin_n=$(jq '.admin_panels | length' "$findings_json" 2>/dev/null || echo 0)
    auth_n=$(jq '.auth_pages | length' "$findings_json" 2>/dev/null || echo 0)
    def_n=$(jq '.default_pages | length' "$findings_json" 2>/dev/null || echo 0)
    tech_v_n=$(jq '.outdated_tech | length' "$findings_json" 2>/dev/null || echo 0)
    cluster_n=$(jq '.response_clusters | length' "$findings_json" 2>/dev/null || echo 0)
    status_n=$(jq '.interesting_status_codes | length' "$findings_json" 2>/dev/null || echo 0)
    tech_n=$(jq '.tech_stack | length' "$findings_json" 2>/dev/null || echo 0)

    [[ $admin_n -gt 0 ]] && warn "Admin panels: $admin_n (CRITICAL)"
    [[ $def_n -gt 0 ]] && warn "Default install pages: $def_n"
    [[ $auth_n -gt 0 ]] && info "Auth pages: $auth_n"
    [[ $tech_v_n -gt 0 ]] && info "Tech versions: $tech_v_n"
    [[ $cluster_n -gt 0 ]] && info "Response clusters: $cluster_n"
    [[ $status_n -gt 0 ]] && info "Interesting status codes: $status_n"
    [[ $tech_n -gt 0 ]] && info "Tech stack: $tech_n"

    ok "Response analysis -> $findings_txt + $findings_json"
}
