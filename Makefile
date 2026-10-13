# SPDX-License-Identifier: Apache-2.0
.PHONY: build test cli app xcode release clean

build:            ## Build the engine, CLI (and app sources on macOS)
	swift build

test:             ## Run unit tests (macOS or Linux)
	swift test

cli:              ## Build the terminal front-end
	swift build -c release --product pairvox-cli
	@echo "Run: .build/release/pairvox-cli --help"

app:              ## Build dist/PairVox.app (macOS, needs XcodeGen)
	scripts/build-app.sh

xcode:            ## Generate and open the Xcode project
	xcodegen generate && open PairVox.xcodeproj

release:          ## Signed + notarized DMG: make release VERSION=0.1.0
	scripts/release.sh $(VERSION)

clean:
	rm -rf .build dist PairVox.xcodeproj
