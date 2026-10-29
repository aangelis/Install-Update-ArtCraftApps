<#
    ArtCraft Suite Manager - Update or Install (Fixed Version v2)
    - Normalized name matching (handles spaces, hyphens, underscores)
    - ProductCode detection fallback for mixed registry scenarios
    - Dynamic latest version retrieval from GitHub API
    - Verifies downloaded file is a valid MSI
    - Correct exit code handling: 0, 3010, 1641, 1618 (retry)
    - Pre-install process termination to avoid file locks
    - Safe version guard (skip if same version detected)

    New in v3:
    - Force ALLUSERS=1 for per-machine installations
    - Explicit scope handling to prevent user/machine mismatches
    - ProductCode variable escaping in Remove-ExistingInstallation
    - Exact process-name matching (previous fuzzy match was dangerously broad)
    - Winget logging to $env:TEMP with captured output and exit code
    - Invalid -f parameter on Add-Content and -equivalent typo

    New in v4:
    - Skip the winget upgrade path for machine-scoped installations.
      Reason: winget invokes the MSI WITHOUT ALLUSERS=1. The MSI then falls
      back to per-user (MSIINSTALLPERUSER=1) and its own LaunchCondition
      aborts with "This app is already installed for everyone" -> msiexec
      exit code 1603 -> winget 0x8A150049 (APPINSTALLER_CLI_ERROR_MSI_INSTALL_FAILED).
      This is deterministic, not intermittent: once the script has installed
      an app per-machine, winget can never upgrade it.
    - Informational pending-reboot check before processing begins.

    New in v5:
    - Local version cache (24h TTL) to reduce GitHub API calls
    - Graceful degradation when API rate-limited

    New in v6:
    - Configurable cache location via $VersionCachePathOverride.
    - Freshness is evaluated per cache entry (CachedAt) instead of once for
      the whole file, so entries fetched at different times expire separately.
    - A stale cache entry is still served if the GitHub lookup fails, instead
      of failing the application outright.
    - Cache writes go through a temporary file and a rename, so a reader never
      sees a half-written file (matters when the cache sits on a share).
    - API call / cache hit counters in the summary.

    New in v7:
    - New $UseWinget configuration switch (default $false). When the variable
      is missing, empty or $false, winget is never used at all: no startup
      "winget list" / "winget upgrade" probes, no "winget install", no
      "winget upgrade". Every application is installed or updated from the MSI
      attached to the latest GitHub release, always with ALLUSERS=1 (per-machine).
      Setting it to $true restores the previous winget-first behaviour.
    - MSI packages are downloaded into the folder that contains this script
      instead of $env:TEMP, and they are kept there, so a later run of the
      script reuses the package already on disk instead of downloading it
      again. The file name contains the release version, so a package is only
      reused for the version it actually belongs to.
    - Downloads land in a ".part" file and are renamed only after the MSI
      signature check passes, so a truncated download or an HTML error page
      can never survive as a reusable package.
    - If the script folder is not writable, the download folder falls back to
      $env:TEMP automatically.

    New in v8:
    - MSI package download directory now respects $VersionCachePathOverride.
      When this variable is set, both the version cache AND the MSI packages
      are stored in the same location (either the path itself or the folder
      containing it if the path ends in .json).

    New in v9:
    - Enhanced error tracking and summary diagnostics for per-application execution results.
    - Expanded individual repository mapping support (e.g., SolidCraft under tangency-labs).

#>

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ======================= LOCAL CONFIGURATION =======================
# ---- Winget switch ----
#
#   $UseWinget = $false        (or the variable deleted / left empty)
#       winget is never touched. No "winget list", no "winget upgrade",
#       no "winget install". Every application is installed or updated from
#       the MSI published on the latest GitHub release, always with
#       ALLUSERS=1 (per-machine).
#
#   $UseWinget = $true
#       winget is used exactly as before: a missing application is installed
#       with "winget install" first, and an available update is applied with
#       "winget upgrade" - except when the existing installation is
#       machine-scoped, because winget cannot pass ALLUSERS=1.
#
#   String values ('true' / 'false') are accepted as well, so the setting can
#   be driven from a wrapper script, a scheduled task or a build pipeline.
$UseWinget = $false

# ---- Version cache location override ----
#
#   Leave the value empty ('') to keep the cache file in the same folder as
#   this script. Recommended for a standalone machine, or for a script that is
#   copied onto every machine.
#
#   Set it to a path to keep the cache elsewhere - typically a shared folder,
#   so that every machine in a lab reuses one set of GitHub lookups:
#
#       $VersionCachePathOverride = '\\fileserver\software\artcraft'
#       $VersionCachePathOverride = '\\fileserver\software\artcraft\cache.json'
#
#   A value ending in ".json" is treated as the full cache file path. Any other
#   value is treated as a folder and the default file name is appended to it.
#   NOTE: The same path (or its folder) is now ALSO used for MSI package storage.
#
#   If this variable is deleted or left blank, the script silently falls back
#   to the script folder for both cache and MSI packages. No API keys or tokens
#   are ever required.
$VersionCachePathOverride = ''

