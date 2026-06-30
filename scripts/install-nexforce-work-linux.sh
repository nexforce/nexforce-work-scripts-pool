#!/usr/bin/env bash
# Nexforce Work — Linux static installer.
#
# Static installer. The user signs in to OpenWork Desktop and clicks
# Re-connect on https://nexforce-studio-dashboard-staging.up.railway.app/
# dashboard/agents-run; that enqueues a single-use install token server-
# side. This installer scans the OpenWork desktop's Chromium LevelDB for
# the bearer the desktop already uses, POSTs the same bearer to the dash-
# board's /v1/installer/dequeue, and runs the server-rendered install
# script that comes back. All the heavy install logic lives server-side
# in renderBashBundleInstall — this script's job is just discovery +
# auth + dequeue + bash.

set -u

NEXFORCE_BASE_URL='https://nexforce-studio-dashboard-staging.up.railway.app'
DEQUEUE_URL="$NEXFORCE_BASE_URL/v1/installer/dequeue"
ME_URL="$NEXFORCE_BASE_URL/v1/me"
LOG_URL="$NEXFORCE_BASE_URL/v1/recover-workspaces/log"

# OpenWork desktop paths on Linux. The bootstrap follows XDG; LevelDB
# is under XDG_CONFIG_HOME (or ~/.config fallback) per Chromium's
# Electron getPath('userData') resolution.
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
BOOTSTRAP_PATH="$XDG_CONFIG_HOME/openwork/desktop-bootstrap.json"
LEVELDB_DIR="$XDG_CONFIG_HOME/com.differentai.openwork/Local Storage/leveldb"

# runId correlates every log POST from this one execution.
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
    payload="{\"runId\":\"$run_id\",\"platform\":\"Linux\",\"event\":\"$event\",\"note\":\"$esc\"}"
  else
    payload="{\"runId\":\"$run_id\",\"platform\":\"Linux\",\"event\":\"$event\"}"
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

# ── Step 1: validate desktop is pointed at Nexforce production ────────
echo 'Checking OpenWork Desktop configuration...'
if [ ! -f "$BOOTSTRAP_PATH" ]; then
  fail "OpenWork Desktop is not installed (no $BOOTSTRAP_PATH). Install OpenWork Desktop and sign in to Nexforce Work first."
fi

bootstrap_base=$(python3 -c "
import json,sys
try:
  with open('$BOOTSTRAP_PATH') as f: d = json.load(f)
  print((d.get('baseUrl') or '').rstrip('/'))
except Exception:
  pass
" 2>/dev/null)
expected_base=${NEXFORCE_BASE_URL%/}
if [ -z "$bootstrap_base" ]; then
  fail 'OpenWork Desktop has no configured dashboard URL. Sign in to Nexforce Work in OpenWork Desktop first.'
fi
if [ "$bootstrap_base" != "$expected_base" ]; then
  fail "OpenWork Desktop is pointed at $bootstrap_base, not Nexforce Work ($NEXFORCE_BASE_URL). Sign out of OpenWork Desktop and sign back in via Nexforce Work."
fi

# ── Step 2: scrape the desktop's session bearer ──────────────────────
echo 'Reading sign-in credential from OpenWork Desktop...'
bearer=$(python3 - <<PY 2>/dev/null
import os, re, sys
d = r"""$LEVELDB_DIR"""
if not os.path.isdir(d): sys.exit(0)
key = 'openwork.den.authToken'
key_utf16 = key.encode('utf-16-le')
hex_re_u8  = re.compile(rb'[0-9a-f]{64}')
hex_re_u16 = re.compile(rb'(?:[0-9a-f]\x00){64}')
for name in sorted(os.listdir(d)):
  if not (name.endswith('.log') or name.endswith('.ldb')): continue
  try:
    with open(os.path.join(d, name), 'rb') as f: data = f.read()
  except Exception:
    continue
  pos = 0
  while True:
    i = data.find(key_utf16, pos)
    if i < 0: break
    window = data[i + len(key_utf16): i + len(key_utf16) + 1024]
    m = hex_re_u16.search(window)
    if m:
      print(m.group(0).decode('utf-16-le'))
      sys.exit(0)
    m = hex_re_u8.search(window)
    if m:
      print(m.group(0).decode('ascii'))
      sys.exit(0)
    pos = i + 1
PY
)
if [ -z "$bearer" ]; then
  fail 'Could not find a Nexforce Work sign-in in OpenWork Desktop. Sign out of OpenWork Desktop and sign back in to Nexforce Work, then re-run this installer.'
fi
log_event 'install-bearer-found' "len=${#bearer}"

# ── Step 3: confirm the bearer still works ──────────────────────────
echo 'Verifying your Nexforce Work session...'
me_status=$(curl -s -o /tmp/nexforce-me-$$.json -w '%{http_code}' --max-time 8 \
  -H "Authorization: Bearer $bearer" "$ME_URL")
if [ "$me_status" != "200" ]; then
  rm -f /tmp/nexforce-me-$$.json
  fail "Your Nexforce Work session has expired (HTTP $me_status). Sign out of OpenWork Desktop and sign back in, then re-run this installer."
fi
rm -f /tmp/nexforce-me-$$.json
log_event 'install-me-ok' ''

# ── Step 4: dequeue the install token URL ───────────────────────────
echo 'Asking Nexforce Work for the agents to install...'
dequeue_body=$(curl -fsS --max-time 12 -X POST \
  -H "Authorization: Bearer $bearer" -H 'Content-Type: application/json' \
  -d '{}' "$DEQUEUE_URL") || fail "Could not reach Nexforce Work to fetch the install queue."

script_url=$(printf '%s' "$dequeue_body" | python3 -c "
import json,sys
try:
  d = json.loads(sys.stdin.read())
  p = d.get('pending')
  if not p: sys.exit(0)
  print(p.get('scriptUrls', {}).get('bash') or '')
except Exception:
  pass
" 2>/dev/null)
bundle_name=$(printf '%s' "$dequeue_body" | python3 -c "
import json,sys
try:
  d = json.loads(sys.stdin.read())
  p = d.get('pending')
  if not p: sys.exit(0)
  print(p.get('bundleName') or '')
except Exception:
  pass
" 2>/dev/null)

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

# ── Step 5: fetch + run the server-rendered install script ──────────
script_body=$(curl -fsSL --max-time 30 -H 'User-Agent: nexforce-work-installer' "$script_url") || \
  fail "Could not download the install script."
if [ -z "$script_body" ]; then fail 'Server returned an empty install script.'; fi
log_event 'install-script-fetched' "bytes=${#script_body}"

/bin/bash -c "$script_body"

log_event 'install-done' ''
