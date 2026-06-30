#!/usr/bin/env bash
# Nexforce Work — macOS static installer.
#
# Standalone installer. On every run:
#   1. Picks a free ephemeral port and starts a loopback HTTP listener
#      (inline python3) on 127.0.0.1:<port>.
#   2. Opens the user's default browser at the Nexforce Work sign-in
#      page with ?installerPort=<port>&installerState=<nonce>.
#   3. The dashboard signs the user in and redirects the browser back
#      to http://127.0.0.1:<port>/?code=<grant>&state=<nonce>.
#   4. The listener captures the grant, exchanges it for a Better Auth
#      session token, and POSTs /v1/installer/dequeue to claim the
#      install URL the Re-connect modal enqueued.
#   5. Bashes the server-rendered install body.
#
# Independent from OpenWork Desktop's sign-in state — fresh browser
# sign-in every run, no LevelDB scraping, no shared credentials.

set -u

NEXFORCE_BASE_URL='https://nexforce-studio-dashboard-staging.up.railway.app'
SIGNIN_URL_BASE="$NEXFORCE_BASE_URL/"
EXCHANGE_URL="$NEXFORCE_BASE_URL/v1/auth/desktop-handoff/exchange"
DEQUEUE_URL="$NEXFORCE_BASE_URL/v1/installer/dequeue"
LOG_URL="$NEXFORCE_BASE_URL/v1/recover-workspaces/log"

run_id="$(date +%Y%m%d%H%M%S)-$(head -c8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c8)"
echo "Run ID: $run_id"
echo ""

log_event() {
  local event=$1
  local note=${2:-}
  local payload
  if [ -n "$note" ]; then
    local esc
    esc=$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null)
    payload="{\"runId\":\"$run_id\",\"platform\":\"macOS\",\"event\":\"$event\",\"note\":\"$esc\"}"
  else
    payload="{\"runId\":\"$run_id\",\"platform\":\"macOS\",\"event\":\"$event\"}"
  fi
  curl -fsS -X POST -H 'Content-Type: application/json' --max-time 4 -d "$payload" "$LOG_URL" >/dev/null 2>&1 || true
}

fail() {
  local msg=$1
  echo ""
  echo "[FAIL] $msg (runId=$run_id)" >&2
  log_event 'install-fail' "$msg"
  exit 1
}

log_event 'install-start' "runId=$run_id"

command -v python3 >/dev/null 2>&1 || fail 'python3 is required to host the sign-in callback listener. Install python3 and retry.'

# ── Step 1: pick free port + nonce ──────────────────────────────────
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
state=$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')
log_event 'install-loopback-bound' "port=$port"

# ── Step 2: start the loopback listener in the background ───────────
# Write the captured ?code=&state= to a temp file the parent reads.
result_file=$(mktemp -t nexforce-installer.XXXXXX)
trap 'rm -f "$result_file"' EXIT

PORT=$port STATE=$state RESULT_FILE=$result_file python3 - <<'PY' >/dev/null 2>&1 &
import http.server, os, socketserver, urllib.parse, sys

port = int(os.environ['PORT'])
expected_state = os.environ['STATE']
result_file = os.environ['RESULT_FILE']

OK_HTML = b"""<!doctype html><html><head><meta charset='utf-8'><title>Nexforce Work</title>
<style>body{font-family:system-ui;background:#0f172a;color:#e2e8f0;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh}.box{background:#1e293b;padding:32px 40px;border-radius:12px;border:1px solid #334155;max-width:420px}h1{margin:0 0 8px;font-size:18px}p{margin:0;font-size:14px;color:#94a3b8}</style>
</head><body><div class='box'><h1>Sign-in complete</h1><p>You can close this tab. The Nexforce Work installer is now finishing on your machine.</p></div></body></html>"""

BAD_HTML = b"""<!doctype html><html><head><meta charset='utf-8'><title>Nexforce Work</title></head>
<body style='font-family:system-ui;padding:32px'><h1>Sign-in failed</h1><p>The installer received an unexpected response. Close this tab, re-run the installer, and try again.</p></body></html>"""