# How long a cached version lookup stays valid, in hours.
$VersionCacheTTLHours = 24
# ===================================================================

$defaultCacheFileName = 'artcraft-version-cache.json'

# ---------- Locate the folder this script lives in ----------

# $PSScriptRoot covers -File and dot-sourcing; the fallbacks cover unusual hosts.
$scriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptDir)) {
    if ($MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
    }
    elseif ($MyInvocation.MyCommand.Definition) {
        $scriptDir = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
    }
    else {
        $scriptDir = (Get-Location).Path
    }
}

# ---------- Resolve the winget switch ----------
# Read defensively: the variable may have been removed from the script, and it
# may hold a boolean or a string such as 'true' / 'false'.
$wingetEnabled = $false
$wingetVariable = Get-Variable -Name 'UseWinget' -Scope Script -ErrorAction SilentlyContinue
if ($wingetVariable -and $null -ne $wingetVariable.Value) {
    $wingetValue = $wingetVariable.Value
    if ($wingetValue -is [bool]) {
        $wingetEnabled = $wingetValue
    }
    elseif ($wingetValue -is [string]) {
        $parsedBool = $false
        if (-not [string]::IsNullOrWhiteSpace($wingetValue) -and
            [bool]::TryParse($wingetValue.Trim(), [ref]$parsedBool)) {
            $wingetEnabled = $parsedBool
        }
    }
    else {
        try { $wingetEnabled = [bool]$wingetValue } catch { $wingetEnabled = $false }
    }
}

# ---------- Resolve the cache location ----------

# Read the override defensively: it may have been removed from the script.
$cacheOverride = $null
$overrideVariable = Get-Variable -Name 'VersionCachePathOverride' -Scope Script -ErrorAction SilentlyContinue
if ($overrideVariable) { $cacheOverride = $overrideVariable.Value }

if (-not [string]::IsNullOrWhiteSpace($cacheOverride)) {
    if ($cacheOverride -match '\.json$') {
        $cacheFile = $cacheOverride
    }
    else {
        $cacheFile = Join-Path $cacheOverride $defaultCacheFileName
    }
    $cacheSource = 'override'
}
else {
    $cacheFile   = Join-Path $scriptDir $defaultCacheFileName
    $cacheSource = 'script folder'
}

$cacheTTLHours = $VersionCacheTTLHours

