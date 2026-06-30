# recover-workspaces (Windows) — standalone, signed-release version.
# Extracted from packages/nexforce-studio-dashboard-api/src/routes/recover-workspaces.ts's
# WINDOWS_PS1_BODY constant for compilation to a signed .exe via ps2exe + SignPath.
# The dashboard-served version at
#   GET /v1/recover-workspaces.ps1
# is regenerated from the same source. If you edit one, edit the other.

<#
.SYNOPSIS
  Nexforce OpenWork Desktop — workspace + opencode recovery script.
.DESCRIPTION
  Repairs the OpenWork desktop's local config (%APPDATA%\openwork\server.json
  and %APPDATA%\com.differentai.openwork\openwork-workspaces.json) when the
  UI surfaces "workspace_not_found" on a new session or "OpenCode is
  unavailable for this workspace". Operates only on the user's own
  AppData/Roaming files. Sends operation events to the vendor's
  diagnostics endpoint for support investigation.
.PRODUCT
  Nexforce Studio Desktop
.VENDOR
  Nexforce
.SOURCE
  https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces.ps1
.NOTES
  This file is regenerated on every redeploy from
    packages/nexforce-studio-dashboard-api/src/routes/recover-workspaces.ts
  in the Nexforce studio-server repo. Edit there, not here.
#>

# recover-workspaces (Windows) — fetched live from
# /v1/recover-workspaces.ps1. Edit the source in
# packages/nexforce-studio-dashboard-api/src/routes/recover-workspaces.ts
# and redeploy; the .bat stub picks it up on next run.
#
# Output policy (user-visible vs telemetry):
#   - The only Write-Host calls the user sees are the three milestone
#     messages: "Please open OpenWork Desktop application to continue...",
#     "[SUCCESS] Recovery succeeded!", "Automatically closing and
#     re-opening OpenWork Desktop application." Plus a final [FAIL] line
#     if something blew up.
#   - Every [recover-workspaces] line that prior versions printed is now
#     POSTed to /v1/recover-workspaces/log so Railway captures it. Same
#     for the initial + final contents of every file this script alters
#     (server.json, openwork-workspaces.json) with tokens redacted client-
#     side before send. Mirrors the install-snapshot diagnostics pattern
#     in workers/diagnostics.ts.

$ErrorActionPreference = 'Stop'

# runId correlates every log POST from this one execution. We print it
# visibly at the top so a user filing a support ticket can quote it.
$runId = ((Get-Date).ToString('yyyyMMddHHmmss')) + '-' + ([Guid]::NewGuid().ToString('N').Substring(0,8))
$logUrl = 'https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces/log'
Write-Host ('Run ID: ' + $runId)
Write-Host ''

# Token-redactor: any property name matching /token/i has its value replaced
# with "<redacted:N>". Recurses through nested objects + arrays. Returns a
# new tree; never mutates the input. Mirrors the install-snapshot redactor
# at workers/install-scripts.ts:531-537.
function Redact($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [string]) { return $v }
    if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { return $v }
    if ($v -is [System.Collections.IDictionary]) {
        $out = @{}
        foreach ($k in $v.Keys) {
            $val = $v[$k]
            if ($k -match 'token' -and $val -is [string] -and $val.Length -gt 0) {
                $out[$k] = ('<redacted:' + $val.Length + '>')
            } else {
                $out[$k] = Redact $val
            }
        }
        return $out
    }
    if ($v -is [array] -or $v -is [System.Collections.IList]) {
        return @($v | ForEach-Object { Redact $_ })
    }
    if ($v -is [PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($prop in $v.PSObject.Properties) {
            $val = $prop.Value
            if ($prop.Name -match 'token' -and $val -is [string] -and $val.Length -gt 0) {
                $out[$prop.Name] = ('<redacted:' + $val.Length + '>')
            } else {
                $out[$prop.Name] = Redact $val
            }
        }
        return $out
    }
    return $v
}

function Log([string]$event, [string]$note, $files) {
    try {
        $payload = @{
            runId    = $runId
            platform = 'Windows'
            event    = $event
        }
        if ($note) { $payload.note = $note }
        if ($files) { $payload.files = $files }
        $json = $payload | ConvertTo-Json -Depth 100 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        # Use HttpWebRequest so we work on PS 5.1 without TLS-handshake retries
        # eating into the recovery time-budget. 4s ceiling, fire-and-forget.
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch {}
        $req = [System.Net.HttpWebRequest]::Create($logUrl)
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Timeout = 4000
        $req.ReadWriteTimeout = 4000
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $resp = $req.GetResponse()
        $resp.Close()
    } catch {
        # Telemetry is best-effort; never bubble.
    }
}

function ReadJsonOrNull([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $p -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        Log 'parse-error' ($p + ' : ' + $_.Exception.Message) $null
        return $null
    }
}

function FileContentOrMissing([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return Get-Content -LiteralPath $p -Raw -Encoding UTF8 } catch { return $null }
}

# Hard cap on how much of one file we'll ship to /v1/recover-workspaces/log.
# 16 KiB is enough for any realistic server.json / openwork-workspaces.json
# (the user's are < 3 KiB). Past that we truncate with a marker so
# ConvertTo-Json can't churn through megabytes of nested-string escapes on
# PS5.1's slow serializer (the root cause of the 4.6 GiB / hung script
# observed when openwork-server-tokens.json had to be raw-shipped after
# ConvertFrom-Json choked on empty-key properties).
$MaxLoggedFileBytes = 16 * 1024

function TruncateIfLarge([string]$s) {
    if ($null -eq $s) { return $null }
    if ($s.Length -le $MaxLoggedFileBytes) { return $s }
    return $s.Substring(0, $MaxLoggedFileBytes) + "…<truncated:original=" + $s.Length + ">"
}

