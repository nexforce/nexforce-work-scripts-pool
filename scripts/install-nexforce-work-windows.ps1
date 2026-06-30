<#
.SYNOPSIS
  Nexforce Work — Windows static installer.
.DESCRIPTION
  Static signed installer. The user signs in to OpenWork Desktop and clicks
  Re-connect on https://nexforce-studio-dashboard-staging.up.railway.app/
  dashboard/agents-run; that enqueues a single-use install token server-
  side. This installer scans the OpenWork desktop's Chromium LevelDB for
  the bearer the desktop already uses, POSTs the same bearer to the dash-
  board's /v1/installer/dequeue, and iexes the server-rendered install
  script that comes back. All the heavy install logic lives server-side
  in renderPowerShellBundleInstall — this script's job is just discovery
  + auth + dequeue + iex.
.PRODUCT
  Nexforce Work
.VENDOR
  Nexforce Global Corp.
#>

$ErrorActionPreference = 'Stop'

$NEXFORCE_BASE_URL = 'https://nexforce-studio-dashboard-staging.up.railway.app'
$DEQUEUE_URL       = "$NEXFORCE_BASE_URL/v1/installer/dequeue"
$ME_URL            = "$NEXFORCE_BASE_URL/v1/me"
$LOG_URL           = "$NEXFORCE_BASE_URL/v1/recover-workspaces/log"

# OpenWork desktop paths on Windows. APPDATA = %AppData% =
# C:\Users\<user>\AppData\Roaming.
$BOOTSTRAP_PATH    = Join-Path $env:APPDATA 'openwork\desktop-bootstrap.json'
$LEVELDB_DIR       = Join-Path $env:APPDATA 'com.differentai.openwork\Local Storage\leveldb'

try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}

# runId correlates every log POST from this one execution. Printed
# visibly so a user filing a support ticket can quote it.
$runId = ((Get-Date).ToString('yyyyMMddHHmmss')) + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,8))
Write-Host ('Run ID: ' + $runId)
Write-Host ''

# Best-effort telemetry. Same shape + endpoint as the recovery scripts:
# {runId, platform, event, note?}. Swallow every error; installer must
# run even if diagnostics is unreachable.
function Log-Event([string]$event, [string]$note) {
    try {
        $payload = @{ runId = $runId; platform = 'Windows'; event = $event }
        if ($note) { $payload.note = $note }
        $json  = $payload | ConvertTo-Json -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $req   = [System.Net.HttpWebRequest]::Create($LOG_URL)
        $req.Method = 'POST'; $req.ContentType = 'application/json'
        $req.Timeout = 4000; $req.ReadWriteTimeout = 4000
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length); $stream.Close()
        $resp = $req.GetResponse(); $resp.Close()
    } catch {}
}

function Fail([string]$msg) {
    Write-Host ('[FAIL] ' + $msg + ' (runId=' + $runId + ')') -ForegroundColor Red
    Log-Event 'install-fail' $msg
    Write-Host ''
    Write-Host 'Press Enter to close...'
    [void](Read-Host)
    exit 1
}

Log-Event 'install-start' "runId=$runId"

# ── Step 1: validate desktop is pointed at Nexforce production ────────
#
# desktop-bootstrap.json is the file the desktop reads at boot to decide
# which dashboard origin to use. If the user's installed OpenWork against
# a different baseUrl (OpenWork upstream, a custom self-host, etc.) we
# refuse to install — the install token we'd dequeue from Nexforce would
# never match what the desktop actually talks to.
Write-Host 'Checking OpenWork Desktop configuration...'
if (-not (Test-Path -LiteralPath $BOOTSTRAP_PATH)) {
    Fail "OpenWork Desktop is not installed (no $BOOTSTRAP_PATH). Install OpenWork Desktop and sign in to Nexforce Work first."
}

$bootstrap = $null
try {
    $bootstrap = (Get-Content -LiteralPath $BOOTSTRAP_PATH -Raw -Encoding UTF8) | ConvertFrom-Json
} catch {
    Fail "Could not read $BOOTSTRAP_PATH ($_)."
}
# PS5.1 (Windows default) has no `??` operator; use a plain if/else.
$bootstrapBase = if ($bootstrap.baseUrl) { ([string]$bootstrap.baseUrl).TrimEnd('/') } else { '' }
if (-not $bootstrapBase) {
    Fail 'OpenWork Desktop has no configured dashboard URL. Sign in to Nexforce Work in OpenWork Desktop first.'
}
if ($bootstrapBase -ne $NEXFORCE_BASE_URL.TrimEnd('/')) {
    Fail "OpenWork Desktop is pointed at $bootstrapBase, not Nexforce Work ($NEXFORCE_BASE_URL). Sign out of OpenWork Desktop and sign back in via Nexforce Work."
}

