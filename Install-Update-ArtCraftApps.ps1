<#
    ArtCraft Suite Manager - Update or Install (Fixed Version v2)
    - Normalized name matching (handles spaces, hyphens, underscores)
    - ProductCode detection fallback for mixed registry scenarios
    - Dynamic latest version retrieval from GitHub API
    - Verifies downloaded file is a valid MSI
    - Correct exit code handling: 0, 3010, 1641, 1618 (retry)
    - Pre-install process termination to avoid file locks
    - Safe version guard (skip if same version detected)
#>

$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$gitHubUser = "storytold"

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

function Install-MsiFromUrl {
    param([string]$Url, [string]$AppName)

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

    # Detect and kill any running processes
    $processName = (($AppName -replace 'Craft', '') -replace 'Launcher', '').ToLower()
    Get-Process | Where-Object { $_.ProcessName.ToLower().Contains($processName) } |
        ForEach-Object { 
            Write-Host "  -> Stopping process: $($_.ProcessName)" -ForegroundColor Gray
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }

    Start-Sleep -Seconds 2

    $argList = "/i `"$msiPath`" /qn /norestart /L*v `"$logFile`""
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $proc = Start-Process msiexec.exe -ArgumentList $argList -Wait -PassThru
        $code = $proc.ExitCode

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
        Write-Host "  -> TIP: Try running the script as Administrator, or run manually:" -ForegroundColor DarkYellow
        Write-Host "     msiexec /i `"$msiPath`" /qn /norestart" -ForegroundColor DarkYellow
        Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $false
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

Write-Host "ArtCraft Suite Manager (Enhanced Detection Mode v2)..." -ForegroundColor Cyan
Write-Host "Analyzing suite infrastructure and package states..." -ForegroundColor Gray

# DON'T delete Craft MSI files here anymore - they may be needed for repairs

$wingetUpgradeRaw   = (winget upgrade --accept-source-agreements 2>&1 | Out-String)
$installedAppsRaw   = (winget list --accept-source-agreements 2>&1 | Out-String)

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
        "$env:LOCALAPPDATA\Programs\$($app.Name)\$($app.ExeName)",
        # Add variations with spaces/hyphens
        "$env:LOCALAPPDATA\Programs\ArtCraft Launcher\ArtCraftLauncher.exe",
        "$env:LOCALAPPDATA\Programs\artcraft-launcher\ArtCraftLauncher.exe",
        "$env:LOCALAPPDATA\Programs\PhotoCraft\PhotoCraft.exe",
        "$env:LOCALAPPDATA\Programs\VectorCraft\VectorCraft.exe"
    )
    $targetAppPath = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    $inWingetList = $false
    # Check both Winget ID AND ProductCode
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
            
            # Try Winget upgrade first
            $wingetHasUpgrade = $wingetUpgradeRaw -match [regex]::Escape($app.ID)
            if ($wingetHasUpgrade) {
                Write-Host "  -> Upgrading via Winget..." -ForegroundColor Gray
                Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue

                winget upgrade --id $app.ID -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    winget upgrade --id $app.ID -e --silent --force --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
                }

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  -> Upgrade completed successfully via Winget!" -ForegroundColor Green
                    $successCount++
                }
                else {
                    Write-Host "  -> Winget upgrade failed. Trying GitHub MSI..." -ForegroundColor Yellow
                    
                    Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue
                    if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name) {
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
                # No Winget upgrade, go straight to GitHub
                Stop-Process -Name $app.ProcessName -Force -ErrorAction SilentlyContinue
                if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name) {
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
        
        # Attempt installation
        Write-Host "  -> Attempting installation via Winget..." -ForegroundColor Gray
        winget install --id $app.ID -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
        $wingetOk = ($LASTEXITCODE -eq 0)

        if (-not $wingetOk) {
            $check = (winget list --id $app.ID -e --accept-source-agreements 2>&1 | Out-String)
            $wingetOk = ($check -match [regex]::Escape($app.ID))
        }

        if ($wingetOk) {
            Write-Host "  -> Clean installation completed successfully via Winget!" -ForegroundColor Green
            $successCount++
            $currentIndex++
            continue
        }

        Write-Host "  -> Winget does not have this package. Falling back to GitHub Releases..." -ForegroundColor DarkYellow

        if (Install-MsiFromUrl -Url $release.Url -AppName $app.Name) {
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
Write-Host "Architecture sync complete." -ForegroundColor Cyan

if ($failCount -gt 0) {
    exit 1
}
exit 0