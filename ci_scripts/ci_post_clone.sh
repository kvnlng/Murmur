#!/bin/sh
#
# ci_post_clone.sh — Xcode Cloud hook, runs after the repo is cloned.
#
# Pre-trusts the SwiftLint SPM build-tool plugin. Xcode Cloud refuses to
# execute build-tool plugins without an explicit trust grant; on a
# developer machine you approve them once via Xcode's UI, but Xcode Cloud
# has no UI to click. The defaults key below skips fingerprint validation
# so plugin trust is implicit for the duration of the build.
#
# Note: the key name "IDESkipPackagePluginFingerprintValidatation" includes
# Apple's typo ("Validatation" with two -atation-s). That's the actual key —
# don't "fix" it.
#
# References:
#   https://developer.apple.com/documentation/xcode/writing-custom-build-scripts
#

set -euo pipefail

echo "ci_post_clone: pre-trusting SwiftLint build-tool plugin for Xcode Cloud"

defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES

echo "ci_post_clone: done"
