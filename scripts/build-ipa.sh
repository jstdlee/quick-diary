#!/usr/bin/env bash
# Unsigned Release build for a real iPhone, packed as an .ipa.
# Sideload tools (SideStore, AltStore, Sideloadly) sign it with your free Apple ID.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d QuickDiary.xcodeproj ] || xcodegen generate

xcodebuild build \
  -project QuickDiary.xcodeproj \
  -scheme QuickDiary \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/device \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" -quiet  # no iCloud entitlement: free Apple IDs cannot sign it

rm -rf build/Payload build/QuickDiary-unsigned.ipa
mkdir -p build/Payload
cp -R build/device/Build/Products/Release-iphoneos/QuickDiary.app build/Payload/
(cd build && zip -qry QuickDiary-unsigned.ipa Payload)
ls -lh build/QuickDiary-unsigned.ipa