# Make sure the destination folder exists (relevant for the override case).
$cacheDir = Split-Path -Parent -Path $cacheFile
if ($cacheDir -and -not (Test-Path -LiteralPath $cacheDir)) {
    try {
        $null = New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Warning: Cannot create cache folder '$cacheDir': $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

# ---------- Resolve the MSI download folder ----------
# MSI packages are stored in the same location as the version cache (when
# overridden) or in the script folder (when using default). This allows
# subsequent runs to reuse downloaded packages without re-fetching them.
$downloadDir = $cacheDir
$downloadDirWritable = $false

if ($downloadDir -and (Test-Path -LiteralPath $downloadDir)) {
    try {
        $writeProbe = Join-Path $downloadDir '.artcraft-write-probe.tmp'
        Set-Content -LiteralPath $writeProbe -Value 'probe' -Encoding ASCII -ErrorAction Stop
        Remove-Item -LiteralPath $writeProbe -Force -ErrorAction SilentlyContinue
        $downloadDirWritable = $true
    }
    catch {
        $downloadDirWritable = $false
    }
}

if (-not $downloadDirWritable) {
    Write-Host "Warning: '$downloadDir' is not writable. MSI packages will be stored in $env:TEMP instead." -ForegroundColor DarkYellow
    $downloadDir = $env:TEMP
}

# Counters, reported in the summary.
$script:apiCallCount  = 0
$script:cacheHitCount = 0

# MSI packages touched during this run, reported in the summary.
$script:usedPackages = @()

# Winget error code emitted when the underlying MSI fails.
$WINGET_ERROR_MSI_INSTALL_FAILED = -1978335159   # 0x8A150049

# Format: Name|WingetId|GitHubUser|GitHubRepo|ExeName
$appDefs = @(
    "ArtCraftLauncher|ArtCraft.ArtCraftLauncher|storytold|craft-launcher|ArtCraftLauncher.exe",
    "PhotoCraft|ArtCraft.PhotoCraft|storytold|photocraft|PhotoCraft.exe",
    "VectorCraft|ArtCraft.VectorCraft|storytold|vectorcraft|VectorCraft.exe",
    "PdfCraft|ArtCraft.PdfCraft|storytold|pdfcraft|PdfCraft.exe",
    "WordCraft|ArtCraft.WordCraft|storytold|wordcraft|WordCraft.exe",
    "GridCraft|ArtCraft.GridCraft|storytold|gridcraft|GridCraft.exe",
    "LightCraft|ArtCraft.LightCraft|storytold|lightcraft|LightCraft.exe",
    "FilmCraft|ArtCraft.FilmCraft|storytold|filmcraft|FilmCraft.exe",
    "DesignCraft|ArtCraft.DesignCraft|storytold|designcraft|DesignCraft.exe",
    "EffectCraft|ArtCraft.EffectCraft|storytold|effectcraft|EffectCraft.exe",
    "DeckCraft|ArtCraft.DeckCraft|storytold|deckcraft|DeckCraft.exe",
    "CADCraft|ArtCraft.CadCraft|storytold|cadcraft|CADCraft.exe",
    "SoundCraft|ArtCraft.SoundCraft|storytold|soundcraft|SoundCraft.exe",
    "FigCraft|ArtCraft.FigCraft|storytold|figcraft|FigCraft.exe",
    "SolidCraft|ArtCraft.SolidCraft|tangency-labs|solidcraft|SolidCraft.exe"
)

# ---------- Version cache ----------

function Get-VersionCache {
    <#
        Reads the version cache file and returns it as a Hashtable keyed by
        "owner/repo". Returns $null when the file is missing, empty or
        unreadable.

        ConvertFrom-Json produces PSCustomObject instances, which do not
        support ContainsKey() or indexed assignment, so the object graph is
        rebuilt as a Hashtable here.

        Freshness is NOT decided here. Each entry carries its own CachedAt
        stamp and is judged individually, so entries fetched at different
        times expire independently.
    #>
    if (-not (Test-Path -LiteralPath $cacheFile)) { return $null }

    try {
        $raw = Get-Content -LiteralPath $cacheFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

        $cacheData = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $cacheData.Versions) { return $null }

        $table = @{}
        foreach ($prop in $cacheData.Versions.PSObject.Properties) {
            $table[$prop.Name] = $prop.Value
        }
        return $table
    }
    catch {
        Write-Host "  -> Warning: Could not read version cache: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $null
    }
}

function Get-CacheFileTimestamp {
    <# Last write time of the cache file, used as a fallback timestamp for
       entries written by older versions of this script that did not record
       a CachedAt value. #>
    try {
        return (Get-Item -LiteralPath $cacheFile -ErrorAction Stop).LastWriteTime
    }
    catch {
        return $null
    }
}

function Test-CacheEntryFresh {
    param($Entry, $FallbackTimestamp)

    if (-not $Entry) { return $false }

    $timestamp = $FallbackTimestamp
    if ($Entry.CachedAt) {
        try {
            $timestamp = [datetime]::Parse($Entry.CachedAt, [Globalization.CultureInfo]::InvariantCulture)
        }
        catch { }
    }

    if (-not $timestamp) { return $false }
    return (((Get-Date) - $timestamp).TotalHours -le $cacheTTLHours)
}

function Set-VersionCache {
    param([hashtable]$Versions)

    try {
        $cacheObj = [pscustomobject]@{
            LastUpdated = (Get-Date).ToString('o')
            Versions    = $Versions
        }

        $cacheJson = $cacheObj | ConvertTo-Json -Depth 6

        # Write to a temporary file, then swap it in. A reader (or a second
        # machine writing to a shared override path) therefore never observes
        # a partially written cache file.
        $tempFile = "$cacheFile.tmp"
        Set-Content -LiteralPath $tempFile -Value $cacheJson -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempFile -Destination $cacheFile -Force -ErrorAction Stop
    }
    catch {
        Write-Host "  -> Warning: Could not save version cache: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Get-GitHubRelease-Cached {
    <#
        Returns release info for owner/repo.

        Order of preference:
          1. A cache entry younger than $cacheTTLHours -> no API call at all.
          2. A live GitHub API lookup                 -> result is cached.
          3. A stale cache entry, if the lookup fails -> better than nothing.

        The cache is what keeps a whole lab behind one NAT address comfortably
        inside the 60 requests/hour unauthenticated GitHub API limit.
    #>
    param([string]$Owner, [string]$Repo)

    $key = "$Owner/$Repo"

    $cache         = Get-VersionCache
    $fileTimestamp = Get-CacheFileTimestamp

    $entry = $null
    if ($cache -and $cache.ContainsKey($key)) { $entry = $cache[$key] }

    if (Test-CacheEntryFresh -Entry $entry -FallbackTimestamp $fileTimestamp) {
        $script:cacheHitCount++
        Write-Host "  -> Cache HIT for $Repo (version $($entry.Version))" -ForegroundColor Gray
        return [pscustomobject]@{
            Version = $entry.Version
            Url     = $entry.Url
            Asset   = $entry.Asset
        }
    }

    if ($entry) {
        Write-Host "  -> Cache entry for $Repo is older than ${cacheTTLHours}h. Querying GitHub API..." -ForegroundColor Gray
    }
    else {
        Write-Host "  -> Cache MISS for $Repo. Querying GitHub API..." -ForegroundColor Gray
    }

    $script:apiCallCount++
    $release = Get-GitHubRelease -Owner $Owner -Repo $Repo

    if (-not $release) {
        if ($entry) {
            Write-Host "  -> GitHub lookup failed. Falling back to stale cached entry ($($entry.Version))." -ForegroundColor DarkYellow
            return [pscustomobject]@{
                Version = $entry.Version
                Url     = $entry.Url
                Asset   = $entry.Asset
            }
        }
        return $null
    }

    if (-not $cache) { $cache = @{} }
    $cache[$key] = [pscustomobject]@{
        Version  = $release.Version
        Url      = $release.Url
        Asset    = $release.Asset
        CachedAt = (Get-Date).ToString('o')
    }
    Set-VersionCache -Versions $cache

    return $release
}

# ---------- Helper functions ----------

function Normalize-Name {
    param([string]$Name)
    return ($Name -replace '[\s\-_]', '').ToLower()
}

function Test-PendingReboot {
    <# Informational only. A pending reboot can cause unrelated MSI
       installations to fail with 1603, so it is worth knowing about. #>
    $flagPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($p in $flagPaths) {
        if (Test-Path $p) { return $true }
    }
    try {
        $pfro = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
                                 -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        if ($pfro) { return $true }
    }
    catch { }
    return $false
}

function Get-GitHubRelease {
    param([string]$Owner, [string]$Repo)

    $headers = @{ 'User-Agent' = 'ArtCraft-Suite-Manager'; 'Accept' = 'application/vnd.github+json' }
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/releases/latest" `
                                     -Headers $headers -TimeoutSec 45 -ErrorAction Stop
    }
    catch {
        $statusCode = $null
        try {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
        }
        catch { }

        if ($statusCode -eq 403 -or $statusCode -eq 429) {
            Write-Host "  -> GitHub API rate limit reached (HTTP $statusCode)." -ForegroundColor DarkYellow
        }
        else {
            Write-Host "  -> GitHub API error: $($_.Exception.Message)" -ForegroundColor DarkYellow
        }
        return $null
    }

    $asset = $release.assets |
        Where-Object { $_.name -like '*.msi' } |
        Sort-Object @{ Expression = { if ($_.name -match 'x64|amd64') { 0 } else { 1 } } } |
        Select-Object -First 1

    if (-not $asset) {
        Write-Host "  -> No MSI asset found in release $($release.tag_name)." -ForegroundColor DarkYellow
        return $null
    }

    return [pscustomobject]@{
        Version = ($release.tag_name -replace '^v', '')
        Url     = $asset.browser_download_url
        Asset   = $asset.name
    }
}

function Test-NewerVersion {
    param([string]$Local, [string]$Remote)

    if ([string]::IsNullOrWhiteSpace($Local) -or [string]::IsNullOrWhiteSpace($Remote)) { return $false }
    try {
        $lv = [version](($Local  -replace '^v', '') -replace '[^0-9\.].*$', '')
        $rv = [version](($Remote -replace '^v', '') -replace '[^0-9\.].*$', '')
        return ($rv -gt $lv)
    }
    catch { return $false }
}

function Get-InstalledProductVersion {
    param([string]$DisplayName)

    $norm = Normalize-Name -Name $DisplayName

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
        } | Select-Object -First 1

    if ($entry) { return $entry.DisplayVersion }
    return $null
}

