#!/usr/bin/env bash
# shellcheck shell=bash

# Delta/diff scanning - highlight what's new between scans

delta_step() {
    local outdir="$1"
    local snapshots_dir="$outdir/.snapshots"
    local timestamp
    timestamp=$(date '+%Y-%m-%d_%H%M%S')
    local current_snap="$snapshots_dir/$timestamp"

    info "Running delta analysis..."

    ensure_dir "$snapshots_dir"

    # Files to track for diffs
    local -A tracked_files=(
        ["subdomains"]="subdomains.txt"
        ["live_hosts"]="clean_httpx.txt"
        ["urls"]="urls.txt"
        ["open_ports"]="ports/naabu_output.txt"
        ["js_endpoints"]="js/analysis/all_endpoints.txt"
        ["secrets"]="js/analysis/trufflehog.txt"
        ["takeovers"]="takeover/potential_takeovers.txt"
    )

    # Find latest previous snapshot
    local prev_snap=""
    prev_snap=$(find "$snapshots_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)

    # Save current snapshot
    ensure_dir "$current_snap"
    for key in "${!tracked_files[@]}"; do
        local src="$outdir/${tracked_files[$key]}"
        if [[ -s "$src" ]]; then
            cp "$src" "$current_snap/${key}.txt"
            sort -o "$current_snap/${key}.txt" "$current_snap/${key}.txt"
        fi
    done

    # Also snapshot categorized patterns
    if [[ -d "$outdir/categorized" ]]; then
        ensure_dir "$current_snap/categorized"
        for f in "$outdir/categorized/"*.txt; do
            [[ -s "$f" ]] || continue
            local base
            base=$(basename "$f")
            sort "$f" > "$current_snap/categorized/$base"
        done
    fi

    # Prune old snapshots beyond MAX_SNAPSHOTS limit
    _prune_snapshots "$snapshots_dir" "${MAX_SNAPSHOTS:-5}"

    # First scan — no previous snapshot to compare
    if [[ -z "$prev_snap" || "$prev_snap" == "$current_snap" ]]; then
        info "First scan for this target — no previous data to compare"
        _generate_first_scan_delta "$outdir" "$timestamp"
        return 0
    fi

    local prev_timestamp
    prev_timestamp=$(basename "$prev_snap" | tr '_' ' ' | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3:\4/')

    info "Comparing against previous scan: $prev_timestamp"

    # Generate delta report
    local delta_md="$outdir/delta.md"
    local delta_json="$outdir/delta.json"
    local has_changes=false

    cat > "$delta_md" << EOF
# Delta Report — what's new since last scan

| | |
|---|---|
| **Previous scan** | $prev_timestamp |
| **Current scan** | $(echo "$timestamp" | tr '_' ' ' | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3:\4/') |

---

EOF

    # Start JSON
    cat > "$delta_json" << EOF
{
  "previous_scan": "$prev_timestamp",
  "current_scan": "$timestamp",
  "changes": {
EOF

    local json_first=true

    # Compare each tracked file
    for key in subdomains live_hosts urls open_ports js_endpoints secrets takeovers; do
        local curr_file="$current_snap/${key}.txt"
        local prev_file="$prev_snap/${key}.txt"
        local new_items=""
        local new_count=0
        local label

        case "$key" in
            subdomains) label="New Subdomains";;
            live_hosts) label="New Live Hosts";;
            urls) label="New URLs";;
            open_ports) label="New Open Ports";;
            js_endpoints) label="New JS Endpoints";;
            secrets) label="New Secrets";;
            takeovers) label="New Potential Takeovers";;
        esac

        if [[ -s "$curr_file" ]]; then
            if [[ -s "$prev_file" ]]; then
                new_items=$(comm -13 "$prev_file" "$curr_file" 2>/dev/null || true)
            else
                new_items=$(cat "$curr_file")
            fi
            new_count=$(echo "$new_items" | grep -c . 2>/dev/null || echo 0)
        fi

        # JSON entry
        if [[ "$json_first" == "true" ]]; then
            json_first=false
        else
            echo "," >> "$delta_json"
        fi
        printf '    "%s": %d' "$key" "$new_count" >> "$delta_json"

        # Markdown entry
        if [[ $new_count -gt 0 ]]; then
            has_changes=true
            local warning=""
            [[ "$key" == "secrets" ]] && warning=" !!!"
            [[ "$key" == "takeovers" ]] && warning=" !!!"

            echo "## $label (+$new_count)$warning" >> "$delta_md"
            echo >> "$delta_md"

            if [[ $new_count -le 50 ]]; then
                echo '```' >> "$delta_md"
                echo "$new_items" >> "$delta_md"
                echo '```' >> "$delta_md"
            else
                echo '```' >> "$delta_md"
                echo "$new_items" | head -20 >> "$delta_md"
                echo "... and $((new_count - 20)) more" >> "$delta_md"
                echo '```' >> "$delta_md"
            fi
            echo >> "$delta_md"
        fi
    done

    # Compare categorized patterns
    local cat_changes=""
    if [[ -d "$current_snap/categorized" && -d "$prev_snap/categorized" ]]; then
        for f in "$current_snap/categorized/"*.txt; do
            [[ -s "$f" ]] || continue
            local base new_cat_count
            base=$(basename "$f")
            local pattern="${base%.txt}"
            local prev_cat="$prev_snap/categorized/$base"

            if [[ -s "$prev_cat" ]]; then
                new_cat_count=$(comm -13 "$prev_cat" "$f" 2>/dev/null | grep -c . || echo 0)
            else
                new_cat_count=$(wc -l < "$f")
            fi

            if [[ $new_cat_count -gt 0 ]]; then
                cat_changes="${cat_changes}| $pattern | +$new_cat_count |\n"
            fi
        done
    fi

    if [[ -n "$cat_changes" ]]; then
        has_changes=true
        echo "## New GF Pattern Matches" >> "$delta_md"
        echo >> "$delta_md"
        echo "| Pattern | New |" >> "$delta_md"
        echo "|---------|-----|" >> "$delta_md"
        echo -e "$cat_changes" >> "$delta_md"
        echo >> "$delta_md"
    fi

    # Close JSON
    cat >> "$delta_json" << EOF

  }
}
EOF

    if [[ "$has_changes" == "true" ]]; then
        echo "---" >> "$delta_md"
        echo >> "$delta_md"
        echo "*Generated by zee-scanner delta analysis*" >> "$delta_md"
        ok "Delta report saved to: $delta_md"
        _print_delta_summary "$current_snap" "$prev_snap"
    else
        echo "No new findings since last scan." >> "$delta_md"
        info "No changes detected since previous scan"
    fi
}

