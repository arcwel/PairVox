# SPDX-License-Identifier: Apache-2.0
.PHONY: build test cli app xcode release qa-smoke clean

# On macOS the default SwiftPM build system rejects the Kokoro/Misaki dynamic products that both
# embed MLX (Xcode handles it). Use the native build system there. See docs/HANDOFF.md §4.
SWIFTPM_FLAGS := $(shell [ "$$(uname)" = "Darwin" ] && echo "--build-system native")

build:            ## Build the engine, CLI (and app sources on macOS)
	swift build $(SWIFTPM_FLAGS)

test:             ## Run unit tests (macOS or Linux)
	swift test $(SWIFTPM_FLAGS)

cli:              ## Build the terminal front-end
	swift build $(SWIFTPM_FLAGS) -c release --product pairvox-cli
	@echo "Run: .build/release/pairvox-cli --help"

app:              ## Build dist/PairVox.app (macOS, needs XcodeGen)
	scripts/build-app.sh

xcode:            ## Generate and open the Xcode project
	xcodegen generate && open PairVox.xcodeproj

qa-smoke:         ## Non-audio QA via pairvox-cli (4 real Haiku turns): make qa-smoke ARGS=--dry-run
	scripts/qa-smoke.sh $(ARGS)

release:          ## Signed + notarized DMG: make release VERSION=0.1.0
	scripts/release.sh $(VERSION)

clean:
	rm -rf .build dist PairVox.xcodeproj