# PS 5.1's ConvertFrom-Json refuses JSON whose object has empty-string
# property names. openwork-server-tokens.json has exactly that shape:
#   { "workspaces": { "": {…}, "/path/…": {…} } }
# Workaround: System.Web.Script.Serialization.JavaScriptSerializer ships
# in System.Web.Extensions on every supported PS Windows version and has
# no empty-key allergy. Returns a Hashtable / ArrayList tree. Mirrors the
# same fallback at install-scripts.ts:1018-1027.
$WebExtensionsLoaded = $false
function EnsureWebExtensions {
    if ($script:WebExtensionsLoaded) { return }
    try { Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop; $script:WebExtensionsLoaded = $true } catch {}
}

function ReadJsonPermissive([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $raw = FileContentOrMissing $p
    if ($null -eq $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch {}
    EnsureWebExtensions
    if (-not $script:WebExtensionsLoaded) {
        Log 'parse-error' ($p + ' : ConvertFrom-Json failed and System.Web.Extensions unavailable') $null
        return $null
    }
    try {
        $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $ser.MaxJsonLength = [int]::MaxValue
        return $ser.DeserializeObject($raw)
    } catch {
        Log 'parse-error' ($p + ' : both ConvertFrom-Json and JavaScriptSerializer failed - ' + $_.Exception.Message) $null
        return $null
    }
}

function RedactedFileContent([string]$p) {
    $raw = FileContentOrMissing $p
    if ($null -eq $raw) { return $null }
    # We never attempt to round-trip parse -> redact -> serialize here.
    # That was the memory-hog path on PS5.1's ConvertTo-Json. Send the raw
    # text (truncated) and let the eyeballing happen in Railway. Token
    # values still need redacting though — anything that looks like
    # "<key>token<key>":"…" gets replaced with "<key>token<key>":"<redacted>".
    # Bounded-time regex on the truncated string.
    $truncated = TruncateIfLarge $raw
    # Regex is single-quoted in PS so backslashes survive PS parsing — but
    # we ALSO sit inside a JS backtick template (WINDOWS_PS1_BODY), so every
    # backslash needs doubling in the TS source to land as one backslash in
    # the served .ps1. The intended PS-side regex is:
    #   ("[^"]*[Tt]oken[^"]*"\s*:\s*)"[^"\]*(?:\.[^"\]*)*"
    # i.e. capture the "token-ish key" + colon, then match a JSON string
    # value (handling \" escapes inside).
    return [regex]::Replace(
        $truncated,
        '("[^"]*[Tt]oken[^"]*"\s*:\s*)"[^"\\]*(?:\\.[^"\\]*)*"',
        '$1"<redacted>"'
    )
}

function ComputeWsId([string]$realPath) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($realPath))
    $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
    return 'ws_' + $hex.Substring(0, 12)
}

function RealPathOf([string]$p) {
    try { return (Get-Item -LiteralPath $p).FullName } catch { return $p }
}

function BackupAndWrite([string]$targetPath, $obj) {
    $dir = Split-Path -Parent $targetPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $targetPath) {
        Copy-Item -LiteralPath $targetPath -Destination ($targetPath + '.bak') -Force
    }
    $tmp = $targetPath + '.tmp'
    # CRITICAL: PS5.1's Set-Content -Encoding UTF8 writes a 3-byte UTF-8
    # BOM. Node's JSON.parse — used by openwork-server's
    # readServerConfigFile (routes/workspaces.ts:178) — throws on a
    # leading BOM and returns 422 invalid_json. install-scripts.ts's
    # heal block (line 614-653) had this issue and works around it the
    # same way. Use UTF8Encoding($false) via .NET so no BOM is emitted
    # on either PS5.1 or PS7.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 100), $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $targetPath -Force
}

# Strip a leading UTF-8 BOM in-place if present. Called BEFORE we read
# the file's parsed object — fixes any server.json that a prior version
# of this script corrupted with PS5.1 Set-Content -Encoding UTF8.
function StripBomIfPresent([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($p)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $tail = New-Object byte[] ($bytes.Length - 3)
            [System.Array]::Copy($bytes, 3, $tail, 0, $tail.Length)
            Copy-Item -LiteralPath $p -Destination ($p + '.bombak') -Force
            [System.IO.File]::WriteAllBytes($p, $tail)
            return $true
        }
    } catch {}
    return $false
}

function Get-OpenworkLauncher {
    if ($env:LOCALAPPDATA) {
        $squirrelRoot = Join-Path $env:LOCALAPPDATA 'OpenWork'
        $updateExe = Join-Path $squirrelRoot 'Update.exe'
        if (Test-Path $updateExe) { return @{ Type = 'squirrel'; Path = $updateExe } }
        if (Test-Path $squirrelRoot) {
            $versioned = Get-ChildItem -Path $squirrelRoot -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending
            foreach ($d in $versioned) {
                $candidate = Join-Path $d.FullName 'OpenWork.exe'
                if (Test-Path $candidate) { return @{ Type = 'exe'; Path = $candidate } }
            }
        }
        $perUserExe = Join-Path $env:LOCALAPPDATA 'Programs\OpenWork\OpenWork.exe'
        if (Test-Path $perUserExe) { return @{ Type = 'exe'; Path = $perUserExe } }
    }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $candidate = Join-Path $base 'OpenWork\OpenWork.exe'
        if (Test-Path $candidate) { return @{ Type = 'exe'; Path = $candidate } }
    }
    return $null
}

function Start-Openwork {
    $launcher = Get-OpenworkLauncher
    if (-not $launcher) { return $false }
    try {
        if ($launcher.Type -eq 'squirrel') {
            Start-Process -FilePath $launcher.Path -ArgumentList '--processStart','OpenWork.exe' | Out-Null
        } else {
            Start-Process -FilePath $launcher.Path | Out-Null
        }
        return $true
    } catch { return $false }
}

