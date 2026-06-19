#!/usr/bin/env bash
# iOS pre-build fixups. Run this BEFORE `flutter build ios` / `flutter run` on
# Apple platforms (it is safe to run repeatedly and is a no-op off macOS).
#
# Why this exists:
#   * WhisperKit (flutter_whisper_kit_apple) pulls its WhisperKit dependency via
#     Swift Package Manager, so SPM must stay enabled for the iOS build.
#   * With SPM enabled, `file_picker` integrates via SPM and transitively pulls
#     DKImagePickerController -> SDWebImage. Meanwhile flutter_image_compress
#     pulls SDWebImage via CocoaPods. Two static SDWebImage copies = 137
#     duplicate-symbol link errors.
#   * GoogleMaps ships as a static framework, so we cannot switch to dynamic
#     frameworks to dodge the clash.
#   Fix: hide file_picker's Package.swift so Flutter integrates it via CocoaPods
#   instead; SDWebImage then resolves to a single shared pod (deduped with
#   flutter_image_compress) and the link succeeds.
set -euo pipefail

# Only relevant on macOS hosts (iOS builds).
[ "$(uname)" = "Darwin" ] || exit 0

PUB_CACHE_DEFAULT="$HOME/.pub-cache"
PUB_CACHE="${PUB_CACHE:-$PUB_CACHE_DEFAULT}"

# Force file_picker to CocoaPods by hiding its Swift package manifest(s).
for f in "$PUB_CACHE"/hosted/pub.dev/file_picker-*/ios/file_picker/Package.swift; do
  if [ -f "$f" ]; then
    mv "$f" "$f.disabled"
    echo "[ios_prebuild] hid $f (force CocoaPods integration)"
  fi
done

echo "[ios_prebuild] done"
