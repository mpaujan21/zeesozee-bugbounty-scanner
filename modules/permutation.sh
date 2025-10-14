#!/usr/bin/env bash
# shellcheck shell=bash

permutation_step() {
    local outdir="$1"
    ok "Performing subdomain permutation..."
    [[ -s "$outdir/clean_httpx.txt" ]] || { warn "No live subdomains; skipping permutations."; return; }
    
    command -v dnsgen >/dev/null || { warn "dnsgen not found; skipping."; return; }
    dnsgen "$outdir/clean_httpx.txt" > "$outdir/dnsgen.txt" 2>/dev/null
    
    cat "$outdir/dnsgen.txt" | dnsx -silent -a -resp -o "$outdir/dnsx.txt" 2>/dev/null
    
    cat "$outdir/dnsgen.txt" | httpx -silent -mc 200,201,202,203,204,301,302,307,401,403,405,500 > "$outdir/live_subdomains_permutation.txt" 2>/dev/null
    # TODO: altdns/permutation with AI
}
