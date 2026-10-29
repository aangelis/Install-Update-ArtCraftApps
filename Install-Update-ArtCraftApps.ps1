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
#>

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$gitHubUser = "storytold"

# Winget error code emitted when the underlying MSI fails.
$WINGET_ERROR_MSI_INSTALL_FAILED = -1978335159   # 0x8A150049

# Format: Name|WingetId|GitHubRepo|ExeName
$appDefs = @(
    "ArtCraftLauncher|ArtCraft.ArtCraftLauncher|craft-launcher|ArtCraftLauncher.exe",
    "PhotoCraft|ArtCraft.PhotoCraft|photocraft|PhotoCraft.exe",
    "VectorCraft|ArtCraft.VectorCraft|vectorcraft|VectorCraft.exe",
    "PdfCraft|ArtCraft.PdfCraft|pdfcraft|PdfCraft.exe",
    "WordCraft|ArtCraft.WordCraft|wordcraft|WordCraft.exe",
    "GridCraft|ArtCraft.GridCraft|gridcraft|GridCraft.exe",
    "LightCraft|ArtCraft.LightCraft|lightcraft|LightCraft.exe",
    "FilmCraft|ArtCraft.FilmCraft|filmcraft|FilmCraft.exe",
    "DesignCraft|ArtCraft.DesignCraft|designcraft|DesignCraft.exe",
    "EffectCraft|ArtCraft.EffectCraft|effectcraft|EffectCraft.exe",
    "DeckCraft|ArtCraft.DeckCraft|deckcraft|DeckCraft.exe",
    "CADCraft|ArtCraft.CadCraft|cadcraft|CADCraft.exe",
    "SoundCraft|ArtCraft.SoundCraft|soundcraft|SoundCraft.exe",
    "FigCraft|ArtCraft.FigCraft|figcraft|FigCraft.exe"
)

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
        Write-Host "  -> GitHub API error: $($_.Exception.Message)" -ForegroundColor DarkYellow
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
        [string]$ProcessName
    )

    if ([string]::IsNullOrWhiteSpace($ProcessName)) { $ProcessName = $AppName }

    $msiPath = Join-Path $env:TEMP "$AppName-bootstrap.msi"
    $logFile = Join-Path $env:TEMP "$AppName-msi.log"

    Write-Host "  -> Download: $Url" -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri $Url -OutFile $msiPath -UserAgent 'Mozilla/5.0' `
                          -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
    }
    catch {
        Write-Host "  -> Download failed: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    if (-not (Test-IsMsiFile -Path $msiPath)) {
        Write-Host "  -> The file is not a valid MSI (probably an HTML page). Deleting it." -ForegroundColor Red
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        return $false
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
            Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            return $true
        }
        if ($code -eq 1618 -and $attempt -lt 2) {
            Write-Host "  -> Another installation is in progress (1618). Retrying in 15s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds 15
            continue
        }

        Write-Host "  -> msiexec failed with exit code $code. Log: $logFile" -ForegroundColor Red
        Write-Host "  -> TIP: Check the log for scope mismatch or permission errors." -ForegroundColor DarkYellow
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
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
    if ($parts.Count -ne 4 -or ($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) })) {
        Write-Warning "Skipping malformed entry: '$def'"
        continue
    }
    $apps += [pscustomobject]@{
        Name        = $parts[0]
        ID          = $parts[1]
        Repo        = $parts[2]
        ExeName     = $parts[3]
        ProcessName = ($parts[3] -replace '\.exe$', '')
        NormName    = Normalize-Name -Name $parts[0]
    }
}

if ($apps.Count -eq 0) { throw "No valid applications found in the definition list." }

Write-Host "ArtCraft Suite Manager (Per-Machine Install v5)..." -ForegroundColor Cyan
Write-Host "Enforcing per-machine installation scope for all applications..." -ForegroundColor Gray
Write-Host "Logs will be written to: $env:TEMP" -ForegroundColor Gray

if (Test-PendingReboot) {
    Write-Host "NOTE: A system reboot is pending. Some MSI installations may fail with 1603." -ForegroundColor DarkYellow
    Write-Host "      Consider rebooting before running this script." -ForegroundColor DarkYellow
}

$wingetUpgradeRaw = (winget upgrade --accept-source-agreements 2>&1 | Out-String)
$installedAppsRaw = (winget list --accept-source-agreements 2>&1 | Out-String)

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

    if ($wingetIdMatch -or $productCodeMatch) {
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

        # Check latest GitHub version FIRST
        $release = Get-GitHubRelease -Owner $gitHubUser -Repo $app.Repo
        if (-not $release) {
            Write-Host "  -> Could not fetch GitHub release info. Assuming current version OK." -ForegroundColor Gray
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

                if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName) {
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

        # Check latest GitHub version FIRST before attempting install
        $release = Get-GitHubRelease -Owner $gitHubUser -Repo $app.Repo
        if (-not $release) {
            Write-Host "  -> Could not determine latest version. Cannot proceed with installation." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
            $currentIndex++
            continue
        }

        Write-Host "  -> Latest version: $($release.Version)" -ForegroundColor Gray

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
        if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name -ProcessName $app.ProcessName) {
            Write-Host "  -> Installation completed successfully via MSI ($($release.Asset))." -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "  -> Installation failed for $($app.Name)." -ForegroundColor Red
            $failCount++
            $failedApps += $app.Name
        }

        $currentIndex++
        continue
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

# List generated winget logs
$wingetLogs = Get-ChildItem -Path $env:TEMP -Filter "*-winget.log" -ErrorAction SilentlyContinue
if ($wingetLogs) {
    Write-Host "`nWinget log files created:" -ForegroundColor Cyan
    $wingetLogs | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Gray }
}

Write-Host "Architecture sync complete." -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
}
exit 0
