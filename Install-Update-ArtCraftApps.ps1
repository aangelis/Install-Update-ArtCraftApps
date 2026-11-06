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

    New in v10:
    - New apps added (MaterialCraft, TextureCraft and Craft Anything).

    New in v11:
    - Launcher-specific handling: installs the ArtCraft Launcher as per-user
      (no ALLUSERS=1) so it lands in %LOCALAPPDATA%\Programs\ArtCraft\Launcher
      and is runnable by the current user.
    - Detects and removes a previous Launcher installed under another user's
      profile (e.g. C:\Users\Admin\AppData\Local\ArtCraft Launcher).
    - All other applications keep the forced per-machine (ALLUSERS=1) path.

    New in v12:
    - Requires Administrator privileges; aborts with a clear message and the
      exact re-run command if elevation is missing.

#>

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ======================= LOCAL CONFIGURATION =======================
$UseWinget = $false
$VersionCachePathOverride = ''
$VersionCacheTTLHours = 24
# ===================================================================

$defaultCacheFileName = 'artcraft-version-cache.json'

# ---------- Locate the folder this script lives in ----------
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

# ---------- Require administrator privileges ----------
function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = Join-Path $scriptDir 'Install-Update-ArtCraftApps.ps1'
    }

    Write-Host ""
    Write-Host "ERROR: This script must be run with Administrator privileges." -ForegroundColor Red
    Write-Host ""
    Write-Host "Reason: it installs MSI packages per-machine (ALLUSERS=1) and modifies" -ForegroundColor Yellow
    Write-Host "        HKLM uninstall keys, which requires elevation." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Re-run it from an elevated PowerShell window with:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    powershell.exe -ExecutionPolicy Bypass -File `"$scriptPath`"" -ForegroundColor White
    Write-Host ""
    Write-Host "To open an elevated PowerShell quickly, right-click PowerShell and choose" -ForegroundColor Gray
    Write-Host "'Run as administrator', or run:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy Bypass -File `"$scriptPath`"'" -ForegroundColor White
    Write-Host ""
    exit 1
}

Write-Host "Running with Administrator privileges." -ForegroundColor Green

# ---------- Resolve the winget switch ----------
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

$script:apiCallCount  = 0
$script:cacheHitCount = 0
$script:usedPackages  = @()

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
    "SolidCraft|ArtCraft.SolidCraft|tangency-labs|solidcraft|SolidCraft.exe",
    "MaterialCraft|ArtCraft.MaterialCraft|storytold|materialcraft|MaterialCraft.exe",
    "TextureCraft|ArtCraft.TextureCraft|storytold|texturecraft|TextureCraft.exe",
    "CraftAnything|ArtCraft.Craft-Anything|storytold|craft-anything|Craft-Anything.exe"
)

# ---------- Version cache ----------
function Get-VersionCache {
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
    try { return (Get-Item -LiteralPath $cacheFile -ErrorAction Stop).LastWriteTime }
    catch { return $null }
}

function Test-CacheEntryFresh {
    param($Entry, $FallbackTimestamp)
    if (-not $Entry) { return $false }
    $timestamp = $FallbackTimestamp
    if ($Entry.CachedAt) {
        try { $timestamp = [datetime]::Parse($Entry.CachedAt, [Globalization.CultureInfo]::InvariantCulture) }
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
        $tempFile = "$cacheFile.tmp"
        Set-Content -LiteralPath $tempFile -Value $cacheJson -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tempFile -Destination $cacheFile -Force -ErrorAction Stop
    }
    catch {
        Write-Host "  -> Warning: Could not save version cache: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Get-GitHubRelease-Cached {
    param([string]$Owner, [string]$Repo)
    $key = "$Owner/$Repo"
    $cache         = Get-VersionCache
    $fileTimestamp = Get-CacheFileTimestamp

    $entry = $null
    if ($cache -and $cache.ContainsKey($key)) { $entry = $cache[$key] }

    if (Test-CacheEntryFresh -Entry $entry -FallbackTimestamp $fileTimestamp) {
        $script:cacheHitCount++
        Write-Host "  -> Cache HIT for $Repo (version $($entry.Version))" -ForegroundColor Gray
        return [pscustomobject]@{ Version = $entry.Version; Url = $entry.Url; Asset = $entry.Asset }
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
            return [pscustomobject]@{ Version = $entry.Version; Url = $entry.Url; Asset = $entry.Asset }
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
            $_.DisplayName -and ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
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
            $_.DisplayName -and ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
        } | Select-Object -First 1
    if ($entry) { return (Split-Path $entry.PsPath -Leaf) }
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
                $_.DisplayName -and ((Normalize-Name -Name $_.DisplayName) -like "*$norm*")
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

# ---------- Generic per-machine MSI install (all apps except Launcher) ----------
function Install-MsiFromUrl {
    param(
        [string]$Url,
        [string]$AppName,
        [string]$ProcessName,
        [string]$Version
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) { $ProcessName = $AppName }

    $versionClean = ($Version -replace '[^0-9\.]', '')
    $msiFileName = "$AppName-$versionClean.msi"
    $msiPath = Join-Path $downloadDir $msiFileName
    $partialPath = "$msiPath.part"
    $logFile = Join-Path $env:TEMP "$AppName-msi.log"

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

    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "  -> Stopping process: $($_.ProcessName)" -ForegroundColor Gray
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Seconds 2

    # Forced per-machine for all non-Launcher apps.
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
        return $false
    }
    return $false
}

# ---------- Launcher-specific helpers ----------
function Get-LauncherAdminInstallPath {
    $candidates = @()
    $usersRoot = 'C:\Users'
    if (Test-Path -LiteralPath $usersRoot) {
        $candidates = Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\ArtCraft Launcher' }
    }
    $candidates += Join-Path $env:LOCALAPPDATA 'ArtCraft Launcher'

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            $exe = Join-Path $path 'artcraft-launcher.exe'
            if (Test-Path -LiteralPath $exe) { return $path }
        }
    }
    return $null
}

function Get-LauncherCorrectInstallPath {
    return (Join-Path $env:LOCALAPPDATA 'Programs\ArtCraft\Launcher')
}

function Test-LauncherPresent {
    $correct = Join-Path (Get-LauncherCorrectInstallPath) 'artcraft-launcher.exe'
    if (Test-Path -LiteralPath $correct) { return $correct }

    $roots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            ((Normalize-Name -Name $_.DisplayName) -like '*artcraftlauncher*')
        } | Select-Object -First 1
    if ($entry -and $entry.InstallLocation) {
        $exe = Join-Path $entry.InstallLocation 'artcraft-launcher.exe'
        if (Test-Path -LiteralPath $exe) { return $exe }
    }
    return $null
}

function Install-LauncherPerUser {
    param([string]$Url, [string]$Version)

    $appName = 'ArtCraftLauncher'
    $versionClean = ($Version -replace '[^0-9\.]', '')
    $msiFileName = "$appName-$versionClean.msi"
    $msiPath = Join-Path $downloadDir $msiFileName
    $partialPath = "$msiPath.part"
    $logFile = Join-Path $env:TEMP "$appName-msi.log"

    if (Test-Path -LiteralPath $msiPath) {
        Write-Host "  -> Reusing cached Launcher MSI: $msiFileName" -ForegroundColor Gray
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
            Write-Host "  -> The file is not a valid MSI. Deleting it." -ForegroundColor Red
            Remove-Item $partialPath -Force -ErrorAction SilentlyContinue
            return $false
        }

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

    Get-Process -Name 'artcraft-launcher' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "  -> Stopping process: $($_.ProcessName)" -ForegroundColor Gray
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Seconds 2

    # *** No ALLUSERS=1 here. Per-user install is intentional. ***
    $argList = "/i `"$msiPath`" /qn /norestart /L*v `"$logFile`""

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $proc = Start-Process msiexec.exe -ArgumentList $argList -Wait -PassThru -ErrorAction Continue
        $code = 1620
        if ($proc) { $code = $proc.ExitCode }

        if ($code -eq 0 -or $code -eq 3010 -or $code -eq 1641) {
            if ($code -ne 0) { Write-Host "  -> Launcher installed (exit $code - reboot may be required)." -ForegroundColor Yellow }
            else { Write-Host "  -> Launcher installed successfully (per-user)." -ForegroundColor Green }
            return $true
        }
        if ($code -eq 1618 -and $attempt -lt 2) {
            Write-Host "  -> Another installation is in progress (1618). Retrying in 15s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 15
            continue
        }
        Write-Host "  -> Launcher msiexec failed with exit code $code. Log: $logFile" -ForegroundColor Red
        return $false
    }
    return $false
}

