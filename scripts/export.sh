#!/bin/zsh
# Builds a universal (Apple Silicon + Intel) Release Tween.app and zips it for sharing.
# Signed ad hoc unless you set a team in Xcode; see README for Developer ID notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

# Archive in a temp folder so the only Tween.app left behind is export/Tween.app.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="$WORK/Tween.xcarchive"
xcodebuild -project Tween.xcodeproj -scheme Tween -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" -derivedDataPath "$WORK/dd" archive -quiet

mkdir -p export
rm -rf export/Tween.app export/Tween.zip
ditto "$ARCHIVE/Products/Applications/Tween.app" export/Tween.app
# The shareable zip: a "Tween" folder with the app and the friend-facing guide.
mkdir -p "$WORK/Tween"
ditto export/Tween.app "$WORK/Tween/Tween.app"
cp "packaging/How to open Tween.txt" "$WORK/Tween/"
ditto -c -k --keepParent "$WORK/Tween" export/Tween.zip

echo "App:  export/Tween.app ($(lipo -archs export/Tween.app/Contents/MacOS/Tween))"
echo "Zip:  export/Tween.zip ($(du -h export/Tween.zip | cut -f1))"