class H(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    u = urllib.parse.urlparse(self.path)
    q = urllib.parse.parse_qs(u.query)
    code = (q.get('code') or [''])[0]
    state = (q.get('state') or [''])[0]
    if code and state == expected_state:
      with open(result_file, 'w') as f: f.write(code)
      body = OK_HTML
    else:
      body = BAD_HTML
    self.send_response(200)
    self.send_header('Content-Type', 'text/html; charset=utf-8')
    self.send_header('Content-Length', str(len(body)))
    self.end_headers()
    self.wfile.write(body)
    # Schedule shutdown so the parent unblocks.
    import threading
    threading.Thread(target=self.server.shutdown, daemon=True).start()
  def log_message(self, *a, **kw): pass

with socketserver.TCPServer(('127.0.0.1', port), H) as srv:
  srv.serve_forever()
PY
listener_pid=$!

# ── Step 3: open the browser ────────────────────────────────────────
sign_in_url="${SIGNIN_URL_BASE}?desktopAuth=1&mode=sign-in&installerPort=${port}&installerState=${state}"
echo 'Opening your browser to sign in to Nexforce Work...'
echo ''
echo '  If the browser does not open automatically, paste this URL:'
echo "  $sign_in_url"
echo ''
open "$sign_in_url" >/dev/null 2>&1 || true

# ── Step 4: wait for the listener (5 min timeout) ───────────────────
echo 'Waiting for sign-in (5 minute timeout)...'
deadline=$(( $(date +%s) + 300 ))
while kill -0 $listener_pid 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    kill -9 $listener_pid 2>/dev/null || true
    fail 'Sign-in timed out. Re-run this installer and complete the browser flow within 5 minutes.'
  fi
  sleep 1
done

code=$(cat "$result_file" 2>/dev/null || true)
if [ -z "$code" ]; then
  fail 'Sign-in did not return a grant. Re-run the installer and try again.'
fi
log_event 'install-grant-received' "len=${#code}"

# ── Step 5: exchange grant for a session bearer ────────────────────
echo 'Exchanging sign-in grant for a session token...'
exch_body=$(curl -fsS --max-time 12 -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"grant\":\"$code\"}" "$EXCHANGE_URL") || fail "Sign-in grant exchange failed."
bearer=$(printf '%s' "$exch_body" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get("token") or "")' 2>/dev/null)
if [ -z "$bearer" ]; then fail 'Sign-in succeeded but no session token was returned.'; fi
log_event 'install-bearer-acquired' ''

# ── Step 6: dequeue the install token URL ──────────────────────────
echo 'Asking Nexforce Work for the agents to install...'
dequeue_body=$(curl -fsS --max-time 12 -X POST \
  -H "Authorization: Bearer $bearer" -H 'Content-Type: application/json' \
  -d '{}' "$DEQUEUE_URL") || fail "Could not reach Nexforce Work to fetch the install queue."

script_url=$(printf '%s' "$dequeue_body" | python3 -c "
import json,sys
try:
  d=json.loads(sys.stdin.read()); p=d.get('pending')
  if not p: sys.exit(0)
  print(p.get('scriptUrls',{}).get('bash') or '')
except Exception: pass" 2>/dev/null)
bundle_name=$(printf '%s' "$dequeue_body" | python3 -c "
import json,sys
try:
  d=json.loads(sys.stdin.read()); p=d.get('pending')
  if not p: sys.exit(0)
  print(p.get('bundleName') or '')
except Exception: pass" 2>/dev/null)

if [ -z "$script_url" ]; then
  echo ''
  echo 'No agents to be installed.'
  echo 'Please, open the Re-connect modal on Nexforce Work and run this installer again.'
  echo ''
  log_event 'install-queue-empty' ''
  exit 0
fi
log_event 'install-queue-hit' "bundle=$bundle_name"
echo "Installing: $bundle_name"

# ── Step 7: fetch + run the server-rendered install script ─────────
script_body=$(curl -fsSL --max-time 30 -H 'User-Agent: nexforce-work-installer' "$script_url") || \
  fail "Could not download the install script."
if [ -z "$script_body" ]; then fail 'Server returned an empty install script.'; fi
log_event 'install-script-fetched' "bytes=${#script_body}"

/bin/bash -c "$script_body"

log_event 'install-done' ''
