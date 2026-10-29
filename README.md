# ArtCraft Suite Manager

A single-file PowerShell script that audits, installs and updates the whole **ArtCraft** app suite (plus the ArtCraft Launcher) on Windows — one run, no interaction, no GUI.

It was born as a lightweight alternative updater for older and slower machines, where the official launcher felt heavy for what is essentially "check a version number, download an MSI, run it quietly". Since then it has grown into a full state-reconciliation tool: it detects what is actually installed (even when the registry and winget disagree), resolves the newest release straight from the GitHub API, and only touches the apps that genuinely need it.

## Origin & credits

The initial idea comes from this community post:

**[Lightweight ArtCraft app updater for older/slow [PCs] — r/ArtCraftAI](https://www.reddit.com/r/ArtCraftAI/comments/1xc0uty/lightweight_artcraft_app_updater_for_olderslow/)**

That concept has since evolved well beyond a simple "download and run the installer" loop. Notable additions over the original approach:

- Normalized name matching, so `ArtCraft Launcher`, `artcraft-launcher` and `ArtCraft_Launcher` are all recognized as the same product
- ProductCode (uninstall GUID) detection as a fallback when winget and the registry report different identifiers
- Dynamic latest-version lookup via the GitHub Releases API instead of hardcoded URLs
- MSI signature validation before execution
- Proper msiexec exit-code handling, including a retry on `1618`
- Pre-install process termination to avoid file locks
- A same-version guard that skips pointless reinstalls
- Local version cache to minimize GitHub API calls across lab machines

## What it does

For each of the 14 suite applications the script answers three questions:

1. **Is it installed?** — checked via filesystem probes, `winget list`, and the Windows uninstall registry
2. **What version is it?** — read from the executable's `ProductVersion`, falling back to the registry `DisplayVersion`
3. **Is there something newer?** — queried live from the corresponding GitHub repository's latest release

Based on the answers it then does exactly one of four things: **skip**, **upgrade via winget**, **upgrade via MSI**, or **fresh install**. At the end it prints a summary and sets the process exit code.

## Managed applications

| App | winget ID | GitHubUser | GitHub repo | Executable |
|---|---|---|---|---|
| ArtCraftLauncher | `ArtCraft.ArtCraftLauncher` | `storytold` | `craft-launcher` | `ArtCraftLauncher.exe` |
| PhotoCraft | `ArtCraft.PhotoCraft` | `storytold` | `photocraft` | `PhotoCraft.exe` |
| VectorCraft | `ArtCraft.VectorCraft` | `storytold` | `vectorcraft` | `VectorCraft.exe` |
| PdfCraft | `ArtCraft.PdfCraft` | `storytold` | `pdfcraft` | `PdfCraft.exe` |
| WordCraft | `ArtCraft.WordCraft` | `storytold` | `wordcraft` | `WordCraft.exe` |
| GridCraft | `ArtCraft.GridCraft` | `storytold` | `gridcraft` | `GridCraft.exe` |
| LightCraft | `ArtCraft.LightCraft` | `storytold` | `lightcraft` | `LightCraft.exe` |
| FilmCraft | `ArtCraft.FilmCraft` | `storytold` | `filmcraft` | `FilmCraft.exe` |
| DesignCraft | `ArtCraft.DesignCraft` | `storytold` | `designcraft` | `DesignCraft.exe` |
| EffectCraft | `ArtCraft.EffectCraft` | `storytold` | `effectcraft` | `EffectCraft.exe` |
| DeckCraft | `ArtCraft.DeckCraft` | `storytold` | `deckcraft` | `DeckCraft.exe` |
| CADCraft | `ArtCraft.CadCraft` | `storytold` | `cadcraft` | `CADCraft.exe` |
| SoundCraft | `ArtCraft.SoundCraft` | `storytold` | `soundcraft` | `SoundCraft.exe` |
| FigCraft | `ArtCraft.FigCraft` | `tangency-labs` | `figcraft` | `FigCraft.exe` |

Adding another app is a one-line change — see [Configuration](#configuration).

## How it works

### 1. Installation detection

An app counts as installed if **any** of these is true:

- One of the probed paths exists (`%ProgramFiles%`, `%ProgramFiles(x86)%`, `%LOCALAPPDATA%\Programs`, plus a few explicit spelling variants of the launcher folder)
- The winget ID appears in `winget list`
- The uninstall **ProductCode** (GUID) appears in `winget list`
- A matching entry is found in the uninstall registry

Registry scanning covers all three relevant hives: `HKLM\...\Uninstall`, `HKLM\WOW6432Node\...\Uninstall` and `HKCU\...\Uninstall`. Matching is done on a **normalized** display name — spaces, hyphens and underscores are stripped and the comparison is case-insensitive and substring-based — which is what makes the script survive inconsistent naming between installer builds.

### 2. Version resolution

The newest release is fetched from:

```
GET https://api.github.com/repos/<owner>/<repo>/releases/latest
```

with a proper `User-Agent` and `Accept: application/vnd.github+json` header and a 45-second timeout. From the response the script picks the first `*.msi` asset, preferring x64/AMD64 builds over anything else, and strips the leading `v` from the tag name.

**Cache behavior:**

- **First run:** All 14 releases are fetched from GitHub API; results are saved to a JSON file
- **Subsequent runs (within 24h):** Cached versions are reused — **zero API calls**
- **Expired entry (>24h):** Individual entries expire separately based on their own timestamp, not a global file timestamp
- **API failure:** If GitHub is unreachable, stale cache entries are still used to avoid blocking the entire run

Cache file locations:

| `$VersionCachePathOverride` | Location |
|------------------------------|----------|
| Empty (default) | Same folder as the script |
| Folder path | `<path>/artcraft-version-cache.json` |
| File path (ends in `.json`) | Exact file path |

This allows you to either keep a per-machine cache or share one cache file across an entire lab via a network share.

**Comparison uses .NET `[version]` objects** rather than string comparison, after trimming pre-release/build suffixes, so `0.9.0` vs `0.10.0` is ordered correctly.

### 3. Decision logic

| State | Remote version | Action |
|---|---|---|
| Installed | equal to local | Skip ("already at latest version") |
| Installed | newer | `winget upgrade` → on failure `winget upgrade --force` → on failure silent MSI |
| Installed | older or unparsable | Skip |
| Missing | any | `winget install`, verified with `winget list` → on failure silent MSI |
| Any | GitHub lookup failed | Reported, app treated as OK (installed) or skipped (missing) |

### 4. Silent MSI installation

When winget can't do the job, the script falls back to the release asset:

1. If an upgrade or fresh install is needed, the script checks if the versioned installer (e.g., `PhotoCraft-1.2.0.msi`) is already present in the target cache folder (`$VersionCachePathOverride` or the script folder).
2. **Validates the file** by reading its first four bytes and checking for the OLE compound-document magic number `D0 CF 11 E0` — this catches the classic failure mode where an error page or redirect gets saved as `.msi`
3. If present, downloading is skipped completely.
5. If missing, it downloads to `.part`, validates the file signature (`D0 CF 11 E0`), and renames it.
6. Terminates any running instance of the app to avoid file locks
7. Runs `msiexec /i "<msi>" /qn /norestart /L*v "<log>"`
8. Interprets the exit code properly (see below)
9. Keeps the downloaded MSI for future usage

### 5. Exit-code handling

| Code | Meaning | Behaviour |
|---|---|---|
| `0` | Success | Continue |
| `3010` | Success, reboot required | Counted as success, warning printed |
| `1641` | Success, reboot initiated | Counted as success, warning printed |
| `1618` | Another installation in progress | Waits 15 s and retries once |
| anything else | Failure | Prints the exit code, the log path, and a manual `msiexec` command to try |

### 6. API resilience

Every GitHub call is wrapped in a try/catch with an explicit timeout. If a request fails — rate limiting, network hiccup, outage, a repo without an MSI asset — the script logs the reason and moves on instead of aborting. Installed apps are then simply considered current, and missing ones are marked as failed.

This matters because the script makes one API call per app (~14 per run): treating a rejected request as a fatal error would turn a single throttled call into a cascade of bogus failures, and retrying aggressively would only make the throttling worse. Failing soft and continuing is the deliberate strategy here.

Combined with the local cache, this keeps unauthenticated API usage well within API limit per public IP, even when many machines all run the script within a day.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1+ (works in PowerShell 7 too)
- [winget](https://aka.ms/getwinget) / App Installer — strongly recommended; without it the script falls back to MSI-only operation
- Internet access to `api.github.com` and GitHub release assets
- An **elevated** shell is recommended: machine-wide MSI installs and `HKLM` registry reads generally require administrator rights

## Usage

```powershell
# Recommended: run from an elevated PowerShell window
powershell -ExecutionPolicy Bypass -File .\Install-Update-ArtCraftApps.ps1
```

Or, from inside a PowerShell session:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-Update-ArtCraftApps.ps1
```

The script is fully unattended: it prints a progress line per app (`[3/14] Processing VectorCraft...`) and finishes with a summary such as:

```
========================================
Summary:
  Successful: 14 / 14
  Failed:     0 / 14
Architecture sync complete.
```

### Exit codes

- `0` — every app ended up installed and current
- `1` — at least one app failed (the names are listed in the summary)

This makes it easy to chain from Task Scheduler or CI.

## Logs & troubleshooting

- Per-app MSI log: `%TEMP%\<AppName>-msi.log`
- Downloaded installer: `%TEMP%\<AppName>-bootstrap.msi` (removed after a successful run)
- Winget operation log: %TEMP%\<AppName>-winget.log
- Version cache: Same folder as script (or configured via $VersionCachePathOverride)

Common causes of failure and what the script tells you:

- **"The file is not a valid MSI (probably an HTML page)"** — the download URL returned markup rather than a binary; usually a changed asset name or a captive portal/proxy interfering
- **"No MSI asset found in release …"** — the release exists but ships no `.msi`
- **"Another installation is in progress (1618)"** — Windows Installer service busy; the script retries once, and suggests waiting or rerunning
- **"Cache MISS for <repo>. Querying GitHub API..."** — cache expired or absent; this is normal on first run or after 24 hours
- **"GitHub API rate limit reached (HTTP 403)"** — you've hit the anonymous rate limit; wait for reset or increase the cache TTL
- **Non-zero msiexec code** — the printed log path holds the verbose MSI log, and the script echoes a manual `msiexec /i …` command you can run interactively

## Configuration

Everything lives in two places at the top of the file.

### GitHub account

Change the GitHub account that hosts the releases:

```powershell
$gitHubUser = "storytold"
```

### Winget Toggle (`$UseWinget`)

```powershell
$UseWinget = $false
```
- `$false` *(Default)*: Operates purely via direct GitHub MSI downloads. Skips `winget` queries entirely for faster execution and guaranteed per-machine installation scope (`ALLUSERS=1`).
- `$true`: Enables winget-first operations where appropriate (with automatic fallback to MSI for machine-scoped packages).
  
### Application definitions

Add or remove apps by editing the definition array. The format is
`Name|WingetId|GitHubRepo|ExeName`:

```powershell
$appDefs = @(
    "ArtCraftLauncher|ArtCraft.ArtCraftLauncher|craft-launcher|ArtCraftLauncher.exe",
    # ...
    "MyNewCraft|ArtCraft.MyNewCraft|mynewcraft|MyNewCraft.exe"
)
```

Malformed entries (wrong field count or empty fields) are skipped with a warning instead of crashing the run.

### Cache & MSI Storage Location (`$VersionCachePathOverride`)

By default, the version cache and MSI storage sits next to the script. To move it to a shared folder for lab-wide coordination:

```powershell
# Store in a custom folder (default filename appended)
$VersionCachePathOverride = '\\fileserver\software\artcraft'

# Or specify the exact file path
$VersionCachePathOverride = '\\fileserver\software\artcraft\cache.json'

# Keep the default (script folder)
$VersionCachePathOverride = ''
```

If the folder doesn't exist, it will be created automatically. Multiple machines pointing to the same cache file means only one machine does the GitHub lookups; the rest reuse the cached versions until the 24-hour expiry.

### Cache TTL (`$VersionCacheTTLHours`)

How long a cached version lookup stays valid (in hours):
```powershell
$VersionCacheTTLHours = 24  # default
```

Increasing this value reduces API calls further at the cost of potentially staying on an older version for longer.

## Known limitations & cautions

- **Process termination is heuristic.** Before installing, the script derives a keyword from the app name (e.g. `PhotoCraft` → `photo`) and stops any process whose name *contains* it. Because it is a substring match, it can in principle hit unrelated processes with a coincidentally similar name. Tightening this to exact process-name matching is a sensible hardening step.
- **Unauthenticated GitHub API calls.** The script sends no token, so it is subject to the standard anonymous rate limit. Running it many times per hour may trigger throttling; the soft-fail behaviour keeps that harmless, but it also means updates can be silently reported as "up to date" during a throttle window. Supplying a `GITHUB_TOKEN` and/or caching the release lookup would remove that blind spot.
- **No rollback.** Once an MSI install starts, the script cannot revert it; use the MSI log if something goes wrong.
- **Windows only.** The suite ships for macOS and Linux too, but this script targets Windows/MSI/winget exclusively.

## Disclaimer

This is an independent, community-made utility. It is not affiliated with or endorsed by the ArtCraft project. It downloads and executes installers published in the configured GitHub repositories — review the source before running it, and prefer running it against repositories you trust.
