#!/bin/bash

set -euo pipefail

# load libs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/colors.sh"
. "$SCRIPT_DIR/lib/utils.sh"
. "$SCRIPT_DIR/lib/validation.sh"
. "$SCRIPT_DIR/lib/fileops.sh"

# load modules
for mod in subdomains probing ports permutation urls categorize sensitive js report; do
    . "$SCRIPT_DIR/modules/${mod}.sh"
done

show_help() {
    cat <<EOF
${BOLD}${BLUE}Zee Scanner - Bug Bounty Reconnaissance Automation${RESET}

${BOLD}Usage:${RESET}
  $0 <foldername> <domain> [OPTIONS]

${BOLD}Required Arguments:${RESET}
  foldername    Output directory name (created in \$HACK/)
  domain        Target domain to scan

${BOLD}Options:${RESET}
  --threads N     Number of concurrent threads (default: 50, range: 1-1000)
  --yes-js y|n    Enable JavaScript analysis (interactive if not specified)
  --yes-ports y|n Enable port scanning (interactive if not specified)
  --help          Show this help message

${BOLD}Examples:${RESET}
  $0 acme acme.com
  $0 acme acme.com --threads 80 --yes-js y --yes-ports n
  $0 bugcrowd bugcrowd.com --threads 100

${BOLD}Environment Variables:${RESET}
  HACK           Output base directory (default: ~/HACK)
  SCAN_THREADS   Default thread count (default: 50)

${BOLD}Output:${RESET}
  Results saved to: \$HACK/<foldername>/
  Final report: \$HACK/<foldername>/report.md
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

HACK="${HACK:-$HOME/HACK}"; FOLDERNAME="$1"; OUTDIR="${HACK%/}/$1"; DOMAIN="$2"; shift 2
THREADS="${SCAN_THREADS:-50}"
YES_JS="ask"; YES_PORTS="ask"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threads) THREADS="${2:-$THREADS}"; shift 2;;
        --yes-js) YES_JS="${2:-ask}"; shift 2;;
        --yes-ports) YES_PORTS="${2:-ask}"; shift 2;;
        --help|-h) show_help; exit 0;;
        *) warn "Unknown option: $1"; shift;;
    esac
done

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

# prompts (if not pre-answered)
[[ "$YES_JS" == "ask" ]] && YES_JS="$(prompt_yn 'Run JS Analysis?')"
[[ "$YES_PORTS" == "ask" ]] && YES_PORTS="$(prompt_yn 'Run Port Scanning?')"

# pipeline
subdomains_step "$DOMAIN" "$(pwd)"
probe_step "$(pwd)" "$THREADS"
[[ "$YES_PORTS" == "y" ]] && ports_step "$(pwd)" "$THREADS"
# permutation_step "$(pwd)"
urls_step "$(pwd)" "$THREADS" "$DOMAIN"
categorize_step "$(pwd)"
sensitive_step "$(pwd)" "$THREADS"
[[ "$YES_JS" == "y" ]] && js_step "$(pwd)"
report_step "$(pwd)" "$DOMAIN"
python3 "$HACK/scripts/export_scan_supabase.py" "$FOLDERNAME" --subs "$OUTDIR/httpx.txt"

ok "Scan completed successfully."
ok "Results saved in: $(pwd)"
popd >/dev/null
