#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds every file a GitHub release carries, in one folder: the Mac DMG, the iPhone .ipa, the newest Strix report,
# a zip of the security reports, and SHA256SUMS. The ad-hoc build never touches dist/ (where the app you run lives);
# --signed goes through scripts/release.sh, which builds into dist/. Nothing is uploaded; it prints the
# `gh release create` line to run next. It refuses a working tree with uncommitted changes to tracked files, so the
# files match the commit they are tagged with.
#
#   scripts/release-assets.sh 0.1.0-beta.2                 # ad-hoc DMG + unsigned .ipa into .build/release-assets/0.1.0-beta.2
#   scripts/release-assets.sh 0.1.0-beta.2 --out DIR       # somewhere else (created if missing; must be empty)
#   scripts/release-assets.sh 0.1.0-beta.2 --signed        # signed, notarized DMG via scripts/release.sh (needs
#                                                          # SIGN_IDENTITY, DEVELOPMENT_TEAM, NOTARY_PROFILE)
#   scripts/release-assets.sh 0.1.0-beta.2 --dry-run       # list what would be built and from where, build nothing
#   scripts/release-assets.sh 0.1.0-beta.2 --json          # one JSON object on stdout at the end
#   scripts/release-assets.sh 0.1.0-beta.2 --strix-run DIR # this Strix run (default: the newest under docs/security/strix/strix_runs)
#   scripts/release-assets.sh 0.1.0-beta.2 --allow-dirty   # build from a tree with uncommitted changes (testing only)
#
# The apps carry the numeric part of the version (0.1.0 for 0.1.0-beta.2) as CFBundleShortVersionString, which Apple
# requires to be numbers, and the commit count as the build number. The file names carry the full version.
# Exit codes: 0 built (or planned), 1 a step failed, 2 bad usage.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: scripts/release-assets.sh VERSION [--out DIR] [--signed] [--strix-run DIR] [--allow-dirty] [--dry-run] [--json]" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
VERSION="$1"; shift
OUT="" SIGNED=0 DRY=0 JSON=0 DIRTY_OK=0 STRIX_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || usage; OUT="$2"; shift 2 ;;
    --signed) SIGNED=1; shift ;;
    --strix-run) [[ $# -ge 2 ]] || usage; STRIX_ARG="$2"; shift 2 ;;
    --allow-dirty) DIRTY_OK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --json) JSON=1; shift ;;
    *) usage ;;
  esac
done
# The version names files and is passed to build tools, so it must look like one.
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)(-[A-Za-z0-9.]+)?$ ]] || { echo "Not a version number: $VERSION" >&2; exit 2; }
MARKETING="${BASH_REMATCH[1]}"
OUT="${OUT:-.build/release-assets/$VERSION}"

BUILD_NUMBER="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short HEAD)"
# Progress goes to stderr, so --json leaves stdout holding one object.
say() { echo "$@" >&2; }
fail() { echo "release-assets: $*" >&2; exit 1; }

# The newest Strix run and audit run in the repository are the ones the release carries.
# Strix names its runs without a date, so the newest is the most recently written; gate notes and audit runs start
# with their date, so the newest sorts last by name.
STRIX_RUN="${STRIX_ARG:-$(ls -td docs/security/strix/strix_runs/*/ 2>/dev/null | head -1 || true)}"; STRIX_RUN="${STRIX_RUN%/}"
# The gate note is the one that names this Strix run.
STRIX_GATE="$(grep -l -F "$(basename "$STRIX_RUN")" docs/security/strix/*.md 2>/dev/null | head -1 || true)"
AUDIT_RUN="$(ls -d docs/security/*-audit-run-*/ 2>/dev/null | sort | tail -1 || true)"; AUDIT_RUN="${AUDIT_RUN%/}"
[[ -n "$STRIX_RUN" && -f "$STRIX_RUN/penetration_test_report.md" ]] || fail "no Strix report under docs/security/strix/strix_runs/"
[[ -n "$AUDIT_RUN" && -f "$AUDIT_RUN/REPORT.md" ]] || fail "no audit report under docs/security/*-audit-run-*/"

DIRTY="$(git status --porcelain --untracked-files=no)"
if [[ -n "$DIRTY" && $DIRTY_OK -eq 0 && $DRY -eq 0 ]]; then
  fail "uncommitted changes to tracked files; commit them first (or pass --allow-dirty to test):
$DIRTY"
fi

DMG="PairVox-$VERSION.dmg"
IPA="PairVoxPhone-$VERSION-unsigned.ipa"
STRIX_MD="PairVox-$VERSION-strix-report.md"
REPORTS="PairVox-$VERSION-security-reports"
FILES=("$DMG" "$IPA" "$STRIX_MD" "$REPORTS.zip" "SHA256SUMS")

