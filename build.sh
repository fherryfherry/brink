#!/bin/bash
# Brink — tek komutla derle, .app ve .dmg üret.
# Gereksinim: macOS 13+ ve Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Brink"
BUNDLE_ID="com.semihtali.brink"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Swift derleniyor (release)..."
swift build -c release

echo "==> .app paketi oluşturuluyor..."
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundle (logos) — Bundle.module looks for it in Contents/Resources
if [ -d ".build/release/${APP_NAME}_${APP_NAME}.bundle" ]; then
  cp -R ".build/release/${APP_NAME}_${APP_NAME}.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>tr</string><string>de</string><string>fr</string><string>es</string><string>pt-BR</string><string>it</string><string>ja</string><string>zh-Hans</string><string>ko</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><false/>
    </dict>
</dict>
</plist>
PLIST

echo "==> İmzalanıyor..."
# A stable local identity, not ad-hoc (`-sign -`): ad-hoc signatures hash the
# binary itself, so every rebuild gets a different identity and macOS treats
# it as a new app for Keychain ACL purposes — re-prompting for "Allow" access
# to Claude Code's credentials on every single build. Signing with the same
# certificate every time keeps that grant valid across rebuilds.
# One-time setup (already done for this checkout): a self-signed
# "Brink Local Dev" code-signing cert imported into the login keychain.
SIGN_IDENTITY="Brink Local Dev"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "    (no '$SIGN_IDENTITY' identity found — falling back to ad-hoc, which re-prompts for Keychain access on every rebuild)"
    SIGN_IDENTITY="-"
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"

echo "==> DMG oluşturuluyor..."
DMG_ROOT="$DIST/dmgroot"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$DMG_ROOT"

echo ""
echo "✅ Bitti!"
echo "   Uygulama : $APP"
echo "   DMG      : $DIST/$APP_NAME.dmg"
echo ""
echo "Çalıştırmak için:  open $APP"
echo "veya DMG'yi açıp Brink'ı Applications klasörüne sürükleyin."