function CollectLocals([System.Collections.Specialized.OrderedDictionary]$bag, $list, [string]$source) {
    if (-not $list) { return }
    foreach ($w in $list) {
        if (-not $w) { continue }
        if (('' + $w.workspaceType) -eq 'remote') { continue }
        $p = ('' + $w.path).Trim()
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) {
            Log 'path-missing' (('[' + $source + '] ') + ($w.id) + ' : path missing on disk: ' + $p) $null
            continue
        }
        $real = RealPathOf $p
        $key = $real.ToLower()
        if (-not $bag.Contains($key)) {
            $entry = [PSCustomObject]@{
                RealPath    = $real
                Name        = ('' + $w.name)
                DisplayName = ('' + $w.displayName)
                Preset      = ('' + $w.preset)
                DesktopId   = ''
                ServerId    = ''
                FromDesktop = $false
                FromServer  = $false
                CorrectId   = ''
            }
            if ($source -eq 'desktop') { $entry.DesktopId = ('' + $w.id); $entry.FromDesktop = $true }
            if ($source -eq 'server')  { $entry.ServerId  = ('' + $w.id); $entry.FromServer  = $true  }
            $bag[$key] = $entry
        } else {
            $existing = $bag[$key]
            if ($source -eq 'desktop') { $existing.DesktopId = ('' + $w.id); $existing.FromDesktop = $true }
            if ($source -eq 'server')  { $existing.ServerId  = ('' + $w.id); $existing.FromServer  = $true  }
            if (-not $existing.Name        -and $w.name)        { $existing.Name        = ('' + $w.name) }
            if (-not $existing.DisplayName -and $w.displayName) { $existing.DisplayName = ('' + $w.displayName) }
            if (-not $existing.Preset      -and $w.preset)      { $existing.Preset      = ('' + $w.preset) }
        }
    }
}

Log 'start' ('runId=' + $runId) $null

