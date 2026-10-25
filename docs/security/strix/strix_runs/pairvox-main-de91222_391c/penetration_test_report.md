# Security Penetration Test Report

**Generated:** 2026-10-25 16:11:25 UTC

# Executive Summary

A comprehensive white-box security assessment was conducted on the **PairVox** native voice interface codebase (`/workspace/PairVox-main-de91222`). The evaluation covered automated static application security testing (SAST), secret scanning, dependency vulnerability analysis, and in-depth manual security code review across core engine components, permission policies, voice command execution, and remote pairing protocols (`PairVoxLink`).

**Overall Risk Posture:** Very Strong.

**Key Findings Overview**
- **Zero Critical / High / Medium Vulnerabilities Identified:** Static analysis and manual review confirmed that security controls are properly implemented across all security-critical boundaries.
- **Robust Subprocess & Environment Sanitization:** `ClaudeCLISession` and `ChildEnvironment` strictly isolate child processes, sanitizing environment variables (`ANTHROPIC_*`, `CLAUDE_CODE_*`, `NODE_OPTIONS`, etc.) and executing child binaries without shell interpolation.
- **Strict Permission Policy & Symlink Enforcement:** `PermissionPolicy` and `FolderGrants` enforce recursive symlink resolution (up to depth 32) and disallow shell commands containing variables, backticks, pipes, or redirects. High-risk actions and MCP tool requests force explicit screen confirmation and cannot be auto-approved by voice.
- **Cryptographically Secure Remote Pairing (`PairVoxLink`):** Remote transport utilizes custom framing with ChaCha20Poly1305 AEAD, 64-bit sequence counters against replay attacks, mutual HMAC-SHA256 handshake proofs, short-lived 128-bit QR pairing secrets, anti-bruteforce rate limits, and interface binding restricted strictly to Tailscale CGNAT IP ranges or loopback.
- **Clean Supply Chain & Key Hygiene:** Audit of `Package.resolved` revealed zero known CVEs across pinned third-party dependencies (`WhisperKit`, `Kokoro`, `MLX`, `ZIPFoundation`, `Swift Argument Parser`). Secret scanning confirmed no exposed credentials in application source files or release configurations.

# Methodology

The assessment followed the **OWASP Source Code Review Guidelines** and **NIST SP 800-115** security testing methodologies.

**Engagement Type:** White-box source code security assessment.
**Scope:** `PairVox` codebase (`/workspace/PairVox-main-de91222`), including `PairVoxCore`, `PairVoxLink`, `PairVoxCLI`, `PairVoxVoice`, `PairVoxApp`, and the test suite under `Tests/`.

**Testing Activities Performed:**
1. **Automated Static Security Analysis (SAST):** Scanned repository with `semgrep` for injection, insecure crypto, and logic patterns.
2. **Secret & Credential Discovery:** Executed `gitleaks` and `trufflehog` across source files, commit history, and test fixtures.
3. **Software Composition Analysis (SCA):** Scanned `Package.resolved` via `trivy fs` to audit all third-party SwiftPM dependencies for known CVEs.
4. **Structural AST Pattern Analysis:** Mapped routes, handlers, and security boundaries using `ast-grep`.
5. **In-Depth Manual Code Review:**
   - **Permission & Grant Policy:** Reviewed `PermissionPolicy.swift` and `FolderGrants.swift` for path traversal, voice approval bypasses, and wildcard expansion risks.
   - **Voice & Session Logic:** Evaluated `ConversationEngine.swift` timing checks, audio echo cancellation, and prompt injection defenses.
   - **Subprocess Isolation:** Verified `ClaudeCLISession.swift`, `ClaudeAdvisor.swift`, and `ChildEnvironment.swift` for argument injection, environment leakage, and path hijacks.
   - **Remote Transport & IPC:** Inspected `PairVoxLink` (`LinkHost.swift`, `Pairing.swift`, `DeviceKeyStore.swift`, `LinkCommands.swift`, `TailnetAddress.swift`) for authentication bypasses, replay attacks, cryptographic weaknesses, and IPC socket permissions.

# Technical Analysis

**Systemic Architecture & Defense-in-Depth Analysis**

