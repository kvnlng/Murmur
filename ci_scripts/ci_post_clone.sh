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
# This used to pass --build-from-source. On 2026-06-30 Homebrew published
# no Tahoe / macOS-26 bottle for SwiftLint 0.65.0, so brew fell back to the
# sonoma bottle, whose `sourcekitdInProc` linkage is incompatible with the
# runner's Xcode toolchain — SwiftLint segfaulted on startup during the Run
# Script phase. Compiling from source used the runner's own toolchain, so
# the ABI always matched. It also cost ~3-5 minutes per workflow run, and
# ci_post_clone runs for BOTH the Test and Archive workflows.
#
# Reverted 2026-08-15: SwiftLint 0.65.0 now ships an `arm64_tahoe` bottle,
# so the fallback that caused the segfault cannot be selected any more —
# brew pours a bottle built for this OS. Verified before changing: the
# bottle is what a macOS 26.6.1 box runs today (`poured_from_bottle: true`
# on 0.65.0), and it lints this repo without incident.
#
# If SwiftLint ever segfaults on startup in CI again, check
# `brew info --json=v2 swiftlint` for an arm64_tahoe (or later) bottle
# first — its absence is the signal to put --build-from-source back.
#

set -euo pipefail

echo "ci_post_clone: installing SwiftLint"
brew install swiftlint
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
