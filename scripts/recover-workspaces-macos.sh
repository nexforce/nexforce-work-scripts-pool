#!/usr/bin/env bash
# recover-workspaces (macOS) — standalone, signed-release version.
# Extracted from packages/nexforce-studio-dashboard-api/src/routes/recover-workspaces.ts's
# UNIX_SH_BODY (Darwin branch) for distribution as a release asset.

# recover-workspaces (macOS + Linux) — fetched live from
# /v1/recover-workspaces.sh. Edit the source in
# packages/nexforce-studio-dashboard-api/src/routes/recover-workspaces.ts
# and redeploy.
#
# User-visible output is intentionally minimal — only:
#   "Please open OpenWork Desktop application to continue..."
#   "[SUCCESS] Recovery succeeded!"
#   "Automatically closing and re-opening OpenWork Desktop application."
# Everything else (paths, found-count, id rewrites, file contents, errors)
# is POSTed to /v1/recover-workspaces/log for Railway-side auditing.

set -u

run_id="$(date +%Y%m%d%H%M%S)-$(head -c8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c8)"
log_url='https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces/log'

# Print the runId visibly so a user filing a support ticket can quote it.
echo "Run ID: $run_id"
echo ""

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[FAIL] this script is for macOS only - found $(uname -s)" >&2
  exit 2
fi

plat='macOS'
server_path="${XDG_CONFIG_HOME:-$HOME/.config}/openwork/server.json"
user_data="$HOME/Library/Application Support/com.differentai.openwork"
stop_pattern="/MacOS/OpenWork"
settle_seconds=2
start_openwork() {
  open -a OpenWork >/dev/null 2>&1 && return 0
  open -a "OpenWork - Dev" >/dev/null 2>&1 && return 0
  return 1
}

ws_state_path="$user_data/openwork-workspaces.json"
foreign_server_path="$user_data/server.json"

stop_openwork() {
  pkill -TERM -f "$stop_pattern" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    pgrep -f "$stop_pattern" >/dev/null 2>&1 || return 0
    sleep 0.5
  done
  pkill -KILL -f "$stop_pattern" >/dev/null 2>&1 || true
  sleep 1
}