1. **Subprocess Execution & Environment Isolation (`Sources/PairVoxCore/Session/`)**
   - Subprocess invocation in `ClaudeCLISession.swift` utilizes `Foundation.Process` with explicit executable URLs and typed string arrays (`[String]`), completely avoiding shell string interpolation (`/bin/sh -c`).
   - `ChildEnvironment.filter()` strips sensitive environment variables including `ANTHROPIC_*`, `CLAUDE_CODE_*`, `NODE_OPTIONS`, and custom TLS/proxy override settings before spawning child processes.
   - `ClaudeLocator` validates binary file ownership and POSIX permissions to prevent unauthorized executable substitution.

2. **Permission Policy & Folder Scope Enforcement (`Sources/PairVoxCore/Policy/`)**
   - `PermissionPolicy.swift` categorizes tools into distinct risk levels (`low`, `medium`, `high`). Read-only tools (`Read`, `Glob`, `Grep`, `LS`, `WebSearch`) are permitted under read grants, while file writes, bash commands, and MCP tool executions are flagged for user confirmation.
   - `FolderGrants.swift` and `FolderScope.swift` resolve path symlinks recursively (up to 32 levels) via `resolvingSymlinksInPath` to prevent directory traversal escapes.
   - Auto-approval for shell commands strictly disqualifies command strings containing environment variables, backticks, subshells (`$()`), redirection operators, wildcards, or directory navigation (`cd ..`).

3. **Voice Engine & Prompt Timing Protections (`Sources/PairVoxCore/Conversation/`)**
   - `ConversationEngine.swift` enforces strict timestamp checks (`speechStartedAt >= promptHeardAt`) to ensure voice approvals apply only to prompt questions presented after speech recognition started.
   - Echo suppression window (`ownEchoWindow = 0.6s`) prevents the application's text-to-speech output from being picked up by the microphone and inadvertently approving its own permission prompt.
   - Commands originating from paired remote devices explicitly disable persistent policy overrides (`always=false`).

4. **PairVoxLink Remote Transport & Cryptography (`Sources/PairVoxLink/`)**
   - **Transport Framing:** `LinkHost.swift` encrypts all frame payloads using ChaCha20Poly1305 AEAD with 64-bit sequence counters to prevent packet tampering, reordering, or replay attacks.
   - **Device Pairing:** `Pairing.swift` generates 128-bit random QR secrets valid for 120 seconds. Peer verification uses constant-time HMAC-SHA256 comparison (`CryptoKit.HMAC.isValid`). Anti-bruteforce rate limits cap invalid pairing attempts at 3 per peer and 12 total.
   - **Secret Storage:** `DeviceKeyStore.swift` stores device secret keys in the macOS Keychain using `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` without iCloud backup synchronization.
   - **Interface Isolation:** `TailnetAddress.swift` restricts listener bindings to Tailscale CGNAT IP ranges (`100.64.0.0/10` IPv4, `fd7a:115c:a1e0::/48` IPv6) on `utun` interfaces or loopback (`127.0.0.1`), preventing exposure on public or untrusted Wi-Fi interfaces.
   - **IPC Sockets:** `LinkCommands.swift` creates Unix domain sockets in restricted `0700` directories with `0600` socket permissions, verifying `getpeereid()` local UID matches the current process owner.

# Recommendations

**Short-Term Recommendations**
1. **Maintain Strict CI Dependency Auditing:** Continue automated scanning of `Package.resolved` in CI/CD pipelines to catch any newly published vulnerabilities in audio ML libraries (`WhisperKit`, `Kokoro`, `MLX`).
2. **Build-Script Hygiene:** Restrict developer build scripts under `scripts/` from being bundled in release distribution artifacts.

**Medium-Term Recommendations**
3. **Hardened Local Socket Restrictions:** Ensure local Unix domain sockets in `PairVoxLink` maintain strict `0700` directory and `0600` socket permissions across all macOS versions.
4. **Periodic Policy Review:** Review `PermissionPolicy` tool risk classifications as new MCP tools or Claude Code capabilities are introduced to ensure high-risk commands remain gated by manual screen confirmation.

**Retest & Validation Guidance:**
All assessed surfaces met or exceeded security expectations. Re-run automated SAST and dependency audits upon major feature additions or dependency upgrades.

