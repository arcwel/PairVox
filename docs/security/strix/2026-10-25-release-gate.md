# Strix pre-release gate (2026-10-25)

Strix 1.7.0 ran on `gemini/gemini-3.5-flash` inside its Docker sandbox (OrbStack). Gemini is from a different family than the model that wrote the code. The target was a copy of `main` at `de91222`. That is the code audit run 8 reviewed, so the run 8 fixes are not in it.

## Result

**Passed: no finding at any severity.** Run `pairvox-main-de91222_391c`, standard mode, no brief, $2.08. Strix reports the scan as complete (`finished_by_tool`). It ran Semgrep, Gitleaks and TruffleHog (source and history), Trivy on `Package.resolved`, and ast-grep. It recorded 18 surfaces, every one "no issue identified":

| Area | Surfaces |
|---|---|
| Dependencies | `Package.resolved` |
| Child process | `ClaudeCLISession.swift`, `Session/` (spawning, the environment filter, the executable path) |
| Approval gate | `PermissionPolicy.swift` (twice), `FolderGrants.swift`, `ConversationEngine.swift` (spoken answers, echo check, prompt timing), `EngineLink.swift` |
| Advisor | `Advisor/` (sandboxing and the prompt-injection fence) |
| Phone link | `LinkHost.swift`, `Pairing.swift`, `DeviceKeyStore.swift`, `LinkCommands.swift` (control socket), `TailnetAddress.swift` |
| Credentials | `KeychainStore.swift` |
| Settings | `Config/` |
| Tests | `Tests/`, `Tests/PairVoxLinkTests` |

The report, SARIF and coverage record are in `strix_runs/pairvox-main-de91222_391c/`. The console output is in `2026-10-25-release-gate.log`.

## Gaps Strix reports in its own record

- Six of its agents finished without recording coverage, so whatever they looked at is not in the record.
- No entry records argument injection or business logic as assessed, although agents were assigned both. Strix says to treat these as unexamined, not clean.
  - Audit run 8 covered both classes by hand, for the approval gate, the installer and the phone answers (`docs/security/2026-10-25-audit-run-8/REPORT.md`).
- As on 2026-10-24, there was no live attack on the phone link. The macOS app cannot run in Strix's Linux sandbox, and Gemini refuses a network target. Backlog 3.10 is still open.