# Mirror install-scripts.ts:993-1003 / the PS variant above: gate on
# whether the OpenWork process is RUNNING, not on whether the on-disk
# files exist (those persist after the user quits, so the prior
# file-existence check never surfaced this prompt for a returning user
# who had just closed the desktop).
if ! pgrep -f "$stop_pattern" >/dev/null 2>&1; then
  echo ""
  echo "Please open OpenWork Desktop application to continue..."
  start_openwork || true
  deadline=$(( $(date +%s) + 120 ))
  while ! pgrep -f "$stop_pattern" >/dev/null 2>&1 && [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 0.5
  done
  if ! pgrep -f "$stop_pattern" >/dev/null 2>&1; then
    echo "[FAIL] OpenWork Desktop didn't start in time. Open it manually, then re-run this script." >&2
    exit 1
  fi
fi

# Process is up; wait briefly for userData files to materialise (first-run
# race). Best-effort: if they never appear, the embedded Python below logs
# what it finds and the run continues.
file_deadline=$(( $(date +%s) + 30 ))
while [ ! -f "$server_path" ] && [ ! -f "$ws_state_path" ] && [ "$(date +%s)" -lt "$file_deadline" ]; do
  sleep 0.5
done

# All sync + telemetry happen inside the embedded Python.
RECOVER_RUN_ID="$run_id" RECOVER_LOG_URL="$log_url" RECOVER_PLATFORM="$plat" \
SERVER_PATH="$server_path" WS_STATE_PATH="$ws_state_path" FOREIGN_SERVER_PATH="$foreign_server_path" \
python3 - <<'PY'
import json, os, sys, hashlib, shutil, re, urllib.request

run_id        = os.environ['RECOVER_RUN_ID']
log_url       = os.environ['RECOVER_LOG_URL']
platform_str  = os.environ['RECOVER_PLATFORM']
server_path   = os.environ['SERVER_PATH']
ws_state_path = os.environ['WS_STATE_PATH']
foreign_path  = os.environ.get('FOREIGN_SERVER_PATH', '')

TOKEN_KEY_RE = re.compile(r'token', re.IGNORECASE)

def redact(v):
    if isinstance(v, dict):
        return {
            k: ('<redacted:' + str(len(val)) + '>' if isinstance(val, str) and val and TOKEN_KEY_RE.search(k) else redact(val))
            for k, val in v.items()
        }
    if isinstance(v, list):
        return [redact(x) for x in v]
    return v

def log(event, note='', files=None):
    payload = {'runId': run_id, 'platform': platform_str, 'event': event}
    if note: payload['note'] = note
    if files: payload['files'] = files
    try:
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(log_url, method='POST', data=data, headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=4).read()
    except Exception:
        pass  # best-effort

def file_redacted(p):
    if not os.path.exists(p): return None
    try:
        with open(p) as f:
            return json.dumps(redact(json.load(f)), indent=2)
    except Exception:
        try:
            with open(p) as f: return f.read()
        except Exception: return None

def read_json_or_none(p):
    if not os.path.exists(p): return None
    try:
        with open(p) as f: return json.load(f)
    except Exception as e:
        log('parse-error', p + ' : ' + repr(e))
        return None

def real_path_of(p):
    try: return os.path.realpath(p)
    except OSError: return p

def compute_id(real):
    return 'ws_' + hashlib.sha256(real.encode('utf-8')).hexdigest()[:12]

log('start', 'runId=' + run_id)
log('paths',
    'canonical=' + server_path + ' exists=' + str(os.path.exists(server_path)) +
    ' ui=' + ws_state_path + ' exists=' + str(os.path.exists(ws_state_path)) +
    ' foreign=' + foreign_path + ' exists=' + str(os.path.exists(foreign_path)))

def strip_bom_if_present(p):
    """Mirror of the PS StripBomIfPresent: PS5.1 versions of this
    script (and any tool that used Set-Content -Encoding UTF8) leave a
    UTF-8 BOM at the front of server.json, which makes Node JSON.parse
    throw 422 invalid_json inside openwork-server. Strip it in-place
    with a .bombak backup so the next desktop boot reads cleanly."""
    if not os.path.exists(p): return False
    try:
        with open(p, 'rb') as f:
            data = f.read()
        if len(data) >= 3 and data[0] == 0xEF and data[1] == 0xBB and data[2] == 0xBF:
            shutil.copy2(p, p + '.bombak')
            with open(p, 'wb') as f:
                f.write(data[3:])
            return True
    except Exception:
        pass
    return False

for bom_path in (server_path, ws_state_path):
    if strip_bom_if_present(bom_path):
        log('bom-stripped', 'removed UTF-8 BOM from ' + bom_path)

server_state_path = os.path.join(os.path.dirname(ws_state_path), 'openwork-server-state.json')
token_store_path  = os.path.join(os.path.dirname(ws_state_path), 'openwork-server-tokens.json')
initial_files = {
    'server.json':                 file_redacted(server_path),
    'openwork-workspaces.json':    file_redacted(ws_state_path),
    'openwork-server-state.json':  file_redacted(server_state_path),
    'openwork-server-tokens.json': file_redacted(token_store_path),
}
if os.path.exists(foreign_path):
    initial_files['foreign-userData-server.json'] = file_redacted(foreign_path)
log('initial-state', '', initial_files)

# ── live openwork-server probe ────────────────────────────────────────────
# Same intent as the PowerShell variant: cross-check what the running
# embedded openwork-server actually serves, vs what server.json says it
# should. workspace_not_found only fires if the LIVE process's in-memory
# config.workspaces is missing the id, regardless of on-disk state.
try:
    state_obj = read_json_or_none(server_state_path)
    token_obj = read_json_or_none(token_store_path)
    probe_port = None
    probe_host_token = None
    if isinstance(state_obj, dict):
        wp = state_obj.get('workspacePorts') if isinstance(state_obj.get('workspacePorts'), dict) else None
        if wp:
            for v in wp.values():
                if v: probe_port = int(v); break
        if not probe_port and state_obj.get('preferredPort'):
            probe_port = int(state_obj['preferredPort'])
    if isinstance(token_obj, dict):
        wmap = token_obj.get('workspaces') if isinstance(token_obj.get('workspaces'), dict) else None
        if wmap:
            for entry in wmap.values():
                if isinstance(entry, dict) and entry.get('hostToken'):
                    probe_host_token = entry['hostToken']; break
    log('live-probe-config', 'port=' + str(probe_port) + ' hasHostToken=' + str(bool(probe_host_token)))
    if probe_port:
        probe_base = 'http://127.0.0.1:' + str(probe_port)
        try:
            req = urllib.request.Request(probe_base + '/health')
            with urllib.request.urlopen(req, timeout=4) as r:
                body = r.read().decode('utf-8', errors='replace')[:180]
                log('live-probe-health', 'status=' + str(r.status) + ' body=' + body)
        except Exception as ex:
            log('live-probe-health-fail', repr(ex))
        if probe_host_token:
            try:
                req = urllib.request.Request(probe_base + '/workspaces', headers={'x-openwork-host-token': probe_host_token})
                with urllib.request.urlopen(req, timeout=6) as r:
                    body = r.read().decode('utf-8', errors='replace')
                    log('live-probe-workspaces', 'status=' + str(r.status) + ' bytes=' + str(len(body)),
                        {'live-probe-workspaces.json': body})
            except Exception as ex:
                log('live-probe-workspaces-fail', repr(ex))
        else:
            log('live-probe-workspaces-skipped', 'no host token in openwork-server-tokens.json')
    else:
        log('live-probe-skipped', 'no port found in openwork-server-state.json')
except Exception as ex:
    log('live-probe-error', repr(ex))

server   = read_json_or_none(server_path)
ws_state = read_json_or_none(ws_state_path)

by_real = {}
def collect(entries, source):
    if not entries: return
    for w in entries:
        if not isinstance(w, dict): continue
        if w.get('workspaceType') == 'remote': continue
        p = (w.get('path') or '').strip()
        if not p: continue
        if not os.path.exists(p):
            log('path-missing', '[' + source + '] ' + str(w.get('id','?')) + ' : ' + p)
            continue
        real = real_path_of(p)
        e = by_real.get(real)
        if e is None:
            e = {'real_path':real,'name':w.get('name') or '','display_name':w.get('displayName') or '','preset':w.get('preset') or '','desktop_id':'','server_id':''}
            by_real[real] = e
        if source == 'desktop': e['desktop_id'] = w.get('id','')
        if source == 'server':  e['server_id']  = w.get('id','')
        for f in ('name','preset'):
            if not e[f] and w.get(f): e[f] = w[f]
        if not e['display_name'] and w.get('displayName'):
            e['display_name'] = w['displayName']

if isinstance(ws_state, dict): collect(ws_state.get('workspaces') or [], 'desktop')
if isinstance(server, dict):   collect(server.get('workspaces')   or [], 'server')

log('found', 'count=' + str(len(by_real)))
if len(by_real) == 0:
    log('noop', 'no LOCAL workspaces in either file')
    log('done', '')
    # Exit 2 = noop (distinct from 0=ok, 1=error) so bash can print the
    # right user-facing summary.
    sys.exit(2)

id_map = {}
for real, e in by_real.items():
    e['correct_id'] = compute_id(real)
    if e['desktop_id'] and e['desktop_id'] != e['correct_id']: id_map[e['desktop_id']] = e['correct_id']
    if e['server_id']  and e['server_id']  != e['correct_id']: id_map[e['server_id']]  = e['correct_id']

# Settle window — let the desktop / its embedded openwork-server finish
# any in-flight writes or port-binding before we start probing + patching.
import time as _time
_time.sleep(5)

print('')
print('Recovering workspaces...')

# ── patch server.json ──────────────────────────────────────────────────────
server_workspaces = (server.get('workspaces') if isinstance(server, dict) else None) or []
server_dirty = False
added = rewritten = unchanged = 0
for real, e in by_real.items():
    existing = None
    for w in server_workspaces:
        if not isinstance(w, dict): continue
        p = (w.get('path') or '').strip()
        if not p: continue
        if real_path_of(p) == real: existing = w; break
    if existing:
        if e['correct_id'] != (existing.get('id') or ''):
            log('server-id-rewrite', 'old=' + str(existing.get('id','')) + ' new=' + e['correct_id'] + ' path=' + real)
            existing['id'] = e['correct_id']; existing['path'] = real
            if not existing.get('workspaceType'): existing['workspaceType'] = 'local'
            server_dirty = True; rewritten += 1
        else:
            unchanged += 1
    else:
        log('server-add', 'id=' + e['correct_id'] + ' path=' + real)
        ne = {'id':e['correct_id'],'path':real,'name':e['name'] or os.path.basename(real) or 'Workspace','preset':e['preset'] or 'starter','workspaceType':'local'}
        if e['display_name']: ne['displayName'] = e['display_name']
        server_workspaces.append(ne)
        server_dirty = True; added += 1

# Restore any REMOTE workspaces present in openwork-workspaces.json but
# missing from server.json. Same rationale as the PS variant: a prior
# version of this script could destructively drop them via POST
# /workspaces/local on a BOM-corrupted server.
remote_restored = 0
if isinstance(ws_state, dict):
    for uw in (ws_state.get('workspaces') or []):
        if not isinstance(uw, dict): continue
        if uw.get('workspaceType') != 'remote': continue
        uw_id = (uw.get('id') or '').strip()
        if not uw_id: continue
        if any((sw.get('id') or '').strip() == uw_id for sw in server_workspaces if isinstance(sw, dict)):
            continue
        log('server-remote-restore', 'id=' + uw_id + ' from openwork-workspaces.json')
        re_entry = {'id': uw_id, 'workspaceType': 'remote'}
        for prop in ('path','name','preset','remoteType','baseUrl','directory','displayName','openworkHostUrl','openworkToken','openworkClientToken','openworkHostToken','openworkWorkspaceId','openworkWorkspaceName','sandboxBackend','sandboxRunId','sandboxContainerName'):
            v = uw.get(prop)
            if v not in (None, ''): re_entry[prop] = v
        server_workspaces.append(re_entry)
        server_dirty = True
        remote_restored += 1
if remote_restored > 0:
    log('server-remote-restore-done', 'restored=' + str(remote_restored))

if server_dirty:
    if not isinstance(server, dict): server = {'workspaces': [], 'authorizedRoots': []}
    server['workspaces'] = server_workspaces
    if 'authorizedRoots' not in server or not isinstance(server.get('authorizedRoots'), list):
        server['authorizedRoots'] = []
    roots = list(server['authorizedRoots'])
    for e in by_real.values():
        if e['real_path'] not in roots: roots.append(e['real_path'])
    # Seed authorizedRoots for restored remote-workspace paths too.
    if isinstance(ws_state, dict):
        for uw in (ws_state.get('workspaces') or []):
            if not isinstance(uw, dict): continue
            if uw.get('workspaceType') != 'remote': continue
            rp = (uw.get('path') or '').strip()
            if rp and rp not in roots: roots.append(rp)
    server['authorizedRoots'] = roots
    try:
        os.makedirs(os.path.dirname(server_path), exist_ok=True)
        if os.path.exists(server_path):
            shutil.copy2(server_path, server_path + '.bak')
        tmp = server_path + '.tmp'
        with open(tmp, 'w') as f: json.dump(server, f, indent=2)
        os.replace(tmp, server_path)
        log('server-written', 'added=' + str(added) + ' idRewritten=' + str(rewritten) + ' unchanged=' + str(unchanged) + ' remoteRestored=' + str(remote_restored))
    except OSError as ex:
        log('server-write-failed', repr(ex))
else:
    log('server-clean', 'unchanged=' + str(unchanged))

# ── patch openwork-workspaces.json ─────────────────────────────────────────
if isinstance(ws_state, dict):
    ui_dirty = False
    ui_ws = ws_state.get('workspaces') or []
    for w in ui_ws:
        if not isinstance(w, dict): continue
        if w.get('workspaceType') == 'remote': continue
        p = (w.get('path') or '').strip()
        if not p: continue
        real = real_path_of(p)
        if real not in by_real: continue
        correct = by_real[real]['correct_id']
        if (w.get('id') or '') != correct:
            log('ui-id-rewrite', 'old=' + str(w.get('id','')) + ' new=' + correct + ' path=' + real)
            w['id'] = correct; w['path'] = real
            ui_dirty = True
    for sel in ('selectedId','watchedId','activeId','selectedWorkspaceId','watchedWorkspaceId'):
        if sel in ws_state and ws_state[sel] and ws_state[sel] in id_map:
            new = id_map[ws_state[sel]]
            log('ui-selection-rewrite', sel + ': old=' + ws_state[sel] + ' new=' + new)
            ws_state[sel] = new
            ui_dirty = True
    if ui_dirty:
        ws_state['workspaces'] = ui_ws
        try:
            os.makedirs(os.path.dirname(ws_state_path), exist_ok=True)
            if os.path.exists(ws_state_path):
                shutil.copy2(ws_state_path, ws_state_path + '.bak')
            tmp = ws_state_path + '.tmp'
            with open(tmp, 'w') as f: json.dump(ws_state, f, indent=2)
            os.replace(tmp, ws_state_path)
            log('ui-written', '')
        except OSError as ex:
            log('ui-write-failed', repr(ex))
    else:
        log('ui-clean', '')

# ── opencode.jsonc cleanup pass ────────────────────────────────────────────
deleted = missing = errors = 0
for real in by_real:
    jsonc = os.path.join(real, 'opencode.jsonc')
    if not os.path.exists(jsonc):
        missing += 1
        continue
    try:
        os.remove(jsonc)
        log('opencode-jsonc-deleted', jsonc)
        deleted += 1
    except OSError as ex:
        log('opencode-jsonc-delete-failed', jsonc + ' : ' + repr(ex))
        errors += 1
log('opencode-jsonc-pass', 'deleted=' + str(deleted) + ' missing=' + str(missing) + ' errors=' + str(errors))

# ── final state ────────────────────────────────────────────────────────────
log('final-state', '', {
    'server.json':              file_redacted(server_path),
    'openwork-workspaces.json': file_redacted(ws_state_path),
})

sys.exit(1 if errors > 0 else 0)
PY
PY_RC=$?

# Exit codes from the embedded Python:
#   0 = recovery completed (zero deletion errors)
#   1 = recovery completed with errors (logged via /v1/recover-workspaces/log)
#   2 = noop (no LOCAL workspaces found in either file)
# Any other code = python crashed.
if [ $PY_RC -eq 2 ]; then
  echo ""
  echo "[SUCCESS] Recovery succeeded!"
  echo "Nothing to do - no LOCAL workspaces registered."
  exit 0
fi
if [ $PY_RC -eq 1 ]; then
  echo ""
  echo "[FAIL] recovery completed with errors (runId=$run_id, see Railway logs)" >&2
  exit 0
fi
if [ $PY_RC -ne 0 ]; then
  echo ""
  echo "[FAIL] recovery script errored (runId=$run_id, exit=$PY_RC)" >&2
  exit 0
fi

echo ""
echo "[SUCCESS] Recovery succeeded!"
echo "Automatically closing and re-opening OpenWork Desktop application."
stop_openwork
sleep "$settle_seconds"
relaunched=0
for _ in 1 2 3; do
  if start_openwork; then relaunched=1; break; fi
  sleep 1
done
if [ "$relaunched" = "0" ]; then
  # Telemetry already logged via python; silent on user side.
  :
fi
exit 0