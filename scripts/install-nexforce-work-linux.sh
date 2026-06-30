#!/usr/bin/env bash
# Nexforce Work — Linux desktop installer bootstrap.
# Downloads the latest OpenWork Desktop installer (.AppImage / .deb /
# .tar.gz) from the upstream GitHub Releases and either runs it
# (AppImage) or hands it to the system package manager (deb), then
# opens the Nexforce dashboard onboarding page. Does NOT register any
# workspace or worker — that flow lives in the dashboard UI.
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
    local esc
    esc=$(printf '%s' "$note" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null)
    payload="{\"runId\":\"$run_id\",\"platform\":\"Linux\",\"event\":\"$event\",\"note\":\"$esc\"}"
  else
    payload="{\"runId\":\"$run_id\",\"platform\":\"Linux\",\"event\":\"$event\"}"
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

# Pick an asset in preference order: .AppImage (universal) > .deb (Debian /
# Ubuntu / Mint) > .tar.gz (anything else). Architecture-match where
# possible (x86_64 vs aarch64).
arch=$(uname -m)
case "$arch" in
  x86_64|amd64)   want_arch='x86_64|x64|amd64' ;;
  aarch64|arm64)  want_arch='aarch64|arm64'    ;;
  *)              want_arch=''                  ;;
esac

read -r asset_url asset_name asset_kind <<EOF
$(printf '%s\n' "$release_json" | python3 -c "
import json, re, sys
want = '$want_arch'
data = json.load(sys.stdin)
assets = [a for a in data.get('assets', []) if 'blockmap' not in a.get('name','')]
def score(a):
  n = a.get('name','').lower()
  if n.endswith('.appimage'): kind = 0
  elif n.endswith('.deb'):    kind = 1
  elif n.endswith('.tar.gz'): kind = 2
  else: return None
  arch_ok = 0 if (not want or re.search(want, n, re.I)) else 1
  return (kind, arch_ok, n)
ranked = [a for a in assets if score(a) is not None]
ranked.sort(key=score)
if ranked:
  a = ranked[0]
  n = a['name'].lower()
  kind = 'appimage' if n.endswith('.appimage') else 'deb' if n.endswith('.deb') else 'tarball'
  print(a['browser_download_url'], a['name'], kind)
" 2>/dev/null)
EOF

if [ -z "${asset_url:-}" ]; then
  log_event 'install-fail-no-asset' ''
  echo "[FAIL] no installable asset on the latest release (.AppImage, .deb, .tar.gz) (runId=$run_id)" >&2
  echo 'Please open https://github.com/different-ai/openwork/releases/latest and pick an installer manually.' >&2
  exit 1
fi

dest="${TMPDIR:-/tmp}/$asset_name"

echo "Downloading $asset_name ..."
curl -fL --progress-bar -o "$dest" "$asset_url" || {
  log_event 'install-fail-download' "$asset_url"
  echo "[FAIL] download failed (runId=$run_id)" >&2
  exit 1
}

case "$asset_kind" in
  appimage)
    chmod +x "$dest"
    echo 'Launching the AppImage...'
    ( "$dest" >/dev/null 2>&1 & ) || echo "[WARN] could not launch the AppImage; run it manually: $dest" >&2
    ;;
  deb)
    echo 'Installing the .deb via the system installer...'
    # Prefer the graphical installer if present (KDE / GNOME / Mint); fall
    # back to sudo apt install which prompts for password in the terminal.
    if command -v xdg-open >/dev/null 2>&1 && command -v gnome-software >/dev/null 2>&1; then
      xdg-open "$dest" || true
    elif command -v gdebi >/dev/null 2>&1; then
      sudo gdebi -n "$dest" || true
    elif command -v apt >/dev/null 2>&1; then
      sudo apt install -y "$dest" || true
    elif command -v dpkg >/dev/null 2>&1; then
      sudo dpkg -i "$dest" || true
    else
      echo "[WARN] no .deb installer found; install $dest manually" >&2
    fi
    ;;
  tarball)
    echo "[INFO] downloaded $dest — extract it into a directory of your choice and run the OpenWork binary inside." >&2
    ;;
esac

echo ''
echo 'Opening the Nexforce onboarding page in your default browser...'
( xdg-open "$DASHBOARD_URL" >/dev/null 2>&1 & ) || echo "[WARN] could not auto-open the browser; visit $DASHBOARD_URL manually" >&2

echo ''
echo 'Done. Finish the installer, then complete onboarding in your browser.'

log_event 'install-done' ''