# ---------- Winget wrappers ----------
function Invoke-WingetLogged {
    param([string[]]$Arguments, [string]$AppName, [string]$Operation)
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
    return [pscustomobject]@{ Success = ($exitCode -eq 0); ExitCode = $exitCode; LogFile = $logFile }
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

# ---------- HEADER ----------
Write-Host "ArtCraft Suite Manager (Per-Machine Apps + Per-User Launcher v12)..." -ForegroundColor Cyan
Write-Host "Other apps: forced per-machine (ALLUSERS=1). Launcher: per-user." -ForegroundColor Gray
Write-Host "Winget usage: $(if ($wingetEnabled) { 'ENABLED' } else { 'DISABLED' })" -ForegroundColor Gray
Write-Host "Logs will be written to: $env:TEMP" -ForegroundColor Gray
Write-Host "MSI packages stored in: $downloadDir" -ForegroundColor Gray
Write-Host "Version cache: $cacheFile" -ForegroundColor Gray
Write-Host "  source: $cacheSource | TTL: ${cacheTTLHours}h" -ForegroundColor Gray

if (Test-PendingReboot) {
    Write-Host "NOTE: A system reboot is pending. Some MSI installations may fail with 1603." -ForegroundColor DarkYellow
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

# ---------- Pre-flight: clean any Launcher installed under a different user ----------
Write-Host "`n[Pre-flight] Checking for ArtCraft Launcher in wrong locations..." -ForegroundColor Cyan
$wrongLauncherPath = Get-LauncherAdminInstallPath
if ($wrongLauncherPath) {
    Write-Host "  -> Found Launcher under another user profile: $wrongLauncherPath" -ForegroundColor Yellow
    Write-Host "  -> Removing it because it is not runnable by the current user..." -ForegroundColor Yellow

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $launcherEntry = Get-ItemProperty $roots -ErrorAction SilentlyContinue |
        Where-Object {
            $_.DisplayName -and
            ((Normalize-Name -Name $_.DisplayName) -like '*artcraftlauncher*') -and
            $_.InstallLocation -and
            ($_.InstallLocation -like "*$wrongLauncherPath*")
        } | Select-Object -First 1

    if ($launcherEntry) {
        $wrongProductCode = Split-Path $launcherEntry.PsPath -Leaf
        $removed = Remove-ExistingInstallation -ProductName 'ArtCraft Launcher' `
                                               -ProductCode $wrongProductCode `
                                               -TargetScope 'wrong-user'
        if (-not $removed) {
            Write-Host "  -> Warning: Could not remove the wrong Launcher instance. Continuing anyway." -ForegroundColor DarkYellow
        }
    }
    else {
        Write-Host "  -> No uninstall entry found; removing folder directly." -ForegroundColor DarkYellow
        Remove-Item -LiteralPath $wrongLauncherPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "  -> No misplaced Launcher found." -ForegroundColor Green
}

# ---------- Main loop ----------
foreach ($app in $apps) {
    Write-Host "`n[$currentIndex/$totalApps] Processing $($app.Name)..." -ForegroundColor Yellow

    # ============================================================
    # SPECIAL CASE: ArtCraft Launcher (per-user install)
    # ============================================================
    if ($app.Name -eq 'ArtCraftLauncher') {
        $launcherExe = Test-LauncherPresent
        $release = Get-GitHubRelease-Cached -Owner $app.User -Repo $app.Repo

        if (-not $release) {
            Write-Host "  -> Could not fetch Launcher release info." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
            $currentIndex++
            continue
        }

        $localVersion = $null
        if ($launcherExe) {
            try { $localVersion = (Get-Item $launcherExe).VersionInfo.ProductVersion } catch {}
        }
        if (-not $localVersion) {
            $localVersion = Get-InstalledProductVersion -DisplayName $app.Name
        }

        if ($localVersion) {
            Write-Host "  -> State: Installed ($localVersion)" -ForegroundColor Green
            if ($release.Version -eq ($localVersion -replace '^v', '')) {
                Write-Host "  -> Launcher already at latest version ($localVersion). Skipping." -ForegroundColor Green
                $successCount++
                $currentIndex++
                continue
            }
            if (-not (Test-NewerVersion -Local $localVersion -Remote $release.Version)) {
                Write-Host "  -> Launcher is up to date. Skipping." -ForegroundColor Green
                $successCount++
                $currentIndex++
                continue
            }
            Write-Host "  -> New Launcher release: $($release.Version)" -ForegroundColor Magenta
        }
        else {
            Write-Host "  -> State: Missing. Installing Launcher (per-user)..." -ForegroundColor Blue
        }

        if (Install-LauncherPerUser -Url $release.Url -Version $release.Version) {
            $verifyExe = Test-LauncherPresent
            if ($verifyExe) {
                Write-Host "  -> Launcher verified at: $verifyExe" -ForegroundColor Green
                $successCount++
            }
            else {
                Write-Host "  -> Warning: Launcher install reported success but executable not found." -ForegroundColor DarkYellow
                Write-Host "     Expected: $(Join-Path (Get-LauncherCorrectInstallPath) 'artcraft-launcher.exe')" -ForegroundColor DarkYellow
                $successCount++
            }
        }
        else {
            Write-Host "  -> Launcher installation failed." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
        }

        $currentIndex++
        continue
    }

    # ============================================================
    # ALL OTHER APPS (forced per-machine)
    # ============================================================
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

    if ($wingetEnabled -and ($wingetIdMatch -or $productCodeMatch)) { $inWingetList = $true }

    $localVersion = $null
    if ($targetAppPath) { $localVersion = (Get-Item $targetAppPath).VersionInfo.ProductVersion }
    if (-not $localVersion) { $localVersion = Get-InstalledProductVersion -DisplayName $app.Name }

    $isInstalled = ($targetAppPath -or $inWingetList -or $localVersion)

    if ($isInstalled) {
        Write-Host "  -> State: Installed ($localVersion)" -ForegroundColor Green
        $existingInstall = Detect-ExistingScope -AppName $app.Name
        $release = Get-GitHubRelease-Cached -Owner $app.User -Repo $app.Repo

        if (-not $release) {
            Write-Host "  -> Could not fetch GitHub release info. Assuming current version OK." -ForegroundColor DarkYellow
            $successCount++
            $currentIndex++
            continue
        }

        $sameVersion = ($localVersion -and ($release.Version -eq ($localVersion -replace '^v', '')))
        if ($sameVersion) {
            Write-Host "  -> Already at latest version ($localVersion). Skipping!" -ForegroundColor Green
            $successCount++
            $currentIndex++
            continue
        }

        if (Test-NewerVersion -Local $localVersion -Remote $release.Version) {
            Write-Host "  -> New release on GitHub: $($release.Version)" -ForegroundColor Magenta

            if (-not $wingetEnabled) {
                Write-Host "  -> Winget disabled: Using direct MSI install path." -ForegroundColor Gray
            }
            else {
                $isMachineScoped  = ($existingInstall -and $existingInstall.Scope -eq 'machine')
                $wingetHasUpgrade = $wingetUpgradeRaw -match [regex]::Escape($app.ID)
                $handledByWinget = $false

                if ($wingetHasUpgrade -and -not $isMachineScoped) {
                    Write-Host "  -> Winget reports an available upgrade." -ForegroundColor Gray
                    Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue
                    $wingetResult = Try-WingetUpgrade -WingetId $app.ID -AppName $app.Name
                    if ($wingetResult.Success) {
                        Write-Host "  -> Upgrade completed via Winget!" -ForegroundColor Green
                        $successCount++
                        $handledByWinget = $true
                    }
                    else {
                        Write-Host "  -> Winget upgrade failed ($($wingetResult.ExitCode))." -ForegroundColor Yellow
                    }
                }
                elseif ($wingetHasUpgrade -and $isMachineScoped) {
                    Write-Host "  -> Machine-scoped install; skipping winget (cannot pass ALLUSERS=1)." -ForegroundColor Gray
                }
                else {
                    Write-Host "  -> Winget has no upgrade available." -ForegroundColor Gray
                }

                if (-not $handledByWinget) {
                    Write-Host "  -> Trying GitHub MSI with forced per-machine scope..." -ForegroundColor Yellow
                    Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue
                    if ($existingInstall -and $existingInstall.Scope -eq 'user') {
                        Write-Host "  -> Removing per-user install before per-machine install..." -ForegroundColor Yellow
                        Remove-ExistingInstallation -ProductName $app.Name -ProductCode $existingInstall.ProductCode -TargetScope 'machine'
                    }
                    if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                        Write-Host "  -> Upgrade completed via MSI!" -ForegroundColor Green
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
                if ($existingInstall -and $existingInstall.Scope -eq 'user') {
                    Write-Host "  -> Removing per-user install before per-machine install..." -ForegroundColor Yellow
                    Remove-ExistingInstallation -ProductName $app.Name -ProductCode $existingInstall.ProductCode -TargetScope 'machine'
                }
                if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
                    Write-Host "  -> Upgrade completed via MSI!" -ForegroundColor Green
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
        $release = Get-GitHubRelease-Cached -Owner $app.User -Repo $app.Repo

        if (-not $release) {
            Write-Host "  -> Could not determine latest version." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
            $currentIndex++
            continue
        }

        Write-Host "  -> Latest version: $($release.Version)" -ForegroundColor Gray

        if ($wingetEnabled) {
            Write-Host "  -> Attempting installation via Winget..." -ForegroundColor Gray
            $wingetResult = Try-WingetInstall -WingetId $app.ID -AppName $app.Name
            if ($wingetResult.Success) {
                Write-Host "  -> Clean installation completed via Winget!" -ForegroundColor Green
                $successCount++
                $currentIndex++
                continue
            }
            Write-Host "  -> Winget installation failed ($($wingetResult.ExitCode)). Falling back to MSI..." -ForegroundColor Yellow
        }

        if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName -Version $release.Version) {
            Write-Host "  -> Installation completed via MSI." -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "  -> Installation failed for $($app.Name)." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
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

$wingetLogs = Get-ChildItem -Path $env:TEMP -Filter "*-winget.log" -ErrorAction SilentlyContinue
if ($wingetLogs) {
    Write-Host "`nWinget log files created:" -ForegroundColor Cyan
    $wingetLogs | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Gray }
}

Write-Host "`nArchitecture sync complete." -ForegroundColor Cyan

if ($failCount -gt 0) { exit 1 }
exit 0
