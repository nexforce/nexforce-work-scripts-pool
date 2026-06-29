<#
.SYNOPSIS
  Nexforce Work — Windows desktop installer bootstrap.
.DESCRIPTION
  Downloads the latest OpenWork Desktop installer for Windows from the
  upstream GitHub Releases and runs it, then opens the Nexforce dashboard
  onboarding page in the default browser so the user can connect a worker.
  Does not register any workspace or worker itself — that flow lives in
  the dashboard UI.
.PRODUCT
  Nexforce Studio Desktop
.VENDOR
  Nexforce
.SOURCE
  https://github.com/different-ai/openwork/releases/latest
#>

$ErrorActionPreference = 'Stop'

$LATEST_API   = 'https://api.github.com/repos/different-ai/openwork/releases/latest'
$DASHBOARD_URL = 'https://nexforce-studio-dashboard-production.up.railway.app/dashboard/onboarding'

try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

Write-Host 'Looking up the latest OpenWork desktop release...'
try {
    # GitHub's REST API requires a User-Agent; -UseBasicParsing keeps PS 5.1 happy.
    $release = Invoke-RestMethod -Uri $LATEST_API -UseBasicParsing -Headers @{ 'User-Agent' = 'nexforce-work-installer' }
} catch {
    Write-Host ('[FAIL] could not reach ' + $LATEST_API + ' - ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host 'Please download the installer manually from https://github.com/different-ai/openwork/releases/latest'
    return
}

# Squirrel publishes a Setup.exe / -Setup.exe with no -ia32 / -arm64 suffix; pick the first match.
$asset = $release.assets | Where-Object {
    $_.name -match '\.exe$' -and $_.name -notmatch '\.blockmap$'
} | Select-Object -First 1

if (-not $asset) {
    Write-Host '[FAIL] no .exe asset on the latest release' -ForegroundColor Red
    Write-Host 'Please open https://github.com/different-ai/openwork/releases/latest and pick an installer manually.'
    return
}

$installer = Join-Path $env:TEMP $asset.name
Write-Host ('Downloading ' + $asset.name + ' (' + [int]($asset.size / 1024 / 1024) + ' MB) ...')
try {
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer -UseBasicParsing
} catch {
    Write-Host ('[FAIL] download failed: ' + $_.Exception.Message) -ForegroundColor Red
    return
}

Write-Host 'Launching the installer...'
try {
    Start-Process -FilePath $installer | Out-Null
} catch {
    Write-Host ('[WARN] could not auto-launch the installer; please run it manually: ' + $installer) -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Opening the Nexforce onboarding page in your default browser...'
try {
    Start-Process $DASHBOARD_URL | Out-Null
} catch {
    Write-Host ('[WARN] could not auto-open the browser; visit ' + $DASHBOARD_URL + ' manually') -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Done. Finish the installer, then complete onboarding in your browser.'
