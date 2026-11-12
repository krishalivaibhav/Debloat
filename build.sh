#!/bin/bash
# Builds build/Debloat.app (universal: Apple Silicon + Intel). Needs Xcode Command Line Tools. Runs on macOS 14+.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Debloat.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$arch-apple-macos14.0" \
    -o "build/Debloat-$arch" Sources/*.swift
done
lipo -create build/Debloat-arm64 build/Debloat-x86_64 -output "$APP/Contents/MacOS/Debloat"
rm build/Debloat-arm64 build/Debloat-x86_64

[ -f Resources/AppIcon.icns ] || swift Resources/make-icon.swift Resources/AppIcon.icns
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp Resources/debloat Resources/catalog.tsv "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/debloat"

# Ad-hoc signature so it runs locally; see README for sharing with other Macs
codesign --force --deep -s - "$APP"

( cd build && zip -qry Debloat.zip Debloat.app )
echo "built $PWD/$APP and build/Debloat.zip"
