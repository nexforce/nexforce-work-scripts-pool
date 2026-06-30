# Privacy Policy — Nexforce Work Scripts Pool

Last Modified: 2026-06-30.

This policy applies specifically to the **Nexforce Work Scripts Pool** — the install + recovery scripts published in this repository (and the signed `.exe` derivatives served from its GitHub Releases). It does **not** restate the full Nexforce Global Corp. privacy policy that governs the broader Nexforce products; for that, see <https://nexforce.co> or contact `product@nexforce.co`.

Your data privacy is of utmost importance to us. This policy details: the data we accumulate and the reasons behind it; the manner in which your data is managed; and the privileges you possess regarding your data.

## What we gather and the reasons behind it

Our fundamental rule is to gather only what is necessary. The scripts in this repository run **on your own machine** and operate only on files inside your own user profile (`%APPDATA%` on Windows, `~/.config` and `~/Library/Application Support` on Linux/macOS). They do **not** require an account, do **not** prompt you for credentials, and do **not** install background services or persistent telemetry agents.

Here is everything that crosses the network when you run these scripts:

### Recovery telemetry

The recovery scripts (`recover-workspaces-*.{ps1,sh}` and the derived signed `.exe`) post **operation events** to the Nexforce dashboard at:

```
POST https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces/log
```

Each event is one of: `start`, `paths`, `initial-state`, `bom-stripped`, `live-probe-config`, `live-probe-health`, `live-probe-workspaces`, `live-probe-workspace-id`, `live-probe-port-owner`, `server-add`, `server-id-rewrite`, `server-written`, `ui-id-rewrite`, `ui-selection-rewrite`, `ui-written`, `opencode-jsonc-deleted`, `final-state`, `stale-opencode-base-url-removed`, `relaunch-ok`, `relaunch-failed`, `done`, `fail`, and similar status events.

Each event carries:

- A randomly-generated `runId` (timestamp + 8 hex characters) that correlates events from one execution.
- The OS name (`Windows`, `macOS`, or `Linux`).
- The event name.
- An optional short note (path of an altered file, error message, count of workspaces, etc.).
- For `initial-state` and `final-state`: the contents of the OpenWork desktop config files the script reads or writes. Token values (any JSON property whose key matches `/token/i`) are **redacted client-side before transmission** and replaced with the literal string `<redacted>`. Individual file payloads are capped at 16 KiB on the client side; the server rejects total request bodies over 2 MiB.

Why we collect this: when you (or a teammate) reports a "workspace not found" or "OpenCode unavailable" error to Nexforce support, this telemetry lets us correlate the issue to a specific run, reproduce the exact desktop config state at the moment of the failure, and ship a fix. The scripts are diagnostic tools first and foremost; the telemetry is what makes them useful for support investigations.

You can audit every line of telemetry the scripts emit in the open-source files in this repository (look for `Log` / `log(` calls). Nothing else is sent.

### Network-level metadata

In the course of receiving the telemetry above, the Nexforce dashboard's Railway-hosted server logs standard HTTP request metadata: the originating IP address, the User-Agent header (`PowerShell`/`curl`/`python-urllib`), and timestamps. This is the same incidental metadata any web server records for any inbound HTTP request and is used for abuse prevention and rate limiting only. Per-IP rate limits on the recovery endpoint are 60 requests per minute per instance.

### Things we explicitly do **not** collect

- We do **not** read the contents of source files in your project directories. The recovery scripts only inspect `opencode.jsonc`, `server.json`, and `openwork-workspaces.json` at fixed OS-specific paths — never your own project files.
- We do **not** collect your real name, email, signed-in identity, or any account-level information. The scripts have no concept of an account.
- We do **not** transmit OpenWork access tokens, OAuth tokens, or other credentials. Every JSON property whose key matches `/token/i` is replaced with `<redacted>` before the file content is uploaded.
- We do **not** install browser cookies. The scripts don't run in a browser.
- We do **not** set persistent identifiers on your machine. The `runId` is generated fresh for every run and discarded once the script exits.
- We do **not** sell or share telemetry with any third party.

### Installer scripts

The installer scripts (`install-nexforce-work-*.{ps1,sh}`) fetch the OpenWork desktop binary from the upstream GitHub Releases at <https://github.com/different-ai/openwork/releases/latest>, run it locally, and open your default browser to the Nexforce dashboard onboarding page. They emit **no telemetry of their own**. GitHub may log the download request per their own privacy policy.

## How we use this data

The telemetry posted by the recovery scripts is used exclusively for:

- **Diagnosing the user's reported issue** during a support investigation.
- **Detecting bugs that affect multiple users** (e.g. a particular Defender false-positive, a corrupted config-file shape).
- **Validating that script updates actually fix the symptoms they target**.

We do not use this data for marketing, product analytics that don't relate to the script's diagnostic purpose, advertising, or to profile individual users.

Nexforce Global Corp employees may access the telemetry to deliver diagnostics or assistance to you. When investigating a specific support ticket, we'll only correlate events to your case to the extent necessary, and we'll inform you when we do.

We reserve the right to disclose this data to law enforcement, regulatory bodies, or legal counsel in compliance with any applicable law, regulation, subpoena, court order, legal process, or governmental request. In such circumstances, we will only share data to the extent required and we will notify you unless we are legally prohibited from doing so.

## Data protection

The protection of your data is paramount to us. The recovery endpoint is served over HTTPS (TLS 1.2 minimum). Token values are redacted client-side before transmission as described above. Per-IP rate limits and request-size limits are enforced server-side to bound abuse impact. The endpoint performs no database writes — telemetry events are emitted to the dashboard's process log and rotated per the hosting provider's standard log-retention.

We comply with the GDPR, CCPA, and other relevant data protection regulations. You have rights to access, rectify, and erase your data, as well as restrict or object to processing, and to data portability. You also have the right to lodge a complaint with a supervisory authority.

To exercise your rights, please contact us at `product@nexforce.co`. Because the telemetry the recovery scripts post is identified only by an opaque `runId` (no name, no email, no user account), exercising "access" or "erasure" requires you to supply the specific `runId` value(s) printed by the script, or a correlated time window of the run. If you're unhappy with the way we've handled your data or your privacy rights, you may also lodge a complaint with the data protection authority in your country.

## Data retention and deletion

Recovery telemetry events are retained for as long as the hosting platform's standard application-log rotation keeps them (typically 30 days). After that they are no longer recoverable. There is no persistent database record of an individual run beyond that window.

You can prevent any future telemetry from your machine by **not running the script**, or by inspecting the open-source source and running a fork with the `Log` / `log` calls disabled.

## Children's Privacy

Our services are not directed at persons under 13 years of age. We do not knowingly collect personal information from children under 13. If we become aware that a child under 13 has provided us with personal information, we will take steps to delete such information from our files.

## Changes to this Privacy Policy

We reserve the right to amend this Privacy Policy at any time. The current version is always the file at the top of the `main` branch of this repository, and material changes are recorded in the commit history. By continuing to use the scripts after a change becomes effective, you agree to be bound by the revised Privacy Policy.

## Contact Information

If you have any questions or comments about this Privacy Policy, please contact us at:

**Nexforce Global Corp.**
Attn: Privacy Officer
800 NE 195 STREET APT 619
MIAMI, FL 33179, USA
Email: `product@nexforce.co`
