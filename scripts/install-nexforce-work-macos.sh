#!/usr/bin/env bash
# Nexforce Work — macOS desktop installer bootstrap.
# Downloads the latest OpenWork Desktop .dmg from the upstream GitHub
# Releases, opens it (Finder mounts the volume and shows the drag-to-
# Applications dialog), then opens the Nexforce dashboard onboarding
# page in the default browser. Does NOT register any workspace or
# worker — that flow lives in the dashboard UI.
#
# Source: https://github.com/different-ai/openwork/releases/latest

set -u

LATEST_API='https://api.github.com/repos/different-ai/openwork/releases/latest'
DASHBOARD_URL='https://nexforce-studio-dashboard-production.up.railway.app/dashboard/onboarding'
LOG_URL='https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces/log'

# runId correlates every log POST from this one execution. Printed
# visibly so a user filing a support ticket can quote it.
run_id="$(date +%Y%m%d%H%M%S)-$(head -c8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c8)"
echo "Run ID: $run_id"
echo ""

# Best-effort telemetry. Same shape + endpoint as the recovery scripts:
# {runId, platform, event, note?}. Swallow every error.
log_event() {
  local event=$1
  local note=${2:-}
  local payload
  if [ -n "$note" ]; then
    # Escape backslash, double-quote, and newline for JSON safety.
    local esc
    esc=$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null)
    payload="{\"runId\":\"$run_id\",\"platform\":\"macOS\",\"event\":\"$event\",\"note\":\"$esc\"}"
  else
    payload="{\"runId\":\"$run_id\",\"platform\":\"macOS\",\"event\":\"$event\"}"
  fi
  curl -fsS -X POST -H 'Content-Type: application/json' --max-time 4 -d "$payload" "$LOG_URL" >/dev/null 2>&1 || true
}

log_event 'install-start' "runId=$run_id"

echo 'Looking up the latest OpenWork desktop release...'
release_json=$(curl -fsSL -H 'User-Agent: nexforce-work-installer' "$LATEST_API" 2>/dev/null) || {
  log_event 'install-fail-release-lookup' "$LATEST_API"
  echo "[FAIL] could not reach $LATEST_API (runId=$run_id)" >&2
  echo 'Please download the installer manually from https://github.com/different-ai/openwork/releases/latest' >&2
  exit 1
}

# Prefer the architecture-matching .dmg. Fall back to the first .dmg if no
# arch-specific build is published. Apple Silicon = arm64; Intel = x64.
arch=$(uname -m)
case "$arch" in
  arm64|aarch64) want_arch='arm64' ;;
  x86_64|amd64)  want_arch='x64'   ;;
  *)             want_arch=''      ;;
esac

dmg_url=$(printf '%s\n' "$release_json" | python3 -c "
import json, sys, re
want = '$want_arch'
data = json.load(sys.stdin)
assets = [a for a in data.get('assets', []) if a.get('name','').endswith('.dmg') and 'blockmap' not in a.get('name','')]
if want:
  ranked = sorted(assets, key=lambda a: (want not in a['name'], a['name']))
else:
  ranked = assets
if ranked:
  print(ranked[0]['browser_download_url'])
" 2>/dev/null) || dmg_url=''

if [ -z "$dmg_url" ]; then
  log_event 'install-fail-no-asset' ''
  echo "[FAIL] no .dmg asset on the latest release (runId=$run_id)" >&2
  echo 'Please open https://github.com/different-ai/openwork/releases/latest and pick an installer manually.' >&2
  exit 1
fi

dmg_name=$(basename "$dmg_url")
dmg_path="${TMPDIR:-/tmp}/$dmg_name"

echo "Downloading $dmg_name ..."
curl -fL --progress-bar -o "$dmg_path" "$dmg_url" || {
  log_event 'install-fail-download' "$dmg_url"
  echo "[FAIL] download failed (runId=$run_id)" >&2
  exit 1
}

echo 'Opening the installer (Finder will mount the disk image)...'
open "$dmg_path" || echo "[WARN] could not auto-open the .dmg; double-click $dmg_path manually" >&2

echo ''
echo 'Opening the Nexforce onboarding page in your default browser...'
open "$DASHBOARD_URL" || echo "[WARN] could not auto-open the browser; visit $DASHBOARD_URL manually" >&2

echo ''
echo 'Done. Drag OpenWork.app into /Applications, then complete onboarding in your browser.'

log_event 'install-done' ''
