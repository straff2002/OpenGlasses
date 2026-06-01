#!/bin/sh
set -eu

# Belt-and-suspenders for the mlx-swift-lm Swift macro (MLXHuggingFaceMacros, used
# by LocalLLMService). ci_post_clone.sh already sets these, but re-assert them right
# before each xcodebuild invocation in case the build step doesn't inherit the
# post-clone defaults. Without this, Xcode Cloud's fresh environment fails the
# archive with "Macro … must be enabled before it can be used" (it can't show the
# interactive Trust & Enable prompt). Safe — dependencies are ours and pinned via
# the committed Package.resolved.
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES
