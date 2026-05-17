# Zee Scanner — Recon Flow

## Pipeline Overview

```
subdomains → probe → takeover → screenshots → urls → categorize → js → report → delta → export
```

Each step is resumable. Completed steps tracked in `.scan_state` via atomic temp+mv writes.

---

## Step 1 — Subdomain Enumeration

All tools run **in parallel**:

| Tool | Mode | Notes |
|------|------|-------|
| `subfinder -all` | passive | all sources |
| `assetfinder --subs-only` | passive | |
| `findomain -q` | passive | |
| `amass enum -passive` | passive | |
| `chaos` | passive | requires `CHAOS_PDCP_API_KEY` |
| `crt.sh` API | passive | Certificate Transparency logs, no API key needed, `curl` + `jq` only |
| `rapiddns.io` | passive | DNS dataset, no API key needed, `curl` + `grep` only |

**Post-combine:**
1. Strip tool prefixes (`[subfinder]`, etc.) → dedup → `subdomains.txt`
2. **Wildcard detection** — 5 random probes via `dig`, compare resolved IPs. If all match = wildcard IP recorded
3. `dnsx` filters out wildcard-resolving subdomains
4. **Recursive enum** — finds zones matching `dev|staging|internal|corp|admin|api|test|qa|uat|preprod`, re-runs `subfinder` on each (max 5 zones), appends results

**Output:** `subdomains.txt`

---

## Step 2 — HTTP Probing

`httpx` probes all subdomains:

- Extracts: status code, title, tech stack, favicon hash, CDN, ASN, CNAME, web server, IP, response headers
- Timeout: 10s | Retries: 2 | Rate limit: 150 req/s

**Outputs:**
- `httpx.txt` — human-readable: `url [status] [title] [webserver] [tech] [ip]`
- `clean_httpx.txt` — plain URL list (input for all downstream steps)

---

## Step 3 — Port Scanning *(optional, `--yes-smap y`)*

Two-phase: passive Shodan lookup first, then active rustscan on discovered hosts.

### Phase 1 — Smap (passive, zero packets sent)

1. Extracts unique hostnames from `clean_httpx.txt`
2. `smap -iL targets -oG` — fetches port/service data from Shodan index
3. Parses greppable output → `host:port` pairs → `ports/smap_open.txt`
4. `httpx` probes discovered ports for HTTP services → `ports/smap_http.txt`

### Phase 2 — Rustscan (active, top 1000 ports)

1. Extracts unique hosts from `ports/smap_open.txt`
2. `rustscan -a hosts --top --no-banner -g` — active TCP connect scan
3. Parses greppable output → `host:port` pairs → `ports/rustscan_open.txt`
4. `httpx` probes newly discovered ports → `ports/rustscan_http.txt`

> Rustscan skipped if not installed or smap found no results.

**Outputs:** `ports/smap_open.txt`, `ports/smap_http.txt`, `ports/smap_greppable.txt`, `ports/rustscan_open.txt`, `ports/rustscan_http.txt`

---

## Step 4 — Subdomain Takeover Detection *(if `ENABLE_TAKEOVER=true`)*

1. `dnsx` batch-resolves CNAMEs for all subdomains → `takeover/cname_results.txt`
2. Matches CNAME values against **30 service fingerprints**:

   > GitHub Pages, Heroku, AWS S3, Shopify, Tumblr, Pantheon, Readme.io, Surge.sh, WordPress.com, Fly.io, Ghost, Fastly, Zendesk, Teamwork, Helpjuice, Help Scout, Cargo, Statuspage, Intercom, Tilda, Unbounce, Pingdom, Campaignmonitor, Acquia, Bitbucket, Smartling, Strikingly, Uptimerobot, Frontify

3. HTTP + HTTPS body confirmation on candidates via `curl` — checks body for error strings
4. Tags each result `[VULNERABLE]` or `[CANDIDATE]`

**Output:** `takeover/potential_takeovers.txt`

---

## Step 5 — Screenshots *(optional, `--yes-screenshots y`)*

`gowitness` screenshots all live hosts from `clean_httpx.txt`.

---

## Step 6 — URL Discovery

**Passive** (parallel):

| Tool | Source |
|------|--------|
| `waybackurls` | Wayback Machine |
| `waymore` | Wayback + extra archives |

**Active:**

| Tool | Notes |
|------|-------|
| `katana` | JS-aware crawler, follows links, skips static assets (png/jpg/css/fonts/etc.) |

**Post-collect:**
1. Combine all → scope filter (only `*.domain.com` URLs)
2. Liveness probe via `httpx -mc 200,301,302,401,403` → `urls.txt`
3. `unfurl format '%s://%d%p'` strips query strings → `urls_optimized.txt` (unique paths)

**Outputs:** `urls.txt`, `urls_optimized.txt`

---

## Step 7 — Categorization

Processes `urls.txt` / `urls_optimized.txt`:

| Output | Tool | What |
|--------|------|------|
| `categorized/php_errors.txt` | `gf php-errors` | PHP error URLs |
| `categorized/keypairs.txt` | `unfurl keypairs` | `param=value` pairs |
| `categorized/paths.txt` | `unfurl paths` | unique paths |
| `js.txt` | awk | `.js` file URLs → JS step input |
| `categorized/json_files.txt` | awk | `.json` file URLs |
| `categorized/sourcemaps.txt` | awk | `.map` file URLs |

---

## Step 8 — JavaScript Analysis *(optional, `--yes-js y`)*

**Delta-aware:** checks `js/.seen_urls.txt` manifest, skips already-processed URLs.

### Download Phase

Groups URLs by hostname (avoids rate-limit blocks). Per-host workers download sequentially, scan each file **immediately after download**:

```
curl → js/files/<domain>_<hash>_<filename>.js
  ├── jsluice urls   → URL extraction from JS AST
  └── jsluice secrets → hardcoded secrets (API keys, tokens)
  └── LinkFinder     → regex-based endpoint extraction
```

Atomic progress bar via `flock` across parallel host workers.

### Post-Download Phase

Runs after all files downloaded:

| Tool | Finds |
|------|-------|
| `trufflehog filesystem` | verified secrets (high signal) |
| `jshunter` | JWT tokens, Firebase configs, GraphQL endpoints, hidden params |

### Outputs (`js/analysis/`)

| File | Content |
|------|---------|
| `all_endpoints.txt` | jsluice + LinkFinder combined |
| `jsluice_secrets.txt` | raw secrets from jsluice |
| `trufflehog.txt` | verified secrets with detector name |
| `jshunter_jwt.txt` | JWT tokens |
| `jshunter_firebase.txt` | Firebase configs/URLs |
| `jshunter_graphql.txt` | GraphQL endpoints |
| `jshunter_params.txt` | hidden parameters |
| `sourcemaps.txt` | source map URLs (may contain original source) |

Raw JS files deleted after analysis to save storage.

---

## Step 9 — Report

Generates `report.md` + `report.json`:
- Per-tool result counts
- Tool effectiveness metrics
- Total scan duration

---

## Step 10 — Delta Analysis

Snapshots current findings to `.snapshots/<timestamp>/`. Diffs against previous snapshot via `comm -13`:

| Tracked | File |
|---------|------|
| Subdomains | `subdomains.txt` |
| Live Hosts | `clean_httpx.txt` |
| URLs | `urls.txt` |
| JS Endpoints | `js/analysis/all_endpoints.txt` |
| Secrets | `js/analysis/trufflehog.txt` |
| Takeovers | `takeover/potential_takeovers.txt` |
| GF Patterns | `categorized/*.txt` |

Keeps max 5 snapshots (prunes oldest). Outputs `delta.md` + `delta.json`.

---

## Step 11 — Export

`export_scan_supabase.py` pushes live hosts from `clean_httpx.txt` to Supabase.

---

## Key Files Reference

```
$OUTDIR/
├── subdomains.txt          # all unique subdomains
├── wildcard_ip.txt         # wildcard IP (if detected)
├── httpx.txt               # human-readable probe results
├── clean_httpx.txt         # live host URLs (plain list)
├── urls.txt                # all live URLs
├── urls_optimized.txt      # deduped by path (no query strings)
├── js.txt                  # JS file URLs
├── categorized/            # gf patterns, keypairs, paths, json, sourcemaps
├── js/
│   ├── .seen_urls.txt      # manifest for delta JS skipping
│   └── analysis/           # all JS analysis outputs
├── takeover/
│   ├── cname_results.txt
│   └── potential_takeovers.txt
├── .snapshots/             # timestamped delta snapshots (max 5)
├── .scan_state             # resume state
├── scan.log                # full timestamped log
├── report.md / report.json
└── delta.md / delta.json
```
