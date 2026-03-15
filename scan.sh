#!/bin/bash

set -euo pipefail

# load libs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/colors.sh"
. "$SCRIPT_DIR/lib/utils.sh"
. "$SCRIPT_DIR/lib/validation.sh"
. "$SCRIPT_DIR/lib/fileops.sh"

# load modules
for mod in subdomains probing response_analysis ports permutation urls categorize js report takeover screenshots delta; do
    . "$SCRIPT_DIR/modules/${mod}.sh"
done

show_help() {
    cat <<EOF
${BOLD}${BLUE}Zee Scanner - Bug Bounty Reconnaissance Automation${RESET}

${BOLD}Usage:${RESET}
  $0 <foldername> <domain> [OPTIONS]

${BOLD}Required Arguments:${RESET}
  foldername    Output directory name (created in \$HACK/programs/)
  domain        Target domain to scan

${BOLD}Options:${RESET}
  --threads N       Number of concurrent threads (default: 50, range: 1-1000)
  --yes-js y|n      Enable JavaScript analysis (interactive if not specified)
  --yes-ports y|n   Enable port scanning (interactive if not specified)
  --yes-screenshots y|n  Enable screenshot capture with gowitness (interactive if not specified)
  --config FILE     Load configuration from FILE (default: scan.conf or ~/.zee-scanner.conf)
  --force-restart   Clear previous scan state and restart from beginning
  --help            Show this help message

${BOLD}Examples:${RESET}
  $0 acme acme.com
  $0 acme acme.com --threads 80 --yes-js y --yes-ports n
  $0 bugcrowd bugcrowd.com --threads 100

${BOLD}Environment Variables:${RESET}
  HACK           Output base directory (default: ~/HACK)
  SCAN_THREADS   Default thread count (default: 50)

${BOLD}Output:${RESET}
  Results saved to: \$HACK/programs/<foldername>/
  Final report: \$HACK/programs/<foldername>/report.md
EOF
}

banner

# Check for --help flag first
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_help
    exit 0
fi

# args + flags
if [[ $# -lt 2 ]]; then
    err "Usage: $0 <foldername> <domain> [--yes-js y|n] [--yes-ports y|n] [--threads N]"
    echo ""
    info "Run '$0 --help' for more information"
    exit 1
fi

HACK="${HACK:-$HOME/HACK}"; FOLDERNAME="$1"; OUTDIR="${HACK%/}/programs/$1"; DOMAIN="$2"; shift 2
THREADS="${SCAN_THREADS:-50}"
YES_JS="ask"; YES_PORTS="ask"; YES_SCREENSHOTS="ask"
FORCE_RESTART=false
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threads) THREADS="${2:-$THREADS}"; shift 2;;
        --yes-js) YES_JS="${2:-ask}"; shift 2;;
        --yes-ports) YES_PORTS="${2:-ask}"; shift 2;;
        --yes-screenshots) YES_SCREENSHOTS="${2:-ask}"; shift 2;;
        --force-restart) FORCE_RESTART=true; shift;;
        --config) CONFIG_FILE="$2"; shift 2;;
        --help|-h) show_help; exit 0;;
        *) warn "Unknown option: $1"; shift;;
    esac
done

# Load configuration
set_default_config

# Try to load config file
if [[ -n "$CONFIG_FILE" ]]; then
    # User specified a config file
    load_config "$CONFIG_FILE" || {
        err "Failed to load config file: $CONFIG_FILE"
        exit 1
    }
elif [[ -f "$SCRIPT_DIR/scan.conf" ]]; then
    # Load default config if exists
    load_config "$SCRIPT_DIR/scan.conf"
elif [[ -f "$HOME/.zee-scanner.conf" ]]; then
    # Load user config from home directory
    load_config "$HOME/.zee-scanner.conf"
else
    info "No config file found, using defaults"
fi

# Validate inputs
info "Validating inputs..."
validate_foldername "$FOLDERNAME" || exit 1
validate_domain "$DOMAIN" || exit 1
validate_threads "$THREADS" || exit 1
ok "Input validation passed"

# Check required tools
info "Checking required tools..."
check_required_tools || exit 1

ensure_dir "$OUTDIR"
pushd "$OUTDIR" >/dev/null

SCAN_START_TIME=$(date +%s)

# Initialize logging and resume capability
init_log "$(pwd)"
info "Scan target: $DOMAIN | Threads: $THREADS | Output: $OUTDIR"
init_state "$(pwd)"

# Handle force restart
if [[ "$FORCE_RESTART" == "true" ]]; then
    clear_state
else
    resume_info
fi

# prompts (if not pre-answered)
[[ "$YES_JS" == "ask" ]] && YES_JS="$(prompt_yn 'Run JS Analysis?')"
[[ "$YES_PORTS" == "ask" ]] && YES_PORTS="$(prompt_yn 'Run Port Scanning?')"
[[ "$YES_SCREENSHOTS" == "ask" ]] && YES_SCREENSHOTS="$(prompt_yn 'Capture Screenshots?')"

