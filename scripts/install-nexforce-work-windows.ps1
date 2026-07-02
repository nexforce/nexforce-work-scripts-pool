<#
.SYNOPSIS
  Nexforce Work — Windows static installer.
.DESCRIPTION
  Standalone signed installer. On every run it:
    1. Picks a random ephemeral port and starts a local HTTP listener on
       127.0.0.1.
    2. Opens the user's default browser at the Nexforce Work sign-in
       page with ?installerPort=<port>&installerState=<nonce>.
    3. The dashboard signs the user in (re-using any existing browser
       session) and redirects the browser back to
       http://127.0.0.1:<port>/?code=<grant>&state=<nonce>.
    4. The listener captures the grant, exchanges it for a Better Auth
       session token, and POSTs /v1/installer/dequeue to claim the
       install URL the Re-connect modal enqueued.
    5. iexes the server-rendered install body.

  Independent from OpenWork Desktop's sign-in state — the user signs in
  fresh each time the .exe runs, no LevelDB scraping or shared
  credentials. OpenWork Desktop is still required at install time so
  the rendered install body has a desktop server to talk to.
.PRODUCT
  Nexforce Work
.VENDOR
  Nexforce Global Corp.
#>

$ErrorActionPreference = 'Stop'

$NEXFORCE_BASE_URL = 'https://nexforce-studio-dashboard-production.up.railway.app'
$SIGNIN_URL_BASE   = "$NEXFORCE_BASE_URL/"
$EXCHANGE_URL      = "$NEXFORCE_BASE_URL/v1/auth/desktop-handoff/exchange"
$DEQUEUE_URL       = "$NEXFORCE_BASE_URL/v1/installer/dequeue"
$LOG_URL           = "$NEXFORCE_BASE_URL/v1/recover-workspaces/log"

try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
# System.Web hosts HttpUtility.UrlDecode (used to unpack the loopback
# callback's ?code=…&state=… query). PS5.1 doesn't load it by default.
try { Add-Type -AssemblyName System.Web } catch {}

# runId correlates every log POST from this one execution.
$runId = ((Get-Date).ToString('yyyyMMddHHmmss')) + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,8))
Write-Host ('Run ID: ' + $runId)
Write-Host ''

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

# ── Step 1: pick a free ephemeral port + nonce ──────────────────────
function Get-FreePort {
    $tcpListener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 0
    $tcpListener.Start()
    $p = $tcpListener.LocalEndpoint.Port
    $tcpListener.Stop()
    return $p
}

$port  = Get-FreePort
$state = (1..32 | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) }) -join ''
Log-Event 'install-loopback-bound' "port=$port"

# ── Step 2: start the loopback HTTP listener ─────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$port/")
try {
    $listener.Start()
} catch {
    Fail "Could not start the local sign-in listener on port $port. Another process may be holding it; retry."
}

# ── Step 3: open the browser at the sign-in URL ──────────────────────
$signInUrl = $SIGNIN_URL_BASE + '?desktopAuth=1&mode=sign-in' +
    '&installerPort=' + $port +
    '&installerState=' + $state
Write-Host 'Opening your browser to sign in to Nexforce Work...'
Write-Host ''
Write-Host '  If the browser does not open automatically, paste this URL:'
Write-Host "  $signInUrl"
Write-Host ''
try { Start-Process $signInUrl | Out-Null } catch {
    Write-Host '[WARN] could not auto-open the browser; paste the URL above into a browser.' -ForegroundColor Yellow
}

# ── Step 4: wait for the loopback callback ──────────────────────────
Write-Host 'Waiting for sign-in (5 minute timeout)...'

# .GetContext() blocks indefinitely; wrap it in an async-with-timeout so
# Ctrl+C is honored and a stalled sign-in surfaces a real error.
$asyncResult = $listener.BeginGetContext($null, $null)
$completed = $asyncResult.AsyncWaitHandle.WaitOne([TimeSpan]::FromMinutes(5))
if (-not $completed) {
    try { $listener.Stop() } catch {}
    Fail 'Sign-in timed out. Re-run this installer and complete the browser flow within 5 minutes.'
}
$ctx = $listener.EndGetContext($asyncResult)
$req = $ctx.Request
$res = $ctx.Response

$query = $req.Url.Query
$qs = @{}
if ($query) {
    foreach ($pair in ($query.TrimStart('?').Split('&'))) {
        if (-not $pair) { continue }
        $kv = $pair.Split('=', 2)
        $qs[$kv[0]] = if ($kv.Length -eq 2) { [System.Web.HttpUtility]::UrlDecode($kv[1]) } else { '' }
    }
}

$code = $qs['code']
$returnedState = $qs['state']

$bodyText = if ($code -and $returnedState -eq $state) {
    @"
<!doctype html><html><head><meta charset='utf-8'><title>Nexforce Work</title>
<style>body{font-family:system-ui;background:#0f172a;color:#e2e8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh}.box{background:#1e293b;padding:32px 40px;border-radius:12px;border:1px solid #334155;max-width:420px}h1{margin:0 0 8px;font-size:18px}p{margin:0;font-size:14px;color:#94a3b8}</style>
</head><body><div class='box'><h1>Sign-in complete</h1><p>You can close this tab. The Nexforce Work installer is now finishing on your machine.</p></div></body></html>
"@
} else {
    @"
<!doctype html><html><head><meta charset='utf-8'><title>Nexforce Work</title></head>
<body style='font-family:system-ui;padding:32px'><h1>Sign-in failed</h1>
<p>The installer received an unexpected response. Close this tab, re-run the installer, and try again.</p></body></html>
"@
}

$buf = [System.Text.Encoding]::UTF8.GetBytes($bodyText)
$res.ContentType = 'text/html; charset=utf-8'
$res.ContentLength64 = $buf.Length
$res.OutputStream.Write($buf, 0, $buf.Length)
$res.OutputStream.Close()
try { $listener.Stop() } catch {}

if (-not $code) { Fail 'Sign-in did not return a grant. Re-run the installer and try again.' }
if ($returnedState -ne $state) { Fail 'Sign-in returned an unexpected state — possible interference. Re-run the installer.' }
Log-Event 'install-grant-received' "len=$($code.Length)"

# ── Step 5: exchange grant for a session bearer ────────────────────
Write-Host 'Exchanging sign-in grant for a session token...'
$exchangeBody = (@{ grant = $code } | ConvertTo-Json -Compress)
try {
    $exch = Invoke-RestMethod -Method Post -Uri $EXCHANGE_URL `
        -Headers @{ 'Content-Type' = 'application/json' } `
        -Body $exchangeBody -TimeoutSec 12
} catch {
    Fail "Sign-in grant exchange failed: $($_.Exception.Message)"
}
$bearer = $exch.token
if (-not $bearer) { Fail 'Sign-in succeeded but no session token was returned.' }
Log-Event 'install-bearer-acquired' ''

# ── Step 6: dequeue the install token URL ──────────────────────────
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
$scriptUrl  = $dequeue.pending.scriptUrls.powershell
$bundleName = $dequeue.pending.bundleName
if (-not $scriptUrl) { Fail 'Server did not return a Windows install script URL.' }
Log-Event 'install-queue-hit' ('bundle=' + $bundleName)
Write-Host ('Installing: ' + $bundleName)

# ── Step 7: fetch + run the server-rendered install script ─────────
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