function Get-ProductCode {
    param([string]$AppName)

    $norm = Normalize-Name -Name $AppName
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
        } | Select-Object -First 1

    if ($entry) {
        return (Split-Path $entry.PsPath -Leaf)  # Returns the GUID
    }
    return $null
}

function Test-IsMsiFile {
    param([string]$Path)

    try {
        $fs  = [System.IO.File]::OpenRead($Path)
        $buf = New-Object byte[] 4
        $null = $fs.Read($buf, 0, 4)
        $fs.Close()
        return ($buf[0] -eq 0xD0 -and $buf[1] -eq 0xCF -and $buf[2] -eq 0x11 -and $buf[3] -eq 0xE0)
    }
    catch { return $false }
}

function Detect-ExistingScope {
    <# Returns the first uninstall entry matching the app name.
       HKLM roots are inspected first, so a machine-scoped entry wins
       when both a machine and a user entry exist. #>
    param([string]$AppName)

    $norm = Normalize-Name -Name $AppName
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($root in $roots) {
        $entries = Get-ItemProperty $root -ErrorAction SilentlyContinue |
            Where-Object {
                $_.DisplayName -and
                ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
            }

        foreach ($entry in $entries) {
            $isMachineScope = ($root -match 'HKLM')
            return [pscustomobject]@{
                ProductCode = (Split-Path $entry.PsPath -Leaf)
                Scope       = if ($isMachineScope) { 'machine' } else { 'user' }
                Path        = $entry.InstallLocation
            }
        }
    }
    return $null
}

