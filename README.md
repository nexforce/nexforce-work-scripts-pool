# nexforce-work-scripts-pool

Standalone, OS-specific scripts for installing and recovering the **Nexforce Work / OpenWork** desktop application on a user's machine. This repo is the **source of truth** for the scripts; the Windows `.ps1` is also compiled to a signed `.exe` and published on each tagged release for Defender/SmartScreen-friendly double-click execution.

## Scripts

All scripts are designed to be run from a user's terminal — or, in the case of the Windows `.exe`, double-clicked from Explorer.

### Install (downloads the OpenWork desktop app and opens the dashboard onboarding URL)

| File | OS |
|---|---|
| `scripts/install-nexforce-work-windows.ps1` | Windows |
| `scripts/install-nexforce-work-macos.sh` | macOS |
| `scripts/install-nexforce-work-linux.sh` | Linux |

These do **not** install a worker / workspace — that flow lives on the dashboard at `/dashboard/onboarding`. These scripts just get the desktop binary on the machine and open the onboarding page so the user can complete the workspace bootstrap from the UI.

### Recover (heals local OpenWork desktop config when the UI surfaces "workspace_not_found" or "OpenCode is unavailable")

| File | OS |
|---|---|
| `scripts/recover-workspaces-windows.ps1` | Windows |
| `scripts/recover-workspaces-macos.sh` | macOS |
| `scripts/recover-workspaces-linux.sh` | Linux |

The Windows recovery flow is **only** safe to ship as a signed `.exe` (Defender flags inline-fetched PowerShell as `Trojan:PowerShell/Downloader.*`). The GitHub Actions release workflow compiles `recover-workspaces-windows.ps1` to `recover-workspaces-windows.exe` via [`ps2exe`](https://github.com/MScholtes/PS2EXE) and signs it through [SignPath.io](https://signpath.io)'s free OSS tier.

macOS / Linux recovery scripts are shipped unsigned (Apple notarization is a separate problem; Linux has no AV equivalent).

## Authenticity

- Every tagged release publishes a `SHA256SUMS.txt` alongside the artifacts.
- The signed Windows `.exe` is signed by the **SignPath Foundation** certificate (CN includes `SignPath Foundation`). Verify with:
  ```powershell
  Get-AuthenticodeSignature .\recover-workspaces-windows.exe | Format-List
  ```
- The `.ps1` source is also published unsigned alongside the `.exe` for users who prefer to inspect + run the source directly.

## Reporting AV false positives

If Windows Defender flags the signed `.exe` (it shouldn't, post-signing), please submit a false-positive report at <https://www.microsoft.com/wdsi/filesubmission> with the hash from `SHA256SUMS.txt`.

## Privacy

The recovery scripts post diagnostic telemetry events (with workspace-config files attached, **token values redacted client-side**) to `https://nexforce-studio-dashboard-production.up.railway.app/v1/recover-workspaces/log` to support investigations into reported user issues. No account, no credentials, no persistent identifiers are involved — every run is keyed by an opaque per-execution `runId`. The installer scripts emit no telemetry of their own.

See [PRIVACY.md](./PRIVACY.md) for the full disclosure, including every event the recovery scripts emit, what's collected, what's explicitly **not** collected, retention, and how to exercise GDPR/CCPA rights.

## License

[MIT](./LICENSE). The MIT license is one of the OSS licenses [SignPath's free tier](https://signpath.org/) accepts for project verification.