# ── Step 2: scrape the desktop's session bearer ──────────────────────
#
# Chromium localStorage lives in LevelDB at:
#   %APPDATA%\com.differentai.openwork\Local Storage\leveldb\
# under key `openwork.den.authToken`. The desktop writes it on sign-in.
# We scan *.log (write-ahead log, plaintext) and *.ldb (compacted SST,
# snappy-compressed) files for the UTF-16LE byte sequence of the key,
# then look forward for a 64-char hex string (Better Auth's 32-byte
# session token, hex-encoded). When the value lives in an .ldb its
# snappy-compressed payload won't match; the installer prints a
# "sign out + back in to OpenWork Desktop" recovery message in that case.
function Find-DesktopBearer {
    if (-not (Test-Path -LiteralPath $LEVELDB_DIR)) { return $null }
    $keyText = 'openwork.den.authToken'
    $keyBytes = [System.Text.Encoding]::Unicode.GetBytes($keyText)

    $files = Get-ChildItem -Path $LEVELDB_DIR -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -eq '.log' -or $_.Extension -eq '.ldb' }
    foreach ($f in $files) {
        try { $data = [System.IO.File]::ReadAllBytes($f.FullName) } catch { continue }
        if (-not $data -or $data.Length -lt $keyBytes.Length) { continue }

        $i = 0
        while ($true) {
            $found = -1
            for ($j = $i; $j -le $data.Length - $keyBytes.Length; $j++) {
                $match = $true
                for ($k = 0; $k -lt $keyBytes.Length; $k++) {
                    if ($data[$j + $k] -ne $keyBytes[$k]) { $match = $false; break }
                }
                if ($match) { $found = $j; break }
            }
            if ($found -lt 0) { break }

            $windowStart = $found + $keyBytes.Length
            $windowEnd   = [Math]::Min($data.Length - 1, $windowStart + 1024)
            $windowLen   = $windowEnd - $windowStart + 1

            # Try UTF-16LE: 64 consecutive (lowByte=hex, highByte=0).
            for ($p = 0; $p -le $windowLen - 128; $p++) {
                $ok = $true
                for ($q = 0; $q -lt 64; $q++) {
                    $lo = $data[$windowStart + $p + $q * 2]
                    $hi = $data[$windowStart + $p + $q * 2 + 1]
                    if ($hi -ne 0) { $ok = $false; break }
                    if (-not ((($lo -ge 0x30) -and ($lo -le 0x39)) -or (($lo -ge 0x61) -and ($lo -le 0x66)))) {
                        $ok = $false; break
                    }
                }
                if ($ok) {
                    return [System.Text.Encoding]::Unicode.GetString($data, $windowStart + $p, 128)
                }
            }

            # Try UTF-8: 64 consecutive hex bytes.
            for ($p = 0; $p -le $windowLen - 64; $p++) {
                $ok = $true
                for ($q = 0; $q -lt 64; $q++) {
                    $b = $data[$windowStart + $p + $q]
                    if (-not ((($b -ge 0x30) -and ($b -le 0x39)) -or (($b -ge 0x61) -and ($b -le 0x66)))) {
                        $ok = $false; break
                    }
                }
                if ($ok) {
                    return [System.Text.Encoding]::ASCII.GetString($data, $windowStart + $p, 64)
                }
            }

            $i = $found + 1
        }
    }
    return $null
}

Write-Host 'Reading sign-in credential from OpenWork Desktop...'
$bearer = Find-DesktopBearer
if (-not $bearer) {
    Fail 'Could not find a Nexforce Work sign-in in OpenWork Desktop. Sign out of OpenWork Desktop and sign back in to Nexforce Work, then re-run this installer.'
}
Log-Event 'install-bearer-found' ('len=' + $bearer.Length)

# ── Step 3: confirm the bearer still works ──────────────────────────
Write-Host 'Verifying your Nexforce Work session...'
try {
    $me = Invoke-RestMethod -Uri $ME_URL -Headers @{ Authorization = "Bearer $bearer" } -TimeoutSec 8
} catch {
    Fail "Your Nexforce Work session has expired. Sign out of OpenWork Desktop and sign back in, then re-run this installer."
}
if (-not $me) { Fail 'Nexforce Work session check returned an unexpected response.' }
$meUserId = if ($me.user -and $me.user.id) { $me.user.id } elseif ($me.id) { $me.id } else { 'unknown' }
Log-Event 'install-me-ok' ('userId=' + $meUserId)

# ── Step 4: dequeue the install token URL ───────────────────────────
Write-Host 'Asking Nexforce Work for the agents to install...'
try {
    $dequeue = Invoke-RestMethod -Method Post -Uri $DEQUEUE_URL `
        -Headers @{ Authorization = "Bearer $bearer"; 'Content-Type' = 'application/json' } `
        -Body '{}' -TimeoutSec 12
} catch {
    Fail "Could not reach Nexforce Work to fetch the install queue: $($_.Exception.Message)"
}
if (-not $dequeue.pending) {
    Write-Host ''
    Write-Host 'No agents to be installed.'
    Write-Host 'Please, open the Re-connect modal on Nexforce Work and run this installer again.'
    Write-Host ''
    Log-Event 'install-queue-empty' ''
    Write-Host 'Press Enter to close...'
    [void](Read-Host)
    return
}
$scriptUrl = $dequeue.pending.scriptUrls.powershell
if (-not $scriptUrl) { Fail 'Server did not return a Windows install script URL.' }
$bundleName = $dequeue.pending.bundleName
Log-Event 'install-queue-hit' ('bundle=' + $bundleName)
Write-Host ('Installing: ' + $bundleName)

# ── Step 5: fetch + run the server-rendered install script ──────────
#
# The script body returned by /openwork/install.ps1?token=… is the full
# renderPowerShellBundleInstall output — discovers the desktop's loop-
# back port + host token, mkdir's remote-workspaces/rem_<id>, POSTs
# /workspaces/remote per agent, merges openwork-workspaces.json, and
# auto-restarts OpenWork. Single-use: the GET above consumes the
# install token row.
try {
    $body = (Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing -Headers @{ 'User-Agent' = 'nexforce-work-installer' }).Content
} catch {
    Fail "Could not download the install script: $($_.Exception.Message)"
}
if (-not $body) { Fail 'Server returned an empty install script.' }

Log-Event 'install-script-fetched' ('bytes=' + $body.Length)
Invoke-Expression $body

Log-Event 'install-done' ''
Write-Host ''
Write-Host 'Press Enter to close...'
[void](Read-Host)
