#!/bin/bash
#
#  make-release.sh — builds a Release copy of InHaus EQ and packages it as a .dmg.
#
#  Run from Terminal:   bash ~/Desktop/InHausEQ/Scripts/make-release.sh
#  Result:              ~/Desktop/InHausEQ/dist/InHaus-EQ-<version>.dmg
#
#  Signed with your Personal Team (free), not notarized, so people opening it for the
#  first time need System Settings → Privacy & Security → Open Anyway (see the
#  "How to Install" note that goes inside the .dmg).
#
set -uo pipefail

fail() { echo; echo "✗ $*" >&2; exit 1; }

cd "$(dirname "$0")/.." || fail "Couldn't find the project folder."
PROJECT=InHausEQ.xcodeproj
SCHEME=InHausEQ
WORK=build/release
ARCHIVE="$WORK/InHausEQ.xcarchive"
[ -d "$PROJECT" ] || fail "Run this from the InHausEQ project (couldn't find $PROJECT in $(pwd))."

# 1. Make sure the command-line tools point at Xcode.
if ! XCODE_VERSION=$(xcodebuild -version 2>&1); then
    echo "$XCODE_VERSION"
    echo
    echo "xcodebuild isn't set up to use Xcode yet. Run these two commands once"
    echo "(they ask for your Mac password), then run this script again:"
    echo
    echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "    sudo xcodebuild -license accept"
    exit 1
fi
echo "Using $(echo "$XCODE_VERSION" | head -n 1)"

# 2. Version numbers, straight from the project file.
VERSION=$(grep -m 1 'MARKETING_VERSION = ' "$PROJECT/project.pbxproj" | sed -E 's/.*= *"?([^";]+)"?;.*/\1/')
BUILD=$(grep -m 1 'CURRENT_PROJECT_VERSION = ' "$PROJECT/project.pbxproj" | sed -E 's/.*= *"?([^";]+)"?;.*/\1/')
[ -n "$VERSION" ] || fail "Couldn't read the version number from the project."
echo "==> Building InHaus EQ $VERSION ($BUILD). This takes a minute or two…"

# 3. Archive (Release, Apple Silicon + Intel).
rm -rf "$WORK"
mkdir -p "$WORK" dist
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
           -destination "generic/platform=macOS" \
           -archivePath "$ARCHIVE" -allowProvisioningUpdates \
           archive -quiet \
    || fail "The build failed. The errors are above; paste them to Claude."

APP=$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name "*.app" | head -n 1)
[ -n "$APP" ] || fail "The build finished but no app was found in the archive."

# 4. Check the signature.
echo "==> Checking the signature"
codesign --verify --deep --strict "$APP" || fail "The app's signature doesn't check out."
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|TeamIdentifier)=" | sed 's/^/    /'
echo "    Architectures: $(lipo -archs "$APP/Contents/MacOS/"*)"

# 5. Disk image: the app, a shortcut to Applications, and the install note.
echo "==> Making the disk image"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$(basename "$APP")" || fail "Couldn't copy the app."
ln -s /Applications "$STAGE/Applications"
cp "Scripts/How to Install.txt" "$STAGE/How to Install.txt" || fail "Scripts/How to Install.txt is missing."

DMG="dist/InHaus-EQ-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "InHaus EQ $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null \
    || fail "Couldn't create the disk image."

echo
echo "✓ Done: $(pwd)/$DMG"
echo "  SHA-256: $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
open -R "$DMG"
