#!/bin/zsh
# Build 斐讯麦 (FeiXunMai.app) and package it.
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=".build/release-app"
APP_NAME="斐讯麦.app"
APP_DIR="dist/$APP_NAME"
VERSION="0.3.0"

echo "==> swift build (release)"
swift build -c release

echo "==> assembling $APP_DIR"
rm -rf dist "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp Info.plist "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
cp .build/release/FeiXunMai "$APP_DIR/Contents/MacOS/FeiXunMai"

echo "==> codesign"
if security find-identity -v -p codesigning | grep -q "FeiXunMai Dev"; then
  codesign --force --deep -s "FeiXunMai Dev" "$APP_DIR"
else
  codesign --force --deep -s - "$APP_DIR"
fi

echo "==> zip"
cd dist
zip -qry "斐讯麦-$VERSION.zip" "$APP_NAME"
cd ..

echo "==> dmg"
hdiutil create -volname "斐讯麦" -srcfolder dist/"$APP_NAME" -ov -format UDZO "dist/斐讯麦-$VERSION.dmg" >/dev/null

echo "==> combined installer pkg (app + BlackHole 2ch)"
rm -rf /tmp/feixunmai-pkgroot /tmp/bhroot /tmp/bhscripts /tmp/pkgpath
mkdir -p /tmp/feixunmai-pkgroot/Applications "/tmp/bhroot/Library/Audio/Plug-Ins/HAL" /tmp/bhscripts
cp -R "dist/$APP_NAME" /tmp/feixunmai-pkgroot/Applications/
cp -R "vendor/BlackHole-full/BlackHole.pkg/Payload/BlackHole2ch.driver" "/tmp/bhroot/Library/Audio/Plug-Ins/HAL/"
printf '#!/bin/sh\nmkdir -p /Library/Audio/Plug-Ins/HAL\nchown root:wheel /Library/Audio/Plug-Ins/HAL\n' > /tmp/bhscripts/preinstall
printf '#!/bin/sh\nchown -R root:wheel /Library/Audio/Plug-Ins/HAL/BlackHole*ch.driver\n' > /tmp/bhscripts/postinstall
chmod +x /tmp/bhscripts/*
pkgbuild --root /tmp/bhroot --scripts /tmp/bhscripts \
  --identifier com.audio.blackhole2ch --version 0.6.1 \
  --install-location / vendor/BlackHole2ch-driver.pkg >/dev/null
pkgbuild --root /tmp/feixunmai-pkgroot \
  --identifier com.feixun.mai --version "$VERSION" \
  --install-location / /tmp/feixunmai-core.pkg >/dev/null
# 豆包专属驱动（USB transport，豆包自动识别）
rm -rf /tmp/fxvroot
mkdir -p "/tmp/fxvroot/Library/Audio/Plug-Ins/HAL"
cp -R driver/FeiXunV2ch.driver "/tmp/fxvroot/Library/Audio/Plug-Ins/HAL/"
pkgbuild --root /tmp/fxvroot \
  --identifier com.feixun.driver2ch --version "0.7.1" \
  --install-location / vendor/FeiXunV2ch-driver.pkg >/dev/null
productbuild --synthesize \
  --package vendor/BlackHole2ch-driver.pkg \
  --package vendor/FeiXunV2ch-driver.pkg \
  --package /tmp/feixunmai-core.pkg /tmp/distribution.dist >/dev/null
python3 - <<'PYEOF'
s = open('/tmp/distribution.dist').read()
if '<license' not in s:
    s = s.replace('<options', '<license file="BlackHole-LICENSE.txt"/><options', 1)
open('/tmp/distribution.dist', 'w').write(s)
PYEOF
mkdir -p /tmp/pkgpath
cp vendor/BlackHole2ch-driver.pkg /tmp/feixunmai-core.pkg /tmp/pkgpath/
cp vendor/BlackHole-full/Resources/LICENSE /tmp/pkgpath/BlackHole-LICENSE.txt
productbuild --distribution /tmp/distribution.dist --package-path /tmp/pkgpath \
  "dist/斐讯麦安装包-$VERSION.pkg" >/dev/null

echo "==> done"
ls -lh dist
