#!/bin/bash
# Builds the tweak and preference bundle against a legacy iOS SDK, assembles the .deb, and
# refreshes the Cydia repo index under repo/. Needs no theos - just clang, ldid and dpkg.
#   SDK=/path/to/iPhoneOS9.3.sdk ./package.sh
set -euo pipefail

cd "$(dirname "$0")"

SDK="${SDK:-$PWD/../sdks/iPhoneOS9.3.sdk}"
MIN_IOS="7.0"
PACKAGE="$(awk '/^Package:/ {print $2}' control)"
VERSION="$(awk '/^Version:/ {print $2}' control)"
STAGE="build/stage"
DEB="build/${PACKAGE}_${VERSION}_iphoneos-arm.deb"

[ -d "$SDK" ] || { echo "Missing SDK at $SDK"; exit 1; }

command rm -rf build
mkdir -p build

# ld-classic is required: the modern linker cannot consume the SDK's TBD v1 stub libraries.
compile() {
    local output="$1" source="$2" kind="$3"; shift 3
    for arch in armv7 arm64; do
        xcrun clang -arch "$arch" \
            -isysroot "$SDK" \
            -miphoneos-version-min="$MIN_IOS" \
            "$kind" -Os -Wall \
            -Wl,-ld_classic \
            -Wno-objc-method-access \
            -F "$SDK/System/Library/PrivateFrameworks" \
            "$@" \
            "$source" -o "$output-$arch" 2>&1 \
            | grep -vE "built for iOS Simulator|ld_classic is deprecated" || true
        [ -f "$output-$arch" ] || { echo "Build failed for $arch: $source"; exit 1; }
    done
    lipo -create "$output-armv7" "$output-arm64" -output "$output"
    command rm -f "$output-armv7" "$output-arm64"
    strip -x "$output"
    ldid -S "$output"
}

compile build/PerceptTweak.dylib tweak/PerceptTweak.m -dynamiclib \
    -install_name /Library/MobileSubstrate/DynamicLibraries/PerceptTweak.dylib \
    -framework Foundation -framework UIKit -framework CFNetwork

# Built without ARC on purpose: ARC below iOS 9 wants libarclite, which current Xcode no
# longer ships. Neither source performs ownership operations that ARC would change.
compile build/perceptprefs perceptprefs/XXXRootListController.m -bundle \
    -framework UIKit -framework Foundation -framework Preferences

PREFBUNDLE="$STAGE/Library/PreferenceBundles/perceptprefs.bundle"
mkdir -p "$STAGE/DEBIAN" "$PREFBUNDLE" \
         "$STAGE/Library/MobileSubstrate/DynamicLibraries" \
         "$STAGE/Library/PreferenceLoader/Preferences"

cp control "$STAGE/DEBIAN/control"

cp build/PerceptTweak.dylib "$STAGE/Library/MobileSubstrate/DynamicLibraries/"
cp tweak/PerceptTweak.plist "$STAGE/Library/MobileSubstrate/DynamicLibraries/"

cp build/perceptprefs "$PREFBUNDLE/perceptprefs"
cp perceptprefs/Resources/Info.plist "$PREFBUNDLE/Info.plist"
cp perceptprefs/Resources/Root.plist "$PREFBUNDLE/Root.plist"
cp perceptprefs/Resources/icon*.png "$PREFBUNDLE/"

cp perceptprefs/layout/Library/PreferenceLoader/Preferences/perceptprefs.plist \
   "$STAGE/Library/PreferenceLoader/Preferences/perceptprefs.plist"

find "$STAGE" -name '.DS_Store' -delete
chmod -R 755 "$STAGE"

dpkg-deb --root-owner-group -Zgzip -b "$STAGE" "$DEB"

# Refresh the repo index so GitHub Pages serves the new package.
command rm -f repo/debs/*.deb
cp "$DEB" repo/debs/
(
    cd repo
    dpkg-scanpackages debs /dev/null 2>/dev/null \
        | sed 's|^Filename: |Filename: ./|' > Packages
    gzip -9 -c Packages > Packages.gz
    bzip2 -9 -c Packages > Packages.bz2
)

echo
echo "Built $DEB"
dpkg-deb -c "$DEB" | awk '{print $1, $6}'