_generate_first_scan_delta() {
    local outdir="$1" timestamp="$2"

    cat > "$outdir/delta.md" << EOF
# Delta Report

**First scan** — $(echo "$timestamp" | tr '_' ' ' | sed 's/\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1 \2:\3:\4/')

No previous scan data to compare against. This baseline will be used for future delta comparisons.

---

*Generated by zee-scanner delta analysis*
EOF

    cat > "$outdir/delta.json" << EOF
{
  "first_scan": true,
  "timestamp": "$timestamp",
  "changes": {}
}
EOF

    ok "Delta baseline saved (first scan)"
}

_print_delta_summary() {
    local current_snap="$1" prev_snap="$2"

    echo
    echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${BLUE}║          DELTA SUMMARY — NEW FINDINGS             ║${RESET}"
    echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════╝${RESET}"

    local -A labels=(
        ["subdomains"]="Subdomains"
        ["live_hosts"]="Live Hosts"
        ["urls"]="URLs"
        ["open_ports"]="Open Ports"
        ["js_endpoints"]="JS Endpoints"
        ["secrets"]="Secrets"
        ["takeovers"]="Takeovers"
    )

    local any_found=false
    for key in subdomains live_hosts urls open_ports js_endpoints secrets takeovers; do
        local curr_file="$current_snap/${key}.txt"
        local prev_file="$prev_snap/${key}.txt"
        local new_count=0

        if [[ -s "$curr_file" ]]; then
            if [[ -s "$prev_file" ]]; then
                new_count=$(comm -13 "$prev_file" "$curr_file" 2>/dev/null | grep -c . || echo 0)
            else
                new_count=$(wc -l < "$curr_file")
            fi
        fi

        [[ $new_count -eq 0 ]] && continue
        any_found=true

        local color="$GREEN"
        [[ "$key" == "secrets" ]] && color="$RED"
        [[ "$key" == "takeovers" ]] && color="$RED"

        printf "  ${color}[+] %-16s +%d${RESET}\n" "${labels[$key]}" "$new_count"
    done

    if [[ "$any_found" == "false" ]]; then
        echo -e "  ${YELLOW}No new findings${RESET}"
    fi

    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════${RESET}"
    echo
}

_prune_snapshots() {
    local snapshots_dir="$1"
    local max_keep="${2:-5}"

    local all_snaps
    all_snaps=$(find "$snapshots_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    local total
    total=$(echo "$all_snaps" | grep -c . 2>/dev/null || echo 0)

    if [[ $total -le $max_keep ]]; then
        return 0
    fi

    local to_remove=$((total - max_keep))
    info "Pruning $to_remove old snapshot(s) (keeping $max_keep)"

    echo "$all_snaps" | head -"$to_remove" | while IFS= read -r snap_dir; do
        rm -rf "$snap_dir"
    done
}