function Remove-ExistingInstallation {
    param([string]$ProductName, [string]$ProductCode, [string]$TargetScope)

    if (-not $ProductCode) {
        Write-Host "  -> No product code found for removal, skipping cleanup." -ForegroundColor Gray
        return $true
    }

    Write-Host "  -> Removing existing $TargetScope installation before fresh install..." -ForegroundColor Yellow

    try {
        $proc = Start-Process msiexec.exe -ArgumentList "/x $ProductCode /qn /norestart" `
                                         -Wait -PassThru -ErrorAction Stop
        $exitCode = $proc.ExitCode

        if ($exitCode -eq 0 -or $exitCode -eq 3010 -or $exitCode -eq 1641) {
            Start-Sleep -Seconds 3
            Write-Host "  -> Previous installation removed successfully." -ForegroundColor Green
            return $true
        }

        Write-Host "  -> Warning: Could not remove previous installation (exit code: $exitCode)." -ForegroundColor DarkYellow
        return $false
    }
    catch {
        Write-Host "  -> Warning: Exception during removal: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
}

function Install-MsiFromUrl {
    param(
        [string]$Url,
        [string]$AppName,
        [string]$ProcessName,
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) { $ProcessName = $AppName }

    # Use versioned filename in download directory
    $versionClean = ($Version -replace '[^0-9\.]', '')
    $msiFileName = "$AppName-$versionClean.msi"
    $msiPath = Join-Path $downloadDir $msiFileName
    $partialPath = "$msiPath.part"
    $logFile = Join-Path $env:TEMP "$AppName-msi.log"

    # Check if we already have the correct MSI from a previous run
    if (Test-Path -LiteralPath $msiPath) {
        Write-Host "  -> Reusing cached MSI: $msiFileName" -ForegroundColor Gray
        $script:usedPackages += $msiFileName
    }
    else {
        Write-Host "  -> Download: $Url" -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $Url -OutFile $partialPath -UserAgent 'Mozilla/5.0' `
                              -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        }
        catch {
            Write-Host "  -> Download failed: $($_.Exception.Message)" -ForegroundColor Red
            Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        if (-not (Test-IsMsiFile -Path $partialPath)) {
            Write-Host "  -> The file is not a valid MSI (probably an HTML page). Deleting it." -ForegroundColor Red
            Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        # Rename from .part to final name only after validation passes
        try {
            Move-Item -LiteralPath $partialPath -Destination $msiPath -Force -ErrorAction Stop
            Write-Host "  -> MSI saved as: $msiFileName" -ForegroundColor Gray
        }
        catch {
            Write-Host "  -> Warning: Could not move MSI to final location: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
            return $false
        }

        $script:usedPackages += $msiFileName
    }

    # Match the exact process name supplied by the caller.
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "  -> Stopping process: $($_.ProcessName)" -ForegroundColor Gray
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    Start-Sleep -Seconds 2

    # Force ALLUSERS=1 to ensure per-machine installation
    $argList = "/i `"$msiPath`" ALLUSERS=1 /qn /norestart /L*v `"$logFile`""

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $proc = Start-Process msiexec.exe -ArgumentList $argList -Wait -PassThru -ErrorAction Continue
        $code = 1620
        if ($proc) { $code = $proc.ExitCode }

        if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) {
            if ($code -ne 0) { Write-Host "  -> Installed (exit $code - a reboot may be required)." -ForegroundColor Yellow }
            return $true
        }
        if ($code -eq 1618 -and $attempt -lt 2) {
            Write-Host "  -> Another installation is in progress (1618). Retrying in 15s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 15
            continue
        }

        Write-Host "  -> msiexec failed with exit code $code. Log: $logFile" -ForegroundColor Red
        Write-Host "  -> TIP: Check the log for scope mismatch or permission errors." -ForegroundColor DarkYellow
        return $false
    }
    return $false
}

function Invoke-WingetLogged {
    <#
        Runs a winget command, captures stdout+stderr into a single log file
        in $env:TEMP (same location as the MSI logs) and returns the exit code.

        Note: --verbose-logs additionally writes detailed diagnostics to
        %LOCALAPPDATA%\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\
        LocalState\DiagOutputDir
        which is where the per-package MSI logs referenced in the output live.
    #>
    param(
        [string[]]$Arguments,
        [string]$AppName,
        [string]$Operation
    )

    $logFile = Join-Path $env:TEMP "$AppName-winget.log"

    Add-Content -Path $logFile -Value "" -ErrorAction SilentlyContinue
    Add-Content -Path $logFile -Value "===== winget $Operation :: $AppName :: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" -ErrorAction SilentlyContinue
    Add-Content -Path $logFile -Value ("Command : winget " + ($Arguments -join ' ')) -ErrorAction SilentlyContinue

    Write-Host "  -> Running: winget $Operation (log: $logFile)" -ForegroundColor Gray

    try {
        $output   = & winget.exe @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output   = "winget invocation failed: $($_.Exception.Message)"
        $exitCode = -1
    }

    Add-Content -Path $logFile -Value $output -ErrorAction SilentlyContinue
    Add-Content -Path $logFile -Value ("ExitCode: {0} (0x{1:X8})" -f $exitCode, $exitCode) -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Success  = ($exitCode -eq 0)
        ExitCode = $exitCode
        LogFile  = $logFile
    }
}

