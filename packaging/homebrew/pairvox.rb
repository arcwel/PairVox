# Homebrew cask template. Publish it in your own tap, e.g. github.com/OWNER/homebrew-tap:
#   brew install --cask OWNER/tap/pairvox
# Fill in OWNER, version and sha256 from scripts/release.sh output.
cask "pairvox" do
  version "0.1.0"
  sha256 "REPLACE_WITH_DMG_SHA256"

  url "https://github.com/OWNER/pairvox/releases/download/v#{version}/PairVox-#{version}.dmg"
  name "PairVox"
  desc "Voice front-end for Claude Code: talk, interrupt and brainstorm hands-free"
  homepage "https://github.com/OWNER/pairvox"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "PairVox.app"

  zap trash: [
    "~/Library/Application Support/PairVox",
    "~/Library/Preferences/app.pairvox.PairVox.plist",
  ]

  caveats <<~EOS
    PairVox drives the Claude Code CLI installed on your Mac. Install it and sign in once:
      npm install -g @anthropic-ai/claude-code   (or Anthropic's native installer)
      claude      # then /login
  EOS
end
