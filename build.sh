#!/bin/zsh
# Builds build/GregsUtils.app. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/GregsUtils.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos15.2" \
  Sources/*.swift Sources/*/*.swift \
  -o "$APP/Contents/MacOS/GregsUtils"

swift Tools/make_icon.swift build/GregsUtils.iconset
iconutil -c icns build/GregsUtils.iconset -o "$APP/Contents/Resources/GregsUtils.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# macOS ties the Screen Recording and Accessibility grants to the code signature. An ad-hoc
# signature changes on every build, which silently invalidates them. Signing with a stable
# local certificate keeps them across rebuilds. See README.
SIGN_ID="${SIGN_ID:-GregsUtils Dev}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
    codesign --force --sign "$SIGN_ID" "$APP"
else
    echo "warning: no '$SIGN_ID' signing certificate found; signing ad-hoc." >&2
    echo "warning: you'll need to re-grant Screen Recording and Accessibility after every rebuild." >&2
    codesign --force --sign - --identifier com.gregc.gregsutils "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    # Safe to stop it: every editor tab is already autosaved.
    pkill -x GregsUtils 2>/dev/null && sleep 1 || true
    rm -rf /Applications/GregsUtils.app
    cp -R "$APP" /Applications/
    open /Applications/GregsUtils.app
    echo "Installed and launched /Applications/GregsUtils.app"
fi
