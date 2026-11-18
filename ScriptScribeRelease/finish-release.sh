#!/bin/zsh
# Finishes the Script Scribe 1.0.82 release once Apple's notary service accepts it:
# waits for the pkg and app submissions, staples both, then builds, notarizes and
# staples the DMG (via make-dmg.sh). Run from Terminal: ~/ScriptScribeRelease/finish-release.sh
set -euo pipefail
cd "${0:A:h}"
PKG_ID=a1cd85ee-43c4-4004-bd40-1a6c597259a6
APP_ID=453f28d3-1942-493a-aa1d-815b0f5aa3cf

# Wait for each submission and stop if Apple rejects it.
for ID in $PKG_ID $APP_ID; do
    xcrun notarytool wait "$ID" --keychain-profile notary
    STATUS=$(xcrun notarytool info "$ID" --keychain-profile notary | awk '/status:/{print $2}')
    if [[ "$STATUS" != Accepted ]]; then
        echo "Submission $ID is $STATUS; log follows"
        xcrun notarytool log "$ID" --keychain-profile notary
        exit 1
    fi
done

# Staple and check the pkg and the app.
xcrun stapler staple ScriptScribe-1.0.82.pkg
spctl -a -vvv -t install ScriptScribe-1.0.82.pkg
xcrun stapler staple "Script Scribe.app"
spctl -a -vvv "Script Scribe.app"

# Repackage the zip with the stapled app, then make the DMG from it.
rm -f ScriptScribe-1.0.82-app.zip
ditto -c -k --keepParent "Script Scribe.app" ScriptScribe-1.0.82-app.zip
./make-dmg.sh
echo "Release complete: $(pwd)"
