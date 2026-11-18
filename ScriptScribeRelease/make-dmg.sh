#!/bin/zsh
# Builds, signs, notarizes and staples ScriptScribe-1.0.82.dmg from the app in this folder.
# Run from Terminal (Xcode's agent isn't allowed to write to mounted disk images).
set -euo pipefail
cd "${0:A:h}"
APP="Script Scribe.app"; VOL="Script Scribe 1.0.82"; DMG="ScriptScribe-1.0.82.dmg"
ID="Developer ID Application: Russell Collis (UM5LY5579J)"
rm -rf stage "$DMG"; mkdir stage
ditto "$APP" "stage/$APP"; ln -s /Applications stage/Applications
hdiutil create -volname "$VOL" -srcfolder stage -ov -format UDZO "$DMG"
rm -rf stage
codesign --force --timestamp --sign "$ID" "$DMG"
codesign --verify --verbose=2 "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile notary --wait
xcrun stapler staple "$DMG"
spctl -a -vvv -t open --context context:primary-signature "$DMG"
