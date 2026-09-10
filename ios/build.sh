#!/usr/bin/env bash
# Build IPadDisplay.app for armv7 / iOS 9 without Xcode.
# usage: ios/build.sh <toolchain-dir with bin/clang and bin/ld> <iPhoneOS9.3.sdk> <out-dir>
set -euo pipefail
TC="$1"; SDK="$2"; OUT="$3"
SRC="$(cd "$(dirname "$0")" && pwd)/IPadDisplay"
APP="$OUT/IPadDisplay.app"
BUNDLE_ID="com.manar.ipaddisplay"
export PATH="$TC/bin:$PATH"

CFLAGS=(--target=armv7-apple-ios9.0 -isysroot "$SDK" -fobjc-arc -O2 -Wall -Wno-unused-command-line-argument)
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$APP"

objs=()
for m in "$SRC"/*.m; do
  o="$OUT/obj/$(basename "${m%.m}").o"
  echo "CC  $(basename "$m")"
  clang "${CFLAGS[@]}" -c "$m" -o "$o"
  objs+=("$o")
done

echo "LD  IPadDisplay"
clang "${CFLAGS[@]}" -fuse-ld=ld -framework UIKit -framework Foundation -framework CoreGraphics -lobjc \
  -Xlinker -ios_version_min -Xlinker 9.0 -o "$APP/IPadDisplay" "${objs[@]}"

# Info.plist: expand the Xcode-style variables, add the keys a bare bundle needs.
sed -e 's/\$(EXECUTABLE_NAME)/IPadDisplay/g' -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$BUNDLE_ID/g" -e 's/\$(PRODUCT_NAME)/IPadDisplay/g' \
  "$SRC/Info.plist" \
| sed -e 's#<key>LSRequiresIPhoneOS</key>#<key>MinimumOSVersion</key><string>9.0</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array><key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array><key>CFBundleSignature</key><string>????</string><key>DTPlatformName</key><string>iphoneos</string><key>DTSDKName</key><string>iphoneos9.3</string><key>LSRequiresIPhoneOS</key>#' \
  > "$APP/Info.plist"
echo "APPL????" > "$APP/PkgInfo"

echo "SIGN (ldid -S)"
ldid -S "$APP/IPadDisplay" || echo "ldid not available here; sign on device with: ldid -S /Applications/IPadDisplay.app/IPadDisplay"

file "$APP/IPadDisplay" || true
( cd "$OUT" && zip -qr IPadDisplay.app.zip IPadDisplay.app )
ls -la "$OUT/IPadDisplay.app.zip" "$APP"
