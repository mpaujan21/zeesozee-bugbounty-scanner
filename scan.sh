#!/bin/bash

set -euo pipefail

# load libs
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/colors.sh"
. "$SCRIPT_DIR/lib/utils.sh"

# load modules
for mod in subdomains probing ports permutation urls categorize sensitive js report; do
    . "$SCRIPT_DIR/modules/${mod}.sh"
done

banner

# args + flags
if [[ $# -lt 2 ]]; then
    err "Usage: $0 <foldername> <domain> [--yes-js y|n] [--yes-ports y|n] [--threads N]"
    echo "Example: $0 Example example.com --threads 80"
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
        *) warn "Unknown option: $1"; shift;;
    esac
done

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
report_step "$(pwd)" "$DOMAIN" "$YES_NUCLEI"
python3 "$HACK/scripts/export_scan_supabase.py" "$FOLDERNAME" --subs "$OUTDIR/httpx.txt"

ok "Scan completed successfully."
ok "Results saved in: $(pwd)"
popd >/dev/null
