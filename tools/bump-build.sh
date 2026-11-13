#!/bin/zsh
#
# Counts iterations of the project: every successful build and every commit moves Info Headers on
# to the next build number, and the version's third part repeats it, e.g. 1.0.7 (build 7).
#
# Records the version that was just built in README.md, then moves the project on to the next
# iteration. Runs as the scheme's Build post-action (after the build finishes, so a build is never
# interrupted by the project file changing) and from the git pre-commit hook. Xcode builds are
# counted at most once a minute, so background preview builds don't keep bumping the number.
# Set SKIP_BUILD_BUMP=1 to leave the build number alone.
#
set -euo pipefail

[[ "${SKIP_BUILD_BUMP:-}" == 1 ]] && exit 0

ROOT="${PROJECT_DIR:-${0:A:h:h}}"
PROJECT_FILE="$ROOT/Script Headers.xcodeproj/project.xcproj"
README="$ROOT/README.md"

CURRENT=$(grep -m1 -oE '"CURRENT_PROJECT_VERSION": "[0-9]+"' "$PROJECT_FILE" | grep -oE '[0-9]+')
VERSION=$(grep -m1 -oE '"MARKETING_VERSION": "[^"]+"' "$PROJECT_FILE" | cut -d'"' -f4)

# Xcode runs Build post-actions even when the build fails. Only count the build if the product
# that was just made carries the current build number.
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
    PLIST="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME/Contents/Info.plist"
    BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "")
    if [[ "$BUILT" != "$CURRENT" ]]; then
        echo "Build $CURRENT didn't produce an app; build number left alone"
        exit 0
    fi
    # Previews and code snippets build in the background, and each bump makes Xcode build again.
    # Count at most one Xcode build a minute so those background builds don't run away.
    STAMP="$TARGET_BUILD_DIR/.info-headers-last-bump"
    if [[ -f "$STAMP" ]] && (( $(date +%s) - $(stat -f %m "$STAMP") < 60 )); then
        echo "Build $CURRENT was counted less than a minute ago; build number left alone"
        exit 0
    fi
    touch "$STAMP"
fi

NEXT=$((CURRENT + 1))
# The release part (e.g. 1.0) stays as set by hand; only the iteration changes.
RELEASE=$(echo "$VERSION" | cut -d. -f1-2)
NEXT_VERSION="$RELEASE.$NEXT"

# README shows the version that was just built.
[[ -f "$README" ]] && sed -i '' -E "s/The current version is \*\*[^*]+\*\*/The current version is **$VERSION (build $CURRENT)**/" "$README"
sed -i '' -E "s/\"CURRENT_PROJECT_VERSION\": \"[0-9]+\"/\"CURRENT_PROJECT_VERSION\": \"$NEXT\"/g" "$PROJECT_FILE"
sed -i '' -E "s/\"MARKETING_VERSION\": \"[^\"]+\"/\"MARKETING_VERSION\": \"$NEXT_VERSION\"/g" "$PROJECT_FILE"

echo "Built $VERSION ($CURRENT); next is $NEXT_VERSION ($NEXT)"