# Calculate total steps based on enabled features
TOTAL_STEPS=7  # subdomains, probe, response_analysis, urls, categorize, report, delta
is_tool_enabled ENABLE_TAKEOVER && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$YES_PORTS" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$YES_SCREENSHOTS" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
[[ "$YES_JS" == "y" ]] && TOTAL_STEPS=$((TOTAL_STEPS + 1))
TOTAL_STEPS=$((TOTAL_STEPS + 1))  # export
CURRENT_STEP=0

next_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo -e "${BOLD}${BLUE}[${CURRENT_STEP}/${TOTAL_STEPS}]${RESET} ${BOLD}$1${RESET}"
    _log "STEP" "[$CURRENT_STEP/$TOTAL_STEPS] $1"
}

# pipeline with resume capability
next_step "Subdomain Enumeration"
if ! is_completed "subdomains"; then
    subdomains_step "$DOMAIN" "$(pwd)" && mark_completed "subdomains"
else
    info "Skipping subdomains (already completed)"
fi

next_step "HTTP Probing"
if ! is_completed "probe"; then
    probe_step "$(pwd)" "$THREADS" && mark_completed "probe"
else
    info "Skipping probing (already completed)"
fi

next_step "Response Analysis"
if ! is_completed "response_analysis"; then
    response_analysis_step "$(pwd)" && mark_completed "response_analysis"
else
    info "Skipping response analysis (already completed)"
fi

if is_tool_enabled ENABLE_TAKEOVER; then
    next_step "Subdomain Takeover Detection"
    if ! is_completed "takeover"; then
        takeover_step "$(pwd)" "$DOMAIN" "$THREADS" && mark_completed "takeover"
    else
        info "Skipping takeover detection (already completed)"
    fi
fi

# Run ports and screenshots in parallel (both depend only on clean_httpx.txt)
_run_ports=false
_run_screenshots=false

if [[ "$YES_PORTS" == "y" ]] && ! is_completed "ports"; then
    _run_ports=true
elif [[ "$YES_PORTS" == "y" ]]; then
    info "Skipping port scanning (already completed)"
fi

if [[ "$YES_SCREENSHOTS" == "y" ]] && ! is_completed "screenshots"; then
    _run_screenshots=true
elif [[ "$YES_SCREENSHOTS" == "y" ]]; then
    info "Skipping screenshots (already completed)"
fi

if [[ "$_run_ports" == "true" || "$_run_screenshots" == "true" ]]; then
    # Both get a step number even though they run in parallel
    [[ "$YES_PORTS" == "y" ]] && next_step "Port Scanning"
    [[ "$YES_SCREENSHOTS" == "y" ]] && next_step "Screenshot Capture"
    if [[ "$_run_ports" == "true" ]]; then
        ( ports_step "$(pwd)" "$THREADS" && mark_completed "ports" ) &
    fi
    if [[ "$_run_screenshots" == "true" ]]; then
        ( screenshots_step "$(pwd)" "$THREADS" && mark_completed "screenshots" ) &
    fi
    wait_jobs "ports+screenshots"
else
    # Still consume step numbers for skipped steps
    [[ "$YES_PORTS" == "y" ]] && next_step "Port Scanning"
    [[ "$YES_SCREENSHOTS" == "y" ]] && next_step "Screenshot Capture"
fi

# permutation_step "$(pwd)"

next_step "URL Discovery"
if ! is_completed "urls"; then
    urls_step "$(pwd)" "$THREADS" "$DOMAIN" && mark_completed "urls"
else
    info "Skipping URL discovery (already completed)"
fi

next_step "URL Categorization"
if ! is_completed "categorize"; then
    categorize_step "$(pwd)" && mark_completed "categorize"
else
    info "Skipping categorization (already completed)"
fi

if [[ "$YES_JS" == "y" ]]; then
    next_step "JavaScript Analysis"
    if ! is_completed "js"; then
        js_step "$(pwd)" && mark_completed "js"
    else
        info "Skipping JS analysis (already completed)"
    fi
fi

next_step "Report Generation"
if ! is_completed "report"; then
    report_step "$(pwd)" "$DOMAIN" "$SCAN_START_TIME" && mark_completed "report"
else
    info "Skipping report generation (already completed)"
fi

next_step "Delta Analysis"
if ! is_completed "delta"; then
    delta_step "$(pwd)" && mark_completed "delta"
else
    info "Skipping delta report (already completed)"
fi

next_step "Export"
if ! is_completed "export"; then
    python3 "$HACK/scripts/export_scan_supabase.py" "$FOLDERNAME" --subs "$OUTDIR/httpx.txt" && mark_completed "export"
else
    info "Skipping export (already completed)"
fi

ok "Scan completed successfully."
ok "Results saved in: $(pwd)"
popd >/dev/null