if [[ $DRY -eq 1 ]]; then
  say "release-assets $VERSION (dry run, nothing built)"
  say "  commit $COMMIT, app version $MARKETING ($BUILD_NUMBER), $([[ $SIGNED -eq 1 ]] && echo "signed and notarized DMG" || echo "ad-hoc DMG")"
  say "  Strix run: $STRIX_RUN"
  say "  audit run: $AUDIT_RUN"
  say "  into $OUT: ${FILES[*]}"
  if [[ $JSON -eq 1 ]]; then
    printf '{"ok":true,"dryRun":true,"version":"%s","appVersion":"%s","build":%s,"commit":"%s","out":"%s","strixRun":"%s","auditRun":"%s","files":[%s]}\n' \
      "$VERSION" "$MARKETING" "$BUILD_NUMBER" "$COMMIT" "$OUT" "$STRIX_RUN" "$AUDIT_RUN" "$(printf '"%s",' "${FILES[@]}" | sed 's/,$//')"
  fi
  exit 0
fi

mkdir -p "$OUT"
[[ -z "$(ls -A "$OUT")" ]] || fail "$OUT is not empty; pass another --out or empty it first"
OUT="$(cd "$OUT" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Mac. release.sh checks the bundle (and, signed, notarizes and staples it).
say "Building the Mac app $MARKETING ($BUILD_NUMBER)…"
if [[ $SIGNED -eq 1 ]]; then
  scripts/release.sh "$MARKETING" >&2 || fail "scripts/release.sh failed"
  cp "dist/PairVox-$MARKETING.dmg" "$OUT/$DMG"
else
  scripts/release.sh "$MARKETING" --dry-run >&2 || fail "scripts/release.sh --dry-run found problems"
  cp ".build/release-dry/PairVox-$MARKETING.dmg" "$OUT/$DMG"
fi
hdiutil verify "$OUT/$DMG" >/dev/null 2>&1 || fail "$DMG does not verify"

# 2. iPhone, unsigned: AltStore or Sideloadly sign it with the installer's own Apple ID.
say "Building the iPhone app $MARKETING ($BUILD_NUMBER)…"
command -v xcodegen >/dev/null && (cd ios && xcodegen generate >/dev/null)
xcodebuild archive -project ios/PairVoxPhone.xcodeproj -scheme PairVoxPhone -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$WORK/PairVoxPhone.xcarchive" -derivedDataPath "$WORK/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet >&2 || fail "the iPhone archive failed"
APP="$WORK/PairVoxPhone.xcarchive/Products/Applications/PairVoxPhone.app"
[[ -d "$APP" ]] || fail "the archive holds no PairVoxPhone.app"
mkdir -p "$WORK/ipa/Payload"
cp -R "$APP" "$WORK/ipa/Payload/"
(cd "$WORK/ipa" && zip -qry "$OUT/$IPA" Payload)

# 3. Security reports: the Strix report on its own, and everything in one zip.
cp "$STRIX_RUN/penetration_test_report.md" "$OUT/$STRIX_MD"
mkdir -p "$WORK/$REPORTS/strix" "$WORK/$REPORTS/audit"
for f in penetration_test_report.md findings.sarif coverage.json run.json; do
  [[ -f "$STRIX_RUN/$f" ]] && cp "$STRIX_RUN/$f" "$WORK/$REPORTS/strix/"
done
[[ -n "$STRIX_GATE" ]] && cp "$STRIX_GATE" "$WORK/$REPORTS/strix/README.md"
for f in REPORT.md findings.json coverage-ledger.json NEEDS-VALIDATION.md; do
  [[ -f "$AUDIT_RUN/$f" ]] && cp "$AUDIT_RUN/$f" "$WORK/$REPORTS/audit/"
done
(cd "$WORK" && zip -qry "$OUT/$REPORTS.zip" "$REPORTS")

# 4. Checksums, then check them.
(cd "$OUT" && shasum -a 256 "$DMG" "$IPA" "$STRIX_MD" "$REPORTS.zip" > SHA256SUMS && shasum -a 256 -c SHA256SUMS >/dev/null) \
  || fail "SHA256SUMS does not check"

say ""
say "Release files for $VERSION in $OUT:"
(cd "$OUT" && ls -l "${FILES[@]}" >&2)
say ""
say "Publish (as the account you choose):"
paths=""
for f in "${FILES[@]}"; do paths+=" \"$OUT/$f\""; done
say "  gh release create v$VERSION --verify-tag $([[ "$VERSION" == *-* ]] && echo "--prerelease ")--notes-file docs/release-notes/v$VERSION.md$paths"

if [[ $JSON -eq 1 ]]; then
  entries=""
  for f in "${FILES[@]}"; do
    size=$(stat -f %z "$OUT/$f")
    sha=$(shasum -a 256 "$OUT/$f" | cut -d' ' -f1)
    entries+="{\"name\":\"$f\",\"size\":$size,\"sha256\":\"$sha\"},"
  done
  printf '{"ok":true,"dryRun":false,"version":"%s","appVersion":"%s","build":%s,"commit":"%s","signed":%s,"out":"%s","files":[%s]}\n' \
    "$VERSION" "$MARKETING" "$BUILD_NUMBER" "$COMMIT" "$([[ $SIGNED -eq 1 ]] && echo true || echo false)" "$OUT" "${entries%,}"
fi
