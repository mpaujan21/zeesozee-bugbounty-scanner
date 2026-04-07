# Zee Scanner

Automates a fast recon pipeline for bug bounty hunting. The main `scan.sh` script orchestrates subdomain enumeration, probing, permutations, URL harvesting, sensitive file hunting, nuclei scans, and optional JavaScript analysis using widely adopted open-source tools.

## Highlights
- Runs multiple recon tools in parallel where possible to speed up discovery.
- Consolidates duplicate output into clean lists that feed later stages.
- Produces categorized URL collections, JS downloads, nuclei findings, and a quick Markdown summary.
- Offers interactive prompts (or flags) to skip time-consuming stages like port or JS analysis.

## Requirements
Install the following command-line tools and make sure they are available in your `PATH`:

- Enumeration: `subfinder`, `assetfinder`, `findomain`
- Probing & ports: `httpx`, `rustscan`, `dnsgen`, `dnsx`
- URL collection & cleaning: `waybackurls`, `gau`, `katana`, `uro`
- Categorization helpers: `gf`, `unfurl`
- Sensitive file hunting: `backupfinder`, `ffuf`
- JavaScript analysis (optional): `curl`, `prettier`, `python3`, LinkFinder (`$TOOLS/LinkFinder/linkfinder.py`), `trufflehog`

## Environment Variables
- `HACK`: Base output directory (defaults to `~/HACK`). Each scan writes under `"$HACK/<foldername>"`.
- `SCAN_THREADS`: Default thread count (overridden by `--threads`).
- `TOOLS`: Path that should contain supporting utilities such as `LinkFinder`.
- `HEADER`, `HEADER2`: Custom HTTP headers sent by the probing and crawling tools (defaults are defined in `lib/utils.sh`).

## Usage
Run scans from the repository root:

```bash
./scan.sh <foldername> <domain> [--threads N] [--yes-js y|n] [--yes-ports y|n]
```

Examples:

- `./scan.sh acme acme.com` – default threaded scan, prompts for JS/port stages.
- `./scan.sh acme acme.com --threads 80 --yes-js n --yes-ports y` – explicit choices with a custom concurrency level.

During execution the script:
1. Enumerates subdomains and probes for live hosts.
2. Optionally scans ports, generates permutations, and hunts for additional URLs.
3. Categorizes interesting URL patterns and gathers potential sensitive files.
4. Optionally downloads/analyzes JavaScript and runs nuclei.
5. Emits a Markdown summary to stdout plus structured files under the chosen output folder.

### Output Structure
Within `"$HACK/<foldername>"` expect files such as:

- `subdomains.txt`, `clean_httpx.txt`, `ips.txt`
- `ports/` (rustscan/httpx results per IP)
- `urls/`, `urls.txt`, `uro.txt`, and `categorized/` (gf & unfurl outputs)
- `sensitive/` (backup finder results, filtered file extensions)
- `js/` artifacts, `js.txt`, `linkfinder.txt`, `trufflehog.txt`
- `nuclei/critical_high.txt`, `nuclei/medium.txt` when enabled
- A brief Markdown report printed to the terminal

## Tips
- Keep third-party tools updated; several modules (`nuclei`, `katana`, etc.) evolve quickly.
- Consider setting up aliases or cron jobs to refresh templates (e.g., `nuclei -update-templates`).
- Review large outputs (like URLs) with additional filtering or custom scripts to focus on high-value findings.