function Try-WingetUpgrade {
    param([string]$WingetId, [string]$AppName)

    $baseArgs = @(
        'upgrade', '--id', $WingetId, '-e',
        '--silent', '--disable-interactivity', '--verbose-logs',
        '--accept-package-agreements', '--accept-source-agreements'
    )

    $result = Invoke-WingetLogged -Arguments $baseArgs -AppName $AppName -Operation 'upgrade'
    if ($result.Success) { return $result }

    Write-Host "  -> Retrying winget upgrade with --force..." -ForegroundColor DarkYellow
    $retry = Invoke-WingetLogged -Arguments ($baseArgs + '--force') -AppName $AppName -Operation 'upgrade --force'
    if ($retry.Success) { return $retry }

    return $result
}

function Try-WingetInstall {
    param([string]$WingetId, [string]$AppName)

    $args = @(
        'install', '--id', $WingetId, '-e',
        '--silent', '--disable-interactivity', '--verbose-logs',
        '--accept-package-agreements', '--accept-source-agreements'
    )

    return Invoke-WingetLogged -Arguments $args -AppName $AppName -Operation 'install'
}

# ---------- Parse and validate definitions ----------

$apps = @()
foreach ($def in $appDefs) {
    $parts = $def.Split('|')
    if ($parts.Count -ne 5 -or ($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) })) {
        Write-Warning "Skipping malformed entry: '$def'"
        continue
    }
    $apps += [pscustomobject]@{
        Name        = $parts[0]
        ID          = $parts[1]
        User        = $parts[2]
        Repo        = $parts[3]
        ExeName     = $parts[4]
        ProcessName = ($parts[4] -replace '\.exe$', '')
        NormName    = Normalize-Name -Name $parts[0]
    }
}

if ($apps.Count -eq 0) { throw "No valid applications found in the definition list." }

Write-Host "ArtCraft Suite Manager (Per-Machine Install v8 + Unified MSI/Cache Location)..." -ForegroundColor Cyan
Write-Host "Enforcing per-machine installation scope for all applications..." -ForegroundColor Gray
Write-Host "Winget usage: $(if ($wingetEnabled) { 'ENABLED' } else { 'DISABLED' })" -ForegroundColor Gray
Write-Host "Logs will be written to: $env:TEMP" -ForegroundColor Gray
Write-Host "MSI packages stored in: $downloadDir" -ForegroundColor Gray
Write-Host "Version cache: $cacheFile" -ForegroundColor Gray
Write-Host "  source: $cacheSource | TTL: ${cacheTTLHours}h" -ForegroundColor Gray

if (Test-PendingReboot) {
    Write-Host "NOTE: A system reboot is pending. Some MSI installations may fail with 1603." -ForegroundColor DarkYellow
    Write-Host "      Consider rebooting before running this script." -ForegroundColor DarkYellow
}

$wingetUpgradeRaw = ''
$installedAppsRaw = ''

if ($wingetEnabled) {
    $wingetUpgradeRaw = (winget upgrade --accept-source-agreements 2>&1 | Out-String)
    $installedAppsRaw = (winget list --accept-source-agreements 2>&1 | Out-String)
}
else {
    Write-Host "  -> Winget disabled: Skipping initial discovery phase." -ForegroundColor Gray
}

$totalApps    = $apps.Count
$currentIndex = 1
$successCount = 0
$failCount    = 0
$failedApps   = @()

