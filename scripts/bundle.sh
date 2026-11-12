#!/usr/bin/env bash
# Assemble MicroManager.app, with the Inspector nested inside it.
#
# SwiftPM cannot emit an .app bundle, and an unbundled binary is a poor
# background app: no LSUIElement, no stable identity for TCC, and SMAppService
# refuses to register it as a login item.
#
#   ./scripts/bundle.sh              build into build/
#   ./scripts/bundle.sh --install    also copy to /Applications and launch
#
# Signing matters more than it looks. macOS keys the Input Monitoring grant to
# the designated requirement. A real identity provides a stable requirement.
# For local ad-hoc builds we explicitly use the bundle identifier as the
# requirement; this is less tamper-resistant than a real certificate, but keeps
# the local permission stable across rebuilds.
#
# Set WL_SIGN_IDENTITY to choose the identity explicitly (CI does this);
# otherwise the first Developer ID or Apple Development identity in the
# keychain is used.
#
# Set WL_MACOS_SDK to an SDK directory to build against it instead of the
# toolchain default, e.g. Command Line Tools 27.x, whose macOS 27 SDK needs
# Xcode's SwiftUI macro plugin:
#
#   WL_MACOS_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ./scripts/bundle.sh
#
# SwiftPM alone then records SDK 13.0 in the binary, which would give it
# macOS 13 AppKit/SwiftUI compatibility behavior, so the SDK version is passed
# to the linker explicitly and checked afterwards.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MicroManager"
BUNDLE_ID="cc.worklouder.micromanager"
INSPECTOR_NAME="Inspector"
INSPECTOR_BUNDLE_ID="cc.worklouder.inspector"
VERSION="${WL_VERSION:-0.1.0}"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"
INSPECTOR="$APP/Contents/Library/$INSPECTOR_NAME.app"

install=false
[[ "${1:-}" == "--install" ]] && install=true

BUILD_FLAGS=()
SDK_VERSION=""
if [[ -n "${WL_MACOS_SDK:-}" ]]; then
    SDK_VERSION="$(plutil -extract Version raw "$WL_MACOS_SDK/SDKSettings.plist" 2>/dev/null)" || {
        echo "WL_MACOS_SDK is not an SDK: $WL_MACOS_SDK" >&2; exit 1; }
    # Must match platforms: [.macOS(.v13)] in Package.swift.
    MIN_MACOS="13.0"
    BUILD_FLAGS=(--sdk "$WL_MACOS_SDK"
        -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")
    echo "==> SDK $SDK_VERSION: $WL_MACOS_SDK"
fi

echo "==> building (release)"
swift build -c release --product WLMicroManager ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
swift build -c release --product WLInspector ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
for product in WLMicroManager WLInspector; do
    [[ -f ".build/release/$product" ]] || {
        echo "build produced no binary at .build/release/$product" >&2; exit 1; }
    if [[ -n "$SDK_VERSION" ]]; then
        recorded="$(vtool -show-build ".build/release/$product" | awk '$1 == "sdk" { print $2; exit }')"
        [[ "$recorded" == "$SDK_VERSION" ]] || {
            echo "$product records SDK ${recorded:-none}, expected $SDK_VERSION" >&2; exit 1; }
    fi
done

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library"
cp ".build/release/WLMicroManager" "$APP/Contents/MacOS/$APP_NAME"

echo "==> drawing icon"
ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/genicon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Micro Manager</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app-switcher entry. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Interoperability tool for the Work Louder Creator Micro 2.</string>
</dict>
</plist>
PLIST

# The Inspector rides along inside the host bundle. One download, one trust
# decision - and the panel's "Inspector" button has something to open.
echo "==> assembling $INSPECTOR"
mkdir -p "$INSPECTOR/Contents/MacOS" "$INSPECTOR/Contents/Resources"
cp ".build/release/WLInspector" "$INSPECTOR/Contents/MacOS/$INSPECTOR_NAME"
cp "$APP/Contents/Resources/AppIcon.icns" "$INSPECTOR/Contents/Resources/AppIcon.icns"

cat > "$INSPECTOR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$INSPECTOR_NAME</string>
    <key>CFBundleDisplayName</key>       <string>Micro Manager Inspector</string>
    <key>CFBundleIdentifier</key>        <string>$INSPECTOR_BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$INSPECTOR_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHumanReadableCopyright</key>  <string>Debug UI for the Work Louder Creator Micro 2.</string>
</dict>
</plist>
PLIST

echo "==> signing"
IDENTITY="${WL_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -m1 -E '"(Apple Development|Developer ID Application)[^"]*"' \
        | sed -E 's/.*"(.*)"/\1/' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
    echo "    identity: $IDENTITY"
    INSPECTOR_SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
    APP_SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
else
    echo "    WARNING: no signing identity found; using a stable local ad-hoc requirement." >&2
    INSPECTOR_SIGN=(codesign --force --sign - --requirements "=designated => identifier \"$INSPECTOR_BUNDLE_ID\"")
    APP_SIGN=(codesign --force --sign - --requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

# Inside out: signing a nested bundle after its host invalidates the host seal.
"${INSPECTOR_SIGN[@]}" "$INSPECTOR"
"${APP_SIGN[@]}" "$APP"
codesign --verify --deep --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if $install; then
    echo "==> installing to /Applications"
    # Replacing a running app leaves a zombie in the menu bar.
    pkill -f "/Applications/$APP_NAME.app" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "==> launching"
    open "/Applications/$APP_NAME.app"
    echo
    echo "If this is the first launch, macOS will ask for Input Monitoring."
    echo "Grant it, then toggle the manager off and on from the menu bar."
else
    echo
    echo "built: $APP"
    echo "run:   open $APP        (or ./scripts/bundle.sh --install)"
fi