try {
    $serverDir   = Join-Path $env:APPDATA 'openwork'
    $serverPath  = Join-Path $serverDir 'server.json'
    $userData    = Join-Path $env:APPDATA 'com.differentai.openwork'
    $wsStatePath = Join-Path $userData 'openwork-workspaces.json'
    $foreignServer = Join-Path $userData 'server.json'

    $pathsNote = 'canonical=' + $serverPath + ' exists=' + (Test-Path -LiteralPath $serverPath) +
                 ' ui=' + $wsStatePath + ' exists=' + (Test-Path -LiteralPath $wsStatePath) +
                 ' foreign=' + $foreignServer + ' exists=' + (Test-Path -LiteralPath $foreignServer)
    Log 'paths' $pathsNote $null

    # Mirror install-scripts.ts:993-1003: gate on whether the OpenWork
    # process is RUNNING, not on whether server.json exists. server.json
    # persists across runs even after the user quits the desktop — so the
    # file-existence check from the prior version never surfaced the
    # "Please open OpenWork…" prompt for a returning user who had just
    # closed the app. Now we always check for the live process and prompt
    # + auto-launch if it's gone.
    if (-not (Get-Process -Name OpenWork -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host 'Please open OpenWork Desktop application to continue...'
        Start-Openwork | Out-Null
        $deadline = (Get-Date).AddSeconds(120)
        while (-not (Get-Process -Name OpenWork -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        if (-not (Get-Process -Name OpenWork -ErrorAction SilentlyContinue)) {
            throw "OpenWork Desktop didn't start in time. Open it manually, then re-run this script."
        }
    }

    # After the desktop is up, ensure the files we read actually materialised.
    # First-run race: process is up but userData hasn't been written yet.
    $fileDeadline = (Get-Date).AddSeconds(30)
    while (-not (Test-Path -LiteralPath $serverPath) -and -not (Test-Path -LiteralPath $wsStatePath) -and (Get-Date) -lt $fileDeadline) {
        Start-Sleep -Milliseconds 500
    }

    # Give the desktop (just-launched, or already-running) and its embedded
    # openwork-server a beat to finish settling: write any pending state
    # changes, bind a port, finalize boot. Without this we sometimes
    # probe before the embedded server is ready and read stale port
    # state, or miss a BOM that the desktop is about to introduce.
    Start-Sleep -Seconds 5

    Write-Host ''
    Write-Host 'Recovering workspaces...'

    # Heal BOM corruption in the canonical files BEFORE any read/write
    # below. Prior versions of this script used
    # Set-Content -Encoding UTF8, which on PS5.1 prepends a 3-byte UTF-8
    # BOM. Node's JSON.parse (openwork-server's readServerConfigFile,
    # routes/workspaces.ts:178) throws on a leading BOM and returns
    # 422 invalid_json, so the live server falls back to fileConfig = {}
    # and config.workspaces = [] — every workspace call then 404s with
    # workspace_not_found. Strip the BOM in place (with .bombak backup)
    # and the very-next desktop boot reads server.json cleanly.
    foreach ($bomPath in @($serverPath, $wsStatePath)) {
        if (StripBomIfPresent $bomPath) {
            Log 'bom-stripped' ('removed UTF-8 BOM from ' + $bomPath) $null
        }
    }

    # Initial state of every file we may alter — log BEFORE any rewrite, with
    # token values redacted client-side so the wire payload never carries
    # them. The foreign userData server.json is logged but never altered;
    # capturing it gives the Railway investigator the same picture the user
    # is staring at. We also snapshot openwork-server-state.json (port info)
    # and openwork-server-tokens.json (token hashes, redacted) so we can
    # cross-check what the LIVE openwork-server is bound to vs what
    # server.json says it should serve.
    $serverStatePath = Join-Path $userData 'openwork-server-state.json'
    $tokenStorePath  = Join-Path $userData 'openwork-server-tokens.json'
    $initialFiles = @{}
    $initialFiles['server.json'] = RedactedFileContent $serverPath
    $initialFiles['openwork-workspaces.json'] = RedactedFileContent $wsStatePath
    $initialFiles['openwork-server-state.json']  = RedactedFileContent $serverStatePath
    # Do NOT include openwork-server-tokens.json content — it has empty-string
    # property names that PS5.1 ConvertFrom-Json refuses, and shipping the
    # raw text via the initial-state payload was the trigger for the 4.6 GiB
    # PowerShell memory blowup in the prior run. Token-store existence /
    # hostToken extraction still happens in the live-probe block below via
    # JavaScriptSerializer (ReadJsonPermissive).
    $initialFiles['openwork-server-tokens.json'] = if (Test-Path -LiteralPath $tokenStorePath) { '<present, content elided>' } else { $null }
    if (Test-Path -LiteralPath $foreignServer) {
        $initialFiles['foreign-userData-server.json'] = RedactedFileContent $foreignServer
    }
    Log 'initial-state' '' $initialFiles

    # Read the two persisted files into PS objects up-front — both the
    # live-probe block (workspace-id probe, /workspaces/local POST) and
    # the recovery loops below need them.
    $server  = ReadJsonOrNull $serverPath
    $wsState = ReadJsonOrNull $wsStatePath

    # Helpers shared between the foreign-migrate block (below) and the
    # live-probe block (further down). PSCustomObject vs Hashtable handling
    # for fields read from JavaScriptSerializer-deserialized JSON.
    function EnumPairs($o) {
        if ($null -eq $o) { return @() }
        if ($o -is [System.Collections.IDictionary]) { return $o.GetEnumerator() }
        if ($o -is [PSCustomObject]) { return $o.PSObject.Properties | ForEach-Object { [PSCustomObject]@{ Key = $_.Name; Value = $_.Value } } }
        return @()
    }
    function GetField($o, $name) {
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { return $o[$name] }
        return $o.$name
    }

    # ── migrate stray foreign userData server.json ────────────────────────
    # Older install-scripts (powerShellOpencodeBaseUrlFixBlock) had a bug
    # where they wrote opencodeBaseUrl to %APPDATA%\com.differentai.openwork\
    # server.json instead of the canonical %APPDATA%\openwork\server.json.
    # The user's machine has the resulting stray 56-byte file. The bug is
    # fixed in install-scripts.ts now, but existing installs need the
    # opencodeBaseUrl migrated into the canonical file so the desktop's
    # embedded server picks it up on next boot.
    try {
        if (Test-Path -LiteralPath $foreignServer) {
            # DELIBERATELY DO NOT migrate opencodeBaseUrl. Prior runs of
            # this script copied it from the stray into the canonical
            # server.json — but that turned out harmful: managed-opencode
            # (embedded.ts boot) only auto-spawns if config.opencodeBaseUrl
            # is empty, so copying the stale URL in CAUSED the
            #   "OpenCode is unavailable for this workspace"
            # error by suppressing the desktop's spawn-on-boot. The
            # foreign file is foreign noise either way — just remove it
            # (with .bak), let the desktop's own manager spawn opencode
            # on the next boot, and the URL it picks lives only in
            # memory + per-workspace baseUrl (NOT in top-level
            # opencodeBaseUrl of server.json).
            try {
                Copy-Item -LiteralPath $foreignServer -Destination ($foreignServer + '.bak') -Force
                Remove-Item -LiteralPath $foreignServer -Force
                Log 'foreign-deleted' ('removed stray ' + $foreignServer + ' (backup: ' + $foreignServer + '.bak)') $null
            } catch {
                Log 'foreign-delete-fail' $_.Exception.Message $null
            }
        }
    } catch {
        Log 'foreign-cleanup-error' $_.Exception.Message $null
    }

    # ── heal stale opencodeBaseUrl in canonical server.json ─────────────────
    # If canonical server.json has a top-level opencodeBaseUrl pointing
    # at 127.0.0.1:<port> and nothing is listening on that port, the
    # desktop's embedded server boots with config.opencodeBaseUrl set to
    # a dead URL — managed-opencode spawn is skipped (embedded.ts:55
    # gates on !config.opencodeBaseUrl) and every workspace then surfaces
    # "OpenCode is unavailable for this workspace" in the UI. Detect the
    # dead URL via Get-NetTCPConnection and drop the field so the next
    # boot spawns fresh.
    try {
        if ($server) {
            $oc = ('' + (GetField $server 'opencodeBaseUrl')).Trim()
            if ($oc) {
                $deadPort = $false
                # IMPORTANT: this regex sits inside a JS backtick template
                # (WINDOWS_PS1_BODY), so every backslash needs doubling in TS
                # source to land as one backslash in the served .ps1.
                # The intended PS-side regex is:
                #   ^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)[:/]?(\d+)
                # i.e. loopback host followed by an optional ':' / '/' and a
                # port number. Prior version under-escaped \d, so PS saw
                # (d+) which matched literal "d+" and skipped every real
                # loopback URL down the "external" branch.
                if ($oc -match '^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)[:/]?(\d+)') {
                    $ocPort = [int]$Matches[2]
                    try {
                        $alive = Get-NetTCPConnection -LocalPort $ocPort -State Listen -ErrorAction Stop
                        if (-not $alive) { $deadPort = $true }
                    } catch {
                        # Get-NetTCPConnection throws "No matching MSFT_NetTCPConnection
                        # objects found" when there's no listener — that's a confirmed
                        # dead port, not a probe failure.
                        $deadPort = $true
                    }
                    if ($deadPort) {
                        Log 'stale-opencode-base-url' ('dropping opencodeBaseUrl=' + $oc + ' (nothing listening on port ' + $ocPort + ')') $null
                        # ConvertTo-Json on a PSCustomObject with the
                        # property removed: use PSObject.Properties.Remove
                        # so the serialized form really omits it.
                        $server.PSObject.Properties.Remove('opencodeBaseUrl')
                        BackupAndWrite $serverPath $server
                        Log 'stale-opencode-base-url-removed' 'canonical server.json no longer pins opencodeBaseUrl - desktop will spawn a fresh one on next boot' $null
                    } else {
                        Log 'opencode-base-url-alive' ('port ' + $ocPort + ' has a listener; leaving opencodeBaseUrl in place') $null
                    }
                } else {
                    # Non-loopback opencodeBaseUrl (e.g. a hosted opencode); leave it
                    # alone, the user configured it deliberately.
                    Log 'opencode-base-url-external' ('non-loopback opencodeBaseUrl=' + $oc + ' - left untouched') $null
                }
            }
        }
    } catch {
        Log 'stale-opencode-base-url-error' $_.Exception.Message $null
    }

    # ── env + process diagnostics ────────────────────────────────────────
    # Smoking gun from the prior run: live /workspaces returned
    # {"items":[],"workspaces":[]} despite server.json on disk having
    # two entries. The embedded server reads server.json once at boot,
    # so it must be reading a DIFFERENT file. The only override
    # resolveOpenworkServerConfigPath honors is OPENWORK_SERVER_CONFIG
    # (runtime.mjs:50-52). Dump every level of every env var that
    # could affect the embedded server's config resolution + parse,
    # plus the OpenWork process command lines.
    try {
        $envNames = @('OPENWORK_SERVER_CONFIG','OPENWORK_WORKSPACES','OPENWORK_DEV_MODE','OPENWORK_OPENCODE_BASE_URL','OPENWORK_OPENCODE_DIRECTORY','APPDATA','LOCALAPPDATA','XDG_CONFIG_HOME')
        $envReport = ''
        foreach ($name in $envNames) {
            $proc = ''
            try { $proc = ('' + ([Environment]::GetEnvironmentVariable($name, 'Process'))) } catch {}
            $user = ''
            try { $user = ('' + ([Environment]::GetEnvironmentVariable($name, 'User'))) } catch {}
            $mach = ''
            try { $mach = ('' + ([Environment]::GetEnvironmentVariable($name, 'Machine'))) } catch {}
            $envReport += $name + '|proc=' + $proc + '|user=' + $user + '|mach=' + $mach + [Environment]::NewLine
        }
        Log 'env-snapshot' '' @{ 'env.txt' = $envReport }
    } catch {
        Log 'env-snapshot-fail' $_.Exception.Message $null
    }

    try {
        # WMI/CIM gives us each process's CommandLine — exactly what we
        # need to see whether OpenWork was launched with --config or with
        # OPENWORK_SERVER_CONFIG-style overrides in its parent shell.
        $procReport = ''
        try {
            $procs = Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'openwork%' OR Name LIKE 'OpenWork%' OR Name LIKE 'opencode%'" -ErrorAction Stop
        } catch {
            $procs = @()
        }
        foreach ($p in $procs) {
            $procReport += 'PID=' + $p.ProcessId + ' Name=' + $p.Name + ' Cmd=' + ('' + $p.CommandLine) + [Environment]::NewLine
        }
        if (-not $procReport) { $procReport = '(no openwork/opencode processes via WMI — script may lack permissions)' }
        Log 'process-snapshot' '' @{ 'processes.txt' = TruncateIfLarge $procReport }
    } catch {
        Log 'process-snapshot-fail' $_.Exception.Message $null
    }

    # ── live openwork-server probe ────────────────────────────────────────
    # The whole point of this run is to ensure the LIVE openwork-server sees
    # the workspace. server.json on disk is necessary but not sufficient —
    # if the embedded server boot crashed, or never reloaded, or is the wrong
    # process bound to the wrong port, the UI sees workspace_not_found
    # regardless of what's on disk. Probe the actual running server so the
    # Railway log captures ground truth.
    try {
        $stateObj = ReadJsonPermissive $serverStatePath
        $tokenObj = ReadJsonPermissive $tokenStorePath
        $probePort = $null
        $probeHostToken = $null
        # EnumPairs / GetField are defined at script-top so the
        # foreign-migrate block above can use them too.
        # Collect (workspaceKey, port) pairs so we can correlate the live
        # server's port with the right hostToken/clientToken in the token
        # store (both files are keyed by the same normalized workspace path).
        # The prior version picked the FIRST entry which was 401 against the
        # /workspaces endpoint because the active server's tokens belong to
        # whatever workspace was the boot-time activeWorkspace, not
        # necessarily the first one in the map.
        $portPairs = @()
        if ($stateObj) {
            $wp = GetField $stateObj 'workspacePorts'
            if ($wp) {
                foreach ($pair in EnumPairs $wp) {
                    if ($pair.Value) { $portPairs += [PSCustomObject]@{ Key = $pair.Key; Port = [int]$pair.Value } }
                }
            }
            if (-not $portPairs -and (GetField $stateObj 'preferredPort')) {
                $portPairs += [PSCustomObject]@{ Key = ''; Port = [int](GetField $stateObj 'preferredPort') }
            }
        }
        if (-not $portPairs) { $portPairs = @() }

        # Pick the first live port — they all map to the SAME embedded server
        # (one process, sticky port per workspace) so any reachable one is
        # fine for the health/workspaces probes.
        if ($portPairs.Count -gt 0) { $probePort = $portPairs[0].Port }

        # Build a list of (clientToken, hostToken) candidates from the
        # tokens file, in workspace-key order. For each, we'll try
        # /workspaces until one returns 200 — that one is the active
        # workspace's token pair, which is what /workspace/:id/* also
        # requires.
        $tokenCandidates = @()
        if ($tokenObj) {
            $wmap = GetField $tokenObj 'workspaces'
            if ($wmap) {
                # Prefer keys that match a live port — the active workspace
                # is among them.
                $portKeys = @($portPairs | ForEach-Object { $_.Key })
                $orderedPairs = @()
                $rest = @()
                foreach ($pair in EnumPairs $wmap) {
                    if ($portKeys -contains $pair.Key) { $orderedPairs += $pair }
                    else { $rest += $pair }
                }
                $orderedPairs += $rest
                foreach ($pair in $orderedPairs) {
                    $ht = GetField $pair.Value 'hostToken'
                    $ct = GetField $pair.Value 'clientToken'
                    if ($ht -or $ct) {
                        $tokenCandidates += [PSCustomObject]@{
                            Key         = $pair.Key
                            HostToken   = if ($ht) { ('' + $ht) } else { '' }
                            ClientToken = if ($ct) { ('' + $ct) } else { '' }
                        }
                    }
                }
            }
        }

        Log 'live-probe-config' ('port=' + $probePort + ' tokenCandidates=' + $tokenCandidates.Count) $null
        if ($probePort) {
            $probeBase = 'http://127.0.0.1:' + $probePort
            try {
                $hr = Invoke-WebRequest -Uri ($probeBase + '/health') -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
                $hbody = [string]$hr.Content
                if ($hbody.Length -gt 180) { $hbody = $hbody.Substring(0, 180) }
                Log 'live-probe-health' ('status=' + $hr.StatusCode + ' body=' + $hbody) $null
            } catch {
                Log 'live-probe-health-fail' $_.Exception.Message $null
            }

            # Try /workspaces with each token candidate. The first non-401
            # response is the active token pair; keep it for the workspace-
            # scoped probe below.
            $activeTokens = $null
            foreach ($cand in $tokenCandidates) {
                $headers = @{}
                if ($cand.HostToken)   { $headers['x-openwork-host-token'] = $cand.HostToken }
                if ($cand.ClientToken) { $headers['Authorization'] = 'Bearer ' + $cand.ClientToken }
                try {
                    $wsResp = Invoke-WebRequest -Uri ($probeBase + '/workspaces') -UseBasicParsing -TimeoutSec 6 -Headers $headers -ErrorAction Stop
                    $bodyText = [string]$wsResp.Content
                    $bodyTrunc = TruncateIfLarge $bodyText
                    Log 'live-probe-workspaces' ('status=' + $wsResp.StatusCode + ' bytes=' + $bodyText.Length + ' key=' + $cand.Key) @{ 'live-probe-workspaces.json' = $bodyTrunc }
                    $activeTokens = $cand
                    break
                } catch {
                    $exMsg = $_.Exception.Message
                    Log 'live-probe-workspaces-401' ('key=' + $cand.Key + ' err=' + $exMsg) $null
                }
            }
            if (-not $activeTokens -and $tokenCandidates.Count -eq 0) {
                Log 'live-probe-workspaces-skipped' 'no token candidates in openwork-server-tokens.json' $null
            }

            # Workspace-scoped probe — reproduce the user's failing UI call.
            # If openwork-workspaces.json's selectedId is X, the UI's
            # "new session" POSTs /workspace/X/opencode/session.
            # We GET /workspace/X/session-groups (also goes through
            # resolveWorkspace) and log status + body. If it 404s with
            # workspace_not_found, we've directly captured the user's bug
            # against the LIVE server's in-memory state.
            $probeWorkspaceId = ''
            if ($wsState) { $probeWorkspaceId = ('' + (GetField $wsState 'selectedId')) }
            if ($probeWorkspaceId -and $activeTokens) {
                $headers = @{}
                if ($activeTokens.HostToken)   { $headers['x-openwork-host-token'] = $activeTokens.HostToken }
                if ($activeTokens.ClientToken) { $headers['Authorization'] = 'Bearer ' + $activeTokens.ClientToken }
                try {
                    $sgResp = Invoke-WebRequest -Uri ($probeBase + '/workspace/' + $probeWorkspaceId + '/session-groups') -UseBasicParsing -TimeoutSec 6 -Headers $headers -ErrorAction Stop
                    $sgBody = [string]$sgResp.Content
                    $sgTrunc = TruncateIfLarge $sgBody
                    Log 'live-probe-workspace-id' ('id=' + $probeWorkspaceId + ' status=' + $sgResp.StatusCode + ' bytes=' + $sgBody.Length) @{ 'live-probe-workspace-id.json' = $sgTrunc }
                } catch {
                    # Capture the 4xx/5xx body — that's where we'll see the
                    # actual { code: "workspace_not_found", ... } payload.
                    $errBody = ''
                    try {
                        $errResp = $_.Exception.Response
                        if ($errResp) {
                            $reader = New-Object System.IO.StreamReader($errResp.GetResponseStream())
                            $errBody = $reader.ReadToEnd()
                            $reader.Close()
                        }
                    } catch {}
                    Log 'live-probe-workspace-id-fail' ('id=' + $probeWorkspaceId + ' err=' + $_.Exception.Message + ' body=' + $errBody.Substring(0, [Math]::Min(300, $errBody.Length))) $null
                }
            } elseif ($probeWorkspaceId -and -not $activeTokens) {
                Log 'live-probe-workspace-id-skipped' ('id=' + $probeWorkspaceId + ' reason=no-active-tokens') $null
            }

            # Who owns the port? If the listener at port isn't actually
            # OpenWork.exe — e.g. a stray "openwork start" from a
            # terminal that was never killed — that explains the empty
            # /workspaces response: a different process, with its own
            # in-memory config, is answering at the port the desktop
            # thinks it should be talking to.
            try {
                $conns = Get-NetTCPConnection -LocalPort $probePort -State Listen -ErrorAction Stop
                $portReport = ''
                foreach ($c in $conns) {
                    $owner = ''
                    try {
                        $proc = Get-Process -Id $c.OwningProcess -ErrorAction Stop
                        $owner = 'PID=' + $c.OwningProcess + ' Name=' + $proc.ProcessName + ' Path=' + ('' + $proc.Path)
                    } catch {
                        $owner = 'PID=' + $c.OwningProcess + ' (could not resolve)'
                    }
                    $portReport += $owner + [Environment]::NewLine
                }
                if (-not $portReport) { $portReport = '(no listener on ' + $probePort + ')' }
                Log 'live-probe-port-owner' ('port=' + $probePort) @{ 'port-owner.txt' = $portReport }
            } catch {
                Log 'live-probe-port-owner-fail' $_.Exception.Message $null
            }

            # DELIBERATELY DO NOT call POST /workspaces/local on the live
            # server as a self-heal. The live server boots with
            # config.workspaces = [] whenever server.json on disk had a
            # BOM (the symptom we're trying to fix), so any POST that
            # adds a workspace then triggers persistServerWorkspaceState
            # (routes/workspaces.ts:209-216) writes
            #   { ...parsedFromDisk, workspaces: config.workspaces.map(...) }
            # back — and config.workspaces only has the just-added
            # entry. Every other workspace that lived in the on-disk
            # server.json gets erased. The prior version of this script
            # did exactly that and deleted the user's REMOTE workspace
            # rem_ws_c4aee514b220 from server.json (1871 -> 337 bytes,
            # remote entry + its authorizedRoot both gone).
            #
            # The actual fix is the bom-strip + the desktop kill+relaunch
            # at the end of this script: the freshly-booted server reads
            # the (now BOM-free) server.json and config.workspaces gets
            # all entries from disk in one shot — no destructive write.
            Log 'live-server-create-local-skipped' 'avoided destructive POST /workspaces/local (would erase other entries from server.json)' $null
        } else {
            Log 'live-probe-skipped' 'no port found in openwork-server-state.json' $null
        }
    } catch {
        Log 'live-probe-error' $_.Exception.Message $null
    }

    $byRealPath = New-Object 'System.Collections.Specialized.OrderedDictionary'
    if ($wsState -and $wsState.workspaces) { CollectLocals $byRealPath @($wsState.workspaces) 'desktop' }
    if ($server  -and $server.workspaces)  { CollectLocals $byRealPath @($server.workspaces)  'server'  }

    Log 'found' ('count=' + $byRealPath.Count) $null
    if ($byRealPath.Count -eq 0) {
        Log 'noop' 'no LOCAL workspaces in either file' $null
        Write-Host ''
        Write-Host '[SUCCESS] Recovery succeeded!' -ForegroundColor Green
        Write-Host 'Nothing to do - no LOCAL workspaces registered.'
        return
    }

    $idMap = @{}
    foreach ($key in @($byRealPath.Keys)) {
        $e = $byRealPath[$key]
        $e.CorrectId = ComputeWsId $e.RealPath
        if ($e.DesktopId -and $e.DesktopId -ne $e.CorrectId) { $idMap[$e.DesktopId] = $e.CorrectId }
        if ($e.ServerId  -and $e.ServerId  -ne $e.CorrectId) { $idMap[$e.ServerId]  = $e.CorrectId }
    }

    # ── patch server.json ───────────────────────────────────────────────────
    $serverWorkspaces = @()
    if ($server -and $server.workspaces) { $serverWorkspaces = @($server.workspaces) }
    $serverDirty = $false
    $added = 0; $rewritten = 0; $unchanged = 0
    foreach ($key in @($byRealPath.Keys)) {
        $e = $byRealPath[$key]
        $existing = $null
        foreach ($w in $serverWorkspaces) {
            $p = ('' + $w.path).Trim()
            if (-not $p) { continue }
            if ((RealPathOf $p).ToLower() -eq $key) { $existing = $w; break }
        }
        if ($existing) {
            $existingId = ('' + $existing.id)
            if ($e.CorrectId -ne $existingId) {
                Log 'server-id-rewrite' ('old=' + $existingId + ' new=' + $e.CorrectId + ' path=' + $e.RealPath) $null
                $existing.id = $e.CorrectId
                $existing.path = $e.RealPath
                if (-not (('' + $existing.workspaceType))) {
                    $existing | Add-Member -NotePropertyName workspaceType -NotePropertyValue 'local' -Force
                }
                $serverDirty = $true
                $rewritten++
            } else {
                $unchanged++
            }
        } else {
            Log 'server-add' ('id=' + $e.CorrectId + ' path=' + $e.RealPath) $null
            if ($e.Name)   { $name   = $e.Name }   else { $name   = Split-Path -Leaf $e.RealPath }
            if ($e.Preset) { $preset = $e.Preset } else { $preset = 'starter' }
            $newEntry = [PSCustomObject]@{
                id            = $e.CorrectId
                path          = $e.RealPath
                name          = $name
                preset        = $preset
                workspaceType = 'local'
            }
            if ($e.DisplayName) {
                $newEntry | Add-Member -NotePropertyName displayName -NotePropertyValue $e.DisplayName
            }
            $serverWorkspaces = @($serverWorkspaces) + @($newEntry)
            $serverDirty = $true
            $added++
        }
    }

    # Restore any REMOTE workspaces that exist in openwork-workspaces.json
    # but not in server.json (CollectLocals skipped them above because the
    # main loop only cares about LOCAL ids). The earlier destructive POST
    # /workspaces/local in this script deleted user remotes from server.json
    # on machines where the live server's config.workspaces was empty due
    # to a BOM-corrupted server.json. Copy the full remote entry verbatim
    # from openwork-workspaces.json (it has openworkToken, baseUrl,
    # openworkHostUrl, openworkWorkspaceId — everything server.json needs).
    $remoteRestored = 0
    if ($wsState -and $wsState.workspaces) {
        foreach ($uw in @($wsState.workspaces)) {
            if (-not $uw) { continue }
            if (('' + $uw.workspaceType) -ne 'remote') { continue }
            $uwId = ('' + $uw.id).Trim()
            if (-not $uwId) { continue }
            $alreadyPresent = $false
            foreach ($sw in $serverWorkspaces) {
                if (('' + $sw.id).Trim() -eq $uwId) { $alreadyPresent = $true; break }
            }
            if ($alreadyPresent) { continue }
            Log 'server-remote-restore' ('id=' + $uwId + ' from openwork-workspaces.json') $null
            $remoteEntry = [PSCustomObject]@{
                id            = $uwId
                workspaceType = 'remote'
            }
            foreach ($prop in @('path','name','preset','remoteType','baseUrl','directory','displayName','openworkHostUrl','openworkToken','openworkClientToken','openworkHostToken','openworkWorkspaceId','openworkWorkspaceName','sandboxBackend','sandboxRunId','sandboxContainerName')) {
                $v = $uw.$prop
                if ($null -ne $v -and ('' + $v) -ne '') {
                    $remoteEntry | Add-Member -NotePropertyName $prop -NotePropertyValue $v -Force
                }
            }
            $serverWorkspaces = @($serverWorkspaces) + @($remoteEntry)
            $serverDirty = $true
            $remoteRestored++
        }
    }
    if ($remoteRestored -gt 0) {
        Log 'server-remote-restore-done' ('restored=' + $remoteRestored + ' remote workspace(s) into server.json') $null
    }

    if ($serverDirty) {
        if (-not $server) { $server = [PSCustomObject]@{ workspaces = @(); authorizedRoots = @() } }
        $server.workspaces = $serverWorkspaces
        if (-not $server.authorizedRoots) {
            $server | Add-Member -NotePropertyName authorizedRoots -NotePropertyValue @() -Force
        }
        $existingRoots = @($server.authorizedRoots)
        foreach ($key in @($byRealPath.Keys)) {
            $real = $byRealPath[$key].RealPath
            if (-not ($existingRoots | Where-Object { $_ -ieq $real })) { $existingRoots += $real }
        }
        # Also seed authorizedRoots for the remote-workspace paths so the
        # openwork-server's isAuthorizedRoot check (server.ts:2423) doesn't
        # 403 on them after restore.
        if ($wsState -and $wsState.workspaces) {
            foreach ($uw in @($wsState.workspaces)) {
                if (-not $uw) { continue }
                if (('' + $uw.workspaceType) -ne 'remote') { continue }
                $rp = ('' + $uw.path).Trim()
                if (-not $rp) { continue }
                if (-not ($existingRoots | Where-Object { $_ -ieq $rp })) { $existingRoots += $rp }
            }
        }
        $server.authorizedRoots = $existingRoots
        BackupAndWrite $serverPath $server
        Log 'server-written' ('added=' + $added + ' idRewritten=' + $rewritten + ' unchanged=' + $unchanged + ' remoteRestored=' + $remoteRestored) $null
    } else {
        Log 'server-clean' ('unchanged=' + $unchanged) $null
    }

    # ── patch openwork-workspaces.json ──────────────────────────────────────
    if ($wsState) {
        $uiDirty = $false
        $uiWorkspaces = @($wsState.workspaces)
        foreach ($w in $uiWorkspaces) {
            if (-not $w) { continue }
            if (('' + $w.workspaceType) -eq 'remote') { continue }
            $p = ('' + $w.path).Trim()
            if (-not $p) { continue }
            $real = RealPathOf $p
            $key = $real.ToLower()
            if (-not $byRealPath.Contains($key)) { continue }
            $correct = $byRealPath[$key].CorrectId
            if (('' + $w.id) -ne $correct) {
                Log 'ui-id-rewrite' ('old=' + ('' + $w.id) + ' new=' + $correct + ' path=' + $real) $null
                $w.id = $correct
                $w.path = $real
                $uiDirty = $true
            }
        }
        foreach ($selField in @('selectedId','watchedId','activeId','selectedWorkspaceId','watchedWorkspaceId')) {
            if (-not ($wsState.PSObject.Properties.Name -contains $selField)) { continue }
            $cur = ('' + $wsState.$selField)
            if (-not $cur) { continue }
            if ($idMap.ContainsKey($cur)) {
                $new = $idMap[$cur]
                Log 'ui-selection-rewrite' ($selField + ': old=' + $cur + ' new=' + $new) $null
                $wsState.$selField = $new
                $uiDirty = $true
            }
        }
        if ($uiDirty) {
            $wsState.workspaces = $uiWorkspaces
            BackupAndWrite $wsStatePath $wsState
            Log 'ui-written' '' $null
        } else {
            Log 'ui-clean' '' $null
        }
    }

    # ── opencode.jsonc cleanup pass (401 invalid_api_key fix) ───────────────
    $deleted = 0; $missing = 0; $errors = 0
    foreach ($key in @($byRealPath.Keys)) {
        $e = $byRealPath[$key]
        $jsonc = Join-Path $e.RealPath 'opencode.jsonc'
        if (-not (Test-Path -LiteralPath $jsonc)) {
            $missing++
            continue
        }
        try {
            Remove-Item -LiteralPath $jsonc -Force
            Log 'opencode-jsonc-deleted' $jsonc $null
            $deleted++
        } catch {
            Log 'opencode-jsonc-delete-failed' ($jsonc + ' : ' + $_.Exception.Message) $null
            $errors++
        }
    }
    Log 'opencode-jsonc-pass' ('deleted=' + $deleted + ' missing=' + $missing + ' errors=' + $errors) $null

    # ── final state of altered files, for Railway-side audit ────────────────
    $finalFiles = @{}
    $finalFiles['server.json'] = RedactedFileContent $serverPath
    $finalFiles['openwork-workspaces.json'] = RedactedFileContent $wsStatePath
    Log 'final-state' '' $finalFiles

    if ($errors -gt 0) {
        Write-Host ('[FAIL] one or more opencode.jsonc deletions errored. See Railway runId=' + $runId) -ForegroundColor Red
        return
    }

    Write-Host ''
    Write-Host '[SUCCESS] Recovery succeeded!' -ForegroundColor Green
    Write-Host 'Automatically closing and re-opening OpenWork Desktop application.'
    try {
        Get-Process -Name OpenWork -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}
    $relaunchDeadline = (Get-Date).AddSeconds(60)
    $relaunched = $false
    while ((Get-Date) -lt $relaunchDeadline) {
        if (Start-Openwork) { $relaunched = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $relaunched) {
        Log 'relaunch-failed' 'auto-relaunch did not start OpenWork' $null
    } else {
        Log 'relaunch-ok' '' $null
    }
    Log 'done' '' $null
} catch {
    Log 'fail' $_.Exception.Message $null
    Write-Host ('[FAIL] ' + $_.Exception.Message + ' (runId=' + $runId + ')') -ForegroundColor Red
}