foreach ($app in $apps) {
    Write-Host "`n[$currentIndex/$totalApps] Processing $($app.Name)..." -ForegroundColor Yellow

    # --- 1. Detect local installation (with normalized name matching) ---
    $possiblePaths = @(
        "$env:ProgramFiles\$($app.Name)\$($app.ExeName)",
        "${env:ProgramFiles(x86)}\$($app.Name)\$($app.ExeName)",
        "$env:LOCALAPPDATA\Programs\$($app.Name)\$($app.ExeName)"
    )
    $targetAppPath = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    $inWingetList = $false
    $wingetIdMatch = $installedAppsRaw -match [regex]::Escape($app.ID)
    $productCode = Get-ProductCode -AppName $app.Name
    $productCodeMatch = if ($productCode) { $installedAppsRaw -match [regex]::Escape($productCode) } else { $false }

    if ($wingetEnabled -and ($wingetIdMatch -or $productCodeMatch)) {
        $inWingetList = $true
    }

    $localVersion = $null
    if ($targetAppPath) {
        $localVersion = (Get-Item $targetAppPath).VersionInfo.ProductVersion
    }
    if (-not $localVersion) {
        $localVersion = Get-InstalledProductVersion -DisplayName $app.Name
    }

    $isInstalled = ($targetAppPath -or $inWingetList -or $localVersion)

    if ($isInstalled) {
        Write-Host "  -> State: Installed ($localVersion)" -ForegroundColor Green

        # Detect existing installation scope
        $existingInstall = Detect-ExistingScope -AppName $app.Name

        # Release info comes from the local cache when it is fresh; the GitHub
        # API is contacted only for missing or expired entries.
        $release = Get-GitHubRelease-Cached -Owner $app.User -Repo $app.Repo

        if (-not $release) {
            Write-Host "  -> Could not fetch GitHub release info. Assuming current version OK." -ForegroundColor DarkYellow
            $successCount++
            $currentIndex++
            continue
        }

        # Safety guard: don't reinstall the exact same version
        $sameVersion = ($localVersion -and
                        ($release.Version -eq ($localVersion -replace '^v', '')))

        if ($sameVersion) {
            Write-Host "  -> Already at latest version ($localVersion). Skipping!" -ForegroundColor Green
            $successCount++
            $currentIndex++
            continue
        }

        # Check for newer version
        if (Test-NewerVersion -Local $localVersion -Remote $release.Version) {
            Write-Host "  -> New release on GitHub: $($release.Version)" -ForegroundColor Magenta

            # If winget is disabled, skip all winget paths and go straight to MSI
            if (-not $wingetEnabled) {
                Write-Host "  -> Winget disabled: Using direct MSI install path." -ForegroundColor Gray
            }
            else {
                # A machine-scoped installation cannot be upgraded by winget:
                # winget invokes the MSI without ALLUSERS=1, the MSI falls back to
                # per-user (MSIINSTALLPERUSER=1) and its LaunchCondition aborts with
                # "This app is already installed for everyone" -> msiexec 1603 ->
                # winget 0x8A150049. Skip winget in that case and use the MSI path
                # below, which explicitly passes ALLUSERS=1.
                $isMachineScoped  = ($existingInstall -and $existingInstall.Scope -eq 'machine')
                $wingetHasUpgrade = $wingetUpgradeRaw -match [regex]::Escape($app.ID)

                $handledByWinget = $false

                if ($wingetHasUpgrade -and -not $isMachineScoped) {
                    Write-Host "  -> Winget reports an available upgrade for this package." -ForegroundColor Gray
                    Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue

                    $wingetResult = Try-WingetUpgrade -WingetId $app.ID -AppName $app.Name

                    if ($wingetResult.Success) {
                        Write-Host "  -> Upgrade completed successfully via Winget!" -ForegroundColor Green
                        $successCount++
                        $handledByWinget = $true
                    }
                    else {
                        Write-Host "  -> Winget upgrade failed (exit code: $($wingetResult.ExitCode)). See: $($wingetResult.LogFile)" -ForegroundColor Yellow
                        if ($wingetResult.ExitCode -eq $WINGET_ERROR_MSI_INSTALL_FAILED) {
                            Write-Host "  -> 0x8A150049 = MSI install failed. If the MSI log reports" -ForegroundColor DarkYellow
                            Write-Host "     'already installed for everyone', the existing install is machine-scoped" -ForegroundColor DarkYellow
                            Write-Host "     and winget cannot pass ALLUSERS=1. Falling back to the MSI path." -ForegroundColor DarkYellow
                        }
                    }
                }
                elseif ($wingetHasUpgrade -and $isMachineScoped) {
                    Write-Host "  -> Existing installation is machine-scoped (per-machine)." -ForegroundColor Gray
                    Write-Host "  -> Skipping winget: it cannot pass ALLUSERS=1, so the MSI would reject it." -ForegroundColor Gray
                }
                else {
                    Write-Host "  -> Winget does not have an upgrade available for this package." -ForegroundColor Gray
                }

                if (-not $handledByWinget) {
                    Write-Host "  -> Trying GitHub MSI with forced per-machine scope..." -ForegroundColor Yellow

                    Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue

                    # Reverse-direction cleanup: a per-user copy is what blocks a
                    # per-machine install, so only user-scoped entries are removed.
                    if ($existingInstall -and $existingInstall.Scope -eq 'user') {
                        Write-Host "  -> Detected per-user installation, removing before per-machine install..." -ForegroundColor Yellow
                        Remove-ExistingInstallation -ProductName $app.Name -ProductCode $existingInstall.ProductCode -TargetScope 'machine'
                    }

                    if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                        Write-Host "  -> Upgrade completed successfully via MSI!" -ForegroundColor Green
                        $successCount++
                    }
                    else {
                        Write-Host "  -> Upgrade failed for $($app.Name)." -ForegroundColor Red
                        $failCount++
                        $failedApps += $app.Name
                    }
                }
            }

            if (-not $wingetEnabled -and -not $inWingetList) {
                Write-Host "  -> Trying GitHub MSI with forced per-machine scope..." -ForegroundColor Yellow

                Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue

                # Reverse-direction cleanup: a per-user copy is what blocks a
                # per-machine install, so only user-scoped entries are removed.
                if ($existingInstall -and $existingInstall.Scope -eq 'user') {
                    Write-Host "  -> Detected per-user installation, removing before per-machine install..." -ForegroundColor Yellow
                    Remove-ExistingInstallation -ProductName $app.Name -ProductCode $existingInstall.ProductCode -TargetScope 'machine'
                }

                if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                    Write-Host "  -> Upgrade completed successfully via MSI!" -ForegroundColor Green
                    $successCount++
                }
                else {
                    Write-Host "  -> Upgrade failed for $($app.Name)." -ForegroundColor Red
                    $failCount++
                    $failedApps += $app.Name
                }
            }
        }
        else {
            Write-Host "  -> Already up to date. Skipping!" -ForegroundColor Green
            $successCount++
        }
    }
    else {
        Write-Host "  -> State: Missing. Starting installation..." -ForegroundColor Blue

        # Release info comes from the local cache when it is fresh; the GitHub
        # API is contacted only for missing or expired entries.
        $release = Get-GitHubRelease-Cached -Owner $app.User -Repo $app.Repo

        if (-not $release) {
            Write-Host "  -> Could not determine latest version. Cannot proceed with installation." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
            $currentIndex++
            continue
        }

        Write-Host "  -> Latest version: $($release.Version)" -ForegroundColor Gray

        if ($wingetEnabled) {
            # Fresh install: no existing scope conflict, so winget is safe to try.
            Write-Host "  -> Attempting installation via Winget..." -ForegroundColor Gray
            $wingetResult = Try-WingetInstall -WingetId $app.ID -AppName $app.Name

            if ($wingetResult.Success) {
                Write-Host "  -> Clean installation completed successfully via Winget!" -ForegroundColor Green
                $successCount++
                $currentIndex++
                continue
            }

            Write-Host "  -> Winget installation failed (exit code: $($wingetResult.ExitCode)). See: $($wingetResult.LogFile)" -ForegroundColor Yellow

            # Check whether winget knows about this package at all
            $check = (winget list --id $app.ID -e --accept-source-agreements 2>&1 | Out-String)
            $wingetHasPackage = ($check -match [regex]::Escape($app.ID))

            if (-not $wingetHasPackage) {
                Write-Host "  -> Package not found in winget. Falling back to GitHub Releases..." -ForegroundColor DarkYellow
            }
            else {
                Write-Host "  -> Winget has the package but installation failed. Falling back to GitHub Releases..." -ForegroundColor DarkYellow
            }

            # Force per-machine installation for new installs too
            if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                Write-Host "  -> Installation completed successfully via MSI ($($release.Asset))." -ForegroundColor Green
                $successCount++
            }
            else {
                Write-Host "  -> Installation failed for $($app.Name)." -ForegroundColor Red
                $failCount++
                $failedApps += $app.Name
            }
        }
        else {
            # Winget disabled: go straight to MSI
            Write-Host "  -> Winget disabled: Installing directly via MSI from GitHub." -ForegroundColor Gray
            if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                Write-Host "  -> Installation completed successfully via MSI ($($release.Asset))." -ForegroundColor Green
                $successCount++
            }
            else {
                Write-Host "  -> Installation failed for $($app.Name)." -ForegroundColor Red
                $failCount++
                $failedApps += $app.Name
            }
        }
    }

    $currentIndex++
}

