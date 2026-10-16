# Releasing PairVox

What exists, what each step needs, and what is still missing. Nothing here runs on its own: the owner tags, the owner holds the certificate and the notary account.

## What is in place

| Piece | Where | State |
|---|---|---|
| App build (Xcode, Metal shaders, embedded frameworks) | `scripts/build-app.sh` | Works. `DIST_DIR` moves the output away from `dist/`. |
| Release build, DMG, signing, notarization, stapling | `scripts/release.sh VERSION` | Written; never run with a real certificate. |
| Release dry run | `scripts/release.sh VERSION --dry-run` | Builds ad-hoc into `.build/release-dry/`, makes the DMG, checks signatures, Info.plist, entitlements (`get-task-allow` is tolerated only on an ad-hoc signature) and unsigned Mach-O files, and lists what a real release still needs. Does not touch `dist/`. Passed 2026-10-15: 24 MB DMG, eight frameworks, two todos (certificate, notary profile). |
| GitHub release workflow | `.github/workflows/release.yml` | Runs on a `v*` tag from `main`. Needs the repository secrets listed at the top of that file and a `release` environment with a required reviewer. |
| Homebrew cask | `packaging/homebrew/pairvox.rb` | Template; version and sha256 are filled in after the first DMG. |
| In-app updates (Sparkle 2.7.1) | `project.yml`, `Sources/PairVoxApp/Support/Updater.swift`, `Sources/PairVoxApp/Info.plist`, `scripts/make-appcast.sh` | Scaffolded and off. The code is behind `#if canImport(Sparkle)`; the updater starts only when `SUFeedURL` and `SUPublicEDKey` are both set, and "Check for Updates…" is disabled otherwise. **The package is not in `project.yml` yet**: on 2026-10-15 `xcodebuild` hung in "Resolve Package Graph" for over ten minutes on Sparkle's binary artifact (the download URL answered with 200, the artifact folder stayed empty, no child process, no socket). Uncomment the two blocks in `project.yml` and run `xcodegen generate` to try again; if it hangs, resolve once from Xcode's GUI (File → Packages → Resolve), which uses a different code path, or vendor the XCFramework. |

## Blocked on the owner

1. **Apple Developer Program membership** (paid). Without it there is no Developer ID certificate, no notarization, and the DMG opens only with a right-click workaround that macOS 15 no longer offers. Decision pending (see the memory note on no paid team until the owner says so).
2. **Developer ID Application certificate** in the Keychain of the Mac that builds, and as a `.p12` in the `release` environment secrets for the workflow.
3. **Notary credentials**: `xcrun notarytool store-credentials pairvox-notary --apple-id … --team-id …` locally; the same three values as workflow secrets.
4. **Sparkle keys**: run `generate_keys` once (from the Sparkle package the Xcode build resolves, under `.build/xcode/SourcePackages/artifacts/`). It stores the private key in the Keychain and prints the public key. Put the public key in `Info.plist` as `SUPublicEDKey`, and the https address of `appcast.xml` as `SUFeedURL`. Back the private key up with `generate_keys -x FILE` and keep that file out of the repository.
5. Name, trademark and domain checks for "PairVox".

## Release checklist

1. `CHANGELOG.md`: move "Unreleased" under the version heading.
2. `scripts/release.sh X.Y.Z --dry-run` passes.
3. `swift test --build-system native` passes; `scripts/soak.sh 120` passes; `docs/security/` has a report for this milestone (full `security-audit` mode).
4. The real mic test (`docs/MIC_TEST.md`) has been done on this build.
5. Tag `vX.Y.Z` on `main` and push the tag. The workflow builds, signs, notarizes and publishes the DMG. Or run `scripts/release.sh X.Y.Z` locally with `SIGN_IDENTITY`, `DEVELOPMENT_TEAM` and `NOTARY_PROFILE` set.
6. `DOWNLOAD_URL_PREFIX=https://github.com/arcwel/PairVox/releases/download/vX.Y.Z/ scripts/make-appcast.sh` and upload `appcast.xml` to the address in `SUFeedURL`.
7. Fill in `packaging/homebrew/pairvox.rb` with the version and sha256 the release script printed.
8. Install the DMG on a clean user account and check: first launch without a Gatekeeper warning, microphone prompt, model download, a spoken reply, "Check for Updates…" enabled.

## Not done yet

- The dry run checks the bundle, not the notary service's own rules; the first real submission may still come back with findings.
- The phone app has no release path at all (no App Store or TestFlight setup); it is built ad-hoc for the simulator and a registered device.
