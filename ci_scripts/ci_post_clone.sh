#!/bin/sh
#
# ci_post_clone.sh — Xcode Cloud hook, runs after the repo is cloned.
#
# Installs SwiftLint via Homebrew so the "Run SwiftLint" build phase in
# the Murmur target can invoke it. Murmur used to pull SwiftLint via the
# SPM build-tool plugin, which forced Xcode Cloud trust workarounds and
# blocked other SPM deps (swift-snapshot-testing couldn't co-resolve with
# SwiftLint's swift-syntax pin). Moving lint to brew + Run Script kept
# the lint gate but freed the package graph.
#
# Homebrew is pre-installed on Xcode Cloud runners.
#
# We compile from source (--build-from-source) rather than pulling the
# prebuilt bottle. When Homebrew doesn't publish a bottle for the
# runner's macOS version (e.g. 2026-06-30: no Tahoe / macOS-26 bottle
# for SwiftLint 0.65.0 so brew falls back to the sonoma bottle), the
# fetched binary's `sourcekitdInProc` linkage is incompatible with the
# runner's Xcode toolchain and SwiftLint segfaults on startup during
# the Run Script phase. Building from source uses the runner's own
# toolchain so the ABI always matches. Costs ~3-5 minutes of extra
# compile time per CI run; solves the root cause.
#

set -euo pipefail

echo "ci_post_clone: installing SwiftLint (build-from-source; see comment above)"
brew install --build-from-source swiftlint
swiftlint --version

# Pre-approve SPM macro / build-tool plugins. The Test action pulls in
# swift-snapshot-testing, swift-custom-dump, and xctest-dynamic-overlay,
# all of which ship macros backed by swift-syntax. On a fresh Xcode Cloud
# clone Xcode would normally show a "Trust & Enable" dialog for each
# plugin the first time it sees them — with no human at the console the
# build either fails or silently skips macro expansion, which then makes
# the test bundles unloadable (exit 70 from `xcodebuild
# test-without-building`).
#
# Setting these defaults tells Xcode to skip the trust prompt for ALL
# plugins on this machine. CI-only — never written to a developer's box.
echo "ci_post_clone: pre-approving SPM package plugins"
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "ci_post_clone: done"