# ---------- Summary ----------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Summary:" -ForegroundColor Cyan
Write-Host "  Successful: $successCount / $totalApps" -ForegroundColor $(if ($successCount -eq $totalApps) { 'Green' } else { 'Yellow' })
Write-Host "  Failed:     $failCount / $totalApps" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })
if ($failedApps.Count -gt 0) {
    Write-Host "  Failed apps: $($failedApps -join ', ')" -ForegroundColor Red
}

Write-Host "`nCache Statistics:" -ForegroundColor Cyan
Write-Host "  GitHub API calls this run:  $script:apiCallCount" -ForegroundColor $(if ($script:apiCallCount -eq 0) { 'Green' } else { 'Gray' })
Write-Host "  Cache hits this run:        $script:cacheHitCount" -ForegroundColor $(if ($script:cacheHitCount -gt 0) { 'Green' } else { 'Gray' })

if ($script:usedPackages.Count -gt 0) {
    Write-Host "`nMSI Packages Used/Stored:" -ForegroundColor Cyan
    $script:usedPackages | ForEach-Object { Write-Host "  $($_)" -ForegroundColor Gray }
}

# List generated winget logs
$wingetLogs = Get-ChildItem -Path $env:TEMP -Filter "*-winget.log" -ErrorAction SilentlyContinue
if ($wingetLogs) {
    Write-Host "`nWinget log files created:" -ForegroundColor Cyan
    $wingetLogs | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Gray }
}

Write-Host "`nArchitecture sync complete." -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
}
exit 0
