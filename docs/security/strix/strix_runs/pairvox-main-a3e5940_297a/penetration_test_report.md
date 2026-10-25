# Security Penetration Test Report

**Generated:** 2026-10-25 21:34:22 UTC

# Executive Summary

A comprehensive security assessment was conducted on the **PairVox** native macOS voice companion codebase for Claude Code. The assessment evaluated the application's attack surface, including process sandboxing, permission policies, network pairing protocols, credential storage, log sanitization, and third-party dependencies.

**Overall Risk Posture:** Robust.

**Key Findings:**
- **No security vulnerabilities identified.**
- Strong security controls were confirmed in the permission policy engine (`FolderScope` symlink and scope validation, execution token sanitization), process execution environment (`ChildEnvironment` variable filtering), remote companion protocol (`ChaCha20-Poly1305` authenticated encryption, `HKDF-SHA256` key derivation, `HMAC-SHA256` handshake verification, `getpeereid` process ownership checks), and diagnostic log redaction (`LogRedactor` regex scrubbers).

**Business Impact:**
The tested codebase demonstrates strong defense-in-depth engineering practices. No unauthorized command execution, path traversal, remote pairing bypass, or credential disclosure risks were identified.

# Methodology

The security assessment was performed using white-box source code analysis and static analysis methodologies.

**Assessment Scope:**
- `PairVoxCore`: Permission policy engine (`PermissionPolicy`, `FolderGrants`), subprocess execution (`ClaudeCLISession`, `ChildEnvironment`), advisor logic (`ClaudeAdvisor`, `RequestAdvisor`).
- `PairVoxLink` & `PairVoxLinkKit`: Remote companion networking (`LinkHost`, `TCPTransport`), wire protocol (`HandshakeWire`, `PairingWire`), cryptography (`LinkCrypto`), device key management (`DeviceKeyStore`).
- `PairVoxApp` & `PairVoxVoice`: Keychain credential storage (`KeychainStore`), log sanitization (`LogRedactor`), diagnostic exports (`DiagnosticLog`, `DiagnosticsExporter`).
- Dependencies: Third-party Swift Package Manager dependencies (`Package.swift`, `Package.resolved`).

**Activities:**
1. Automated static analysis using Semgrep, ast-grep, Gitleaks, Trufflehog, and Trivy FS.
2. Code review of permission enforcement and path traversal protections in `FolderScope`.
3. Cryptographic and protocol review of PairVoxLink handshake and transport encryption.
4. Audit of sensitive data redaction patterns in logging and diagnostics components.
5. Supply chain vulnerability assessment of all pinned third-party packages.

# Technical Analysis

**Security Analysis & Evaluated Surfaces:**

1. **Authorization & Folder Grants (`PairVoxCore/Policy`)**
   - `FolderScope.resolved(_:relativeTo:)` normalizes tilde expansion, standardizes paths, and handles dangling or nested symlink resolution up to a maximum recursion depth of 32 links.
   - Target paths are strictly verified against granted folder scopes using prefix matching on canonicalized paths.
   - `PermissionPolicy.shellGrant` enforces strict guards against command execution bypasses by disallowing shell special characters (`$`, `` ` ``, redirects, nested shell invocations, and inline code flags).

2. **Process Execution & Environment Security (`PairVoxCore/Session`)**
   - `ClaudeCLISession` launches `claude` CLI sub-processes using standard piping.
   - `ChildEnvironment.filter(_:)` explicitly strips sensitive or protocol-altering environment variables (`ANTHROPIC_*`, `CLAUDE_CODE_*`, `CLAUDE_CONFIG_DIR`, `NODE_OPTIONS`, `SSL_CERT_*`) before process launch, mitigating environment manipulation risks.

3. **Remote Link Protocol Security (`PairVoxLink` & `PairVoxLinkKit`)**
   - Remote companion communication employs `ChaCha20-Poly1305` authenticated frame encryption with 64-bit sequence counters (`FrameCodec`) and `HKDF-SHA256` key derivation (`LinkKeys`).
   - Pairing authentication uses `HMAC-SHA256` handshake proofs with constant-time comparison (`Handshake.constantTimeEqual`) to prevent timing side-channel attacks.
   - `LinkCommandServer` UNIX domain control sockets verify process ownership via `getpeereid` to ensure peer process UID matches the server UID.

4. **Secrets Management & Log Sanitization (`PairVoxApp` & `PairVoxVoice`)**
   - API keys and device keys are stored in the macOS system Keychain (`app.pairvox.PairVox`) with strict accessibility attributes (`kSecAttrAccessibleWhenUnlocked` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
   - `LogRedactor` applies regular expression scrubbers to strip API keys (`sk-ant-`, `sk-`), GitHub tokens, AWS credentials, Bearer tokens, passwords, user email addresses, and home directory paths.
   - `DiagnosticLog` excludes conversation transcript content by default unless explicitly enabled by the user.

5. **Supply Chain Assessment (`Package.swift` & `Package.resolved`)**
   - Evaluated 8 direct and transitive package dependencies (including `WhisperKit`, `kokoro-ios`, `mlx-swift`, and `ZIPFoundation`).
   - Confirmed that `ZIPFoundation` is pinned to version `0.9.20` (resolving historical CVE-2023-39138) and no pinned package versions carry active published CVEs.

# Recommendations

**Short-Term Recommendations:**
1. **Continuous Dependency Auditing:** Establish automated CI scanning for Swift Package Manager dependencies using tools such as `trivy` or `swift-outdated` to detect future advisories promptly.
2. **Log Redactor Test Expansion:** Maintain comprehensive unit tests covering edge cases in regular expression pattern matching within `LogRedactor` as new third-party service tokens are integrated.

**Long-Term Recommendations:**
1. **Network Transport Monitoring:** Periodically review cryptographic primitives and key derivation implementations in `PairVoxLink` as new Swift Crypto or system APIs evolve.
2. **Retest & Validation:** Perform periodic static and dynamic security reviews upon major architectural updates or additions to the permission policy engine.

