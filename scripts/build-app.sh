#!/bin/sh
# Builds build/iOdus.app: the app, the backend (xodus-cli), the Xbox runtime
# DLLs, the icon, and Info.plist. Signs it with the Developer ID Application
# identity in the login keychain (else the local "iOdus Local Signing"), with
# the hardened runtime. With --notarize, Apple notarizes the app and the
# ticket is stapled to it.
#
# Usage: scripts/build-app.sh [--notarize] [version]
# Inputs (override with environment variables):
#   BACKEND     the signed xodus-cli   (default ~/projects/iodus-xodus/target/release/xodus-cli)
#   LOCK        backend source lock    (default ~/projects/iodus-xodus/nexus/backend-source.lock.json)
#   COMPONENTS  runtime DLL folder     (default ~/projects/iodus-runtime-build/components)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NOTARIZE=0
if [ "${1:-}" = "--notarize" ]; then NOTARIZE=1; shift; fi
VERSION=${1:-0.1.0}
BUILD_NUMBER=$(git -C "$ROOT" rev-list --count HEAD)
BACKEND=${BACKEND:-$HOME/projects/iodus-xodus/target/release/xodus-cli}
LOCK=${LOCK:-$HOME/projects/iodus-xodus/nexus/backend-source.lock.json}
COMPONENTS=${COMPONENTS:-$HOME/projects/iodus-runtime-build/components}
. "$ROOT/scripts/signing.sh"
NOTARY_PROFILE=${NOTARY_PROFILE:-iodus-notary}
APP="$ROOT/build/iOdus.app"
DLLS="xgameruntime.dll windows.web.dll twinapi.appcore.dll iodus_wintypes.dll api-ms-win-core-psm-appnotify-l1-1-0.dll api-ms-win-core-debug-minidump-l1-1-0.dll d3d11.dll winhttp.dll"

for f in "$BACKEND" "$LOCK" "$ROOT/Resources/AppIcon.icns"; do
  [ -f "$f" ] || { echo "Missing: $f" >&2; exit 1; }
done
for dll in $DLLS; do
  [ -f "$COMPONENTS/$dll" ] || { echo "Missing runtime DLL: $COMPONENTS/$dll" >&2; exit 1; }
done
[ -f "$COMPONENTS/highball-d3d12-shim.dll" ] || { echo "Missing: $COMPONENTS/highball-d3d12-shim.dll (scripts/build-runtime.sh)" >&2; exit 1; }
[ -f "$COMPONENTS/compat/PlayFabGameSave.dll" ] || { echo "Missing: $COMPONENTS/compat/PlayFabGameSave.dll (scripts/build-runtime.sh)" >&2; exit 1; }

echo "== Build iOdus (release)"
swift build -c release --package-path "$ROOT"

echo "== Make the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
cp "$ROOT/.build/release/iOdus" "$APP/Contents/MacOS/iOdus"
# The same signed binary keeps its code hash, so the Keychain items keep their access.
cp "$BACKEND" "$APP/Contents/MacOS/xodus-cli"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$LOCK" "$APP/Contents/Resources/backend-source.lock.json"
for dll in $DLLS; do cp "$COMPONENTS/$dll" "$APP/Contents/Resources/runtime/"; done
# The Wine start script, and the PlayFab save proxy that it puts in front of a
# game's PlayFabGameSave.dll (never copied into a prefix).
cp "$ROOT/scripts/runtime-compat/iodus-wine-launch" "$APP/Contents/Resources/runtime/"
chmod 755 "$APP/Contents/Resources/runtime/iodus-wine-launch"
mkdir -p "$APP/Contents/Resources/runtime/compat"
cp "$COMPONENTS/compat/PlayFabGameSave.dll" "$APP/Contents/Resources/runtime/compat/"
# The d3d12.dll layer for the D3DMetal 4 beta runtime (RuntimeInstaller.addD3DMetal4).
cp "$COMPONENTS/highball-d3d12-shim.dll" "$APP/Contents/Resources/runtime/compat/"

# Licenses and sources. iOdus is GPL-3.0; xodus-cli is GPL-3.0 (Xodus); the
# Xbox runtime DLLs are Wine code under the LGPL 2.1 or later. Both licenses
# require that the user can get the exact source of this build.
BACKEND_REPO=${BACKEND_REPO:-$HOME/projects/iodus-xodus}
[ -e "$BACKEND_REPO/.git" ] || { echo "Missing $BACKEND_REPO (needed for the source list)" >&2; exit 1; }
L="$APP/Contents/Resources/LICENSES"
mkdir -p "$L"
cp "$ROOT/LICENSE" "$L/GPL-3.0.txt"
cp "$ROOT/licenses/LGPL-2.1.txt" "$L/LGPL-2.1.txt"
commit() { git -C "$1" rev-parse HEAD; }
dirty() { [ -z "$(git -C "$1" status --porcelain)" ] || echo " (with local changes)"; }
pin() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sources'][sys.argv[2]]['commit'])" "$ROOT/scripts/nexus-runtime-patches/lock.json" "$1"; }
cat > "$L/SOURCES.md" <<SOURCES
# Licenses and sources of iOdus $VERSION (build $BUILD_NUMBER)

| Part | License | Source |
|---|---|---|
| iOdus (the app) | GPL-3.0 (GPL-3.0.txt) | https://github.com/burghr/iOdus, commit $(commit "$ROOT")$(dirty "$ROOT") |
| xodus-cli (Contents/MacOS) | GPL-3.0 (GPL-3.0.txt) | https://github.com/burghr/iodus-xodus, branch iodus, commit $(commit "$BACKEND_REPO")$(dirty "$BACKEND_REPO") |
| Xbox runtime DLLs (Contents/Resources/runtime): xgameruntime, windows.web, twinapi.appcore, iodus_wintypes | LGPL 2.1 or later (LGPL-2.1.txt) | Wine https://github.com/xodus-gaming/wine commit $(pin wine); xgameruntime https://github.com/xodus-gaming/xgameruntime commit $(pin xgameruntime); the patches in scripts/nexus-runtime-patches (from Xodus Nexus, MIT, see NOTICE.md there) and scripts/runtime-patches of iOdus |
| Forwarders and proxies (Contents/Resources/runtime): api-ms-win-core-*, d3d11, winhttp | GPL-3.0 (GPL-3.0.txt) | scripts/runtime-compat of iOdus |
| Wine loader (Contents/Helpers/WineLoader.app) | LGPL 2.1 or later (LGPL-2.1.txt) | Wine 11.18 loader/main.c with the changes of Highball (https://github.com/gauthierpiarrette/highball, spike/wineloader); scripts/runtime-compat/wineloader of iOdus |

scripts/build-runtime.sh of iOdus builds the DLLs from these sources.
The Game Porting Toolkit and D3DMetal are Apple's software under Apple's license.
iOdus does not contain them; the setup downloads them after you accept the license.
SOURCES

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.burghr.iodus</string>
  <key>CFBundleName</key><string>iOdus</string>
  <key>CFBundleDisplayName</key><string>iOdus</string>
  <key>CFBundleExecutable</key><string>iOdus</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>iOdus. Not affiliated with Microsoft or Xbox.</string>
</dict>
</plist>
PLIST

echo "== Sign with: $IDENTITY"
# The same binary, identifier, and identity give the same code hash, so the
# Keychain items of xodus-cli keep their access.
# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS --entitlements "$ROOT/Resources/xodus-cli.entitlements" \
  -s "$IDENTITY" -i com.burghr.iodus.xodus-cli "$APP/Contents/MacOS/xodus-cli"
# The signed Wine loader for the native arm64 runtimes (Highball arm64 engine with FEX):
# Contents/Helpers/WineLoader.app. Only a loader with Apple's cross-architecture
# entitlement can run x86-64 code in a native arm64 Wine. The entitlement is
# restricted: it needs the Developer ID provisioning profile of the App ID
# com.burghr.iodus.wineloader (WINELOADER_PROFILE, kept out of the repository).
# Without a Developer ID or the profile, the app has no helper and cannot start
# those runtimes (GameRuntime.problem says so). -x86_64_layout_emulation needs Xcode 26.4.
WINELOADER_PROFILE=${WINELOADER_PROFILE:-$HOME/projects/iodus-runtimes/signing/iodus-wineloader-developer-id.provisionprofile}
HELPER="$APP/Contents/Helpers/WineLoader.app"
if [ "$DEVELOPER_ID" = 1 ] && [ -f "$WINELOADER_PROFILE" ]; then
  echo "== Build the Wine loader helper"
  TEAM=$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
  [ -n "$TEAM" ] || { echo "No team ID in $IDENTITY" >&2; exit 1; }
  LOADER_SRC="$ROOT/scripts/runtime-compat/wineloader"
  LOADER_TMP=$(mktemp -d)
  mkdir -p "$HELPER/Contents/MacOS"
  # The flags of Highball's spike/wineloader/build.sh: platform and SDK 11.0 keep x18 for
  # Windows ARM64 code; PAGEZERO and image base at 0x170000000 with the layout flag.
  MACOSX_DEPLOYMENT_TARGET=11.0 clang -arch arm64 -O2 -Wall -mmacos-version-min=11.0 \
    -o "$HELPER/Contents/MacOS/wine" "$LOADER_SRC/main.c" \
    -Wl,-platform_version,macos,11.0,11.0 \
    -Wl,-pagezero_size,0x170000000 -Wl,-image_base,0x170000000 -Wl,-x86_64_layout_emulation \
    -Wl,-sectcreate,__TEXT,__info_plist,"$LOADER_SRC/wine_info.plist" 2> "$LOADER_TMP/ld.log" \
    || { cat "$LOADER_TMP/ld.log" >&2; exit 1; }
  otool -l "$HELPER/Contents/MacOS/wine" | grep -A3 "segname __PAGEZERO" | grep -q "vmsize 0x0000000170000000" \
    || { echo "The Wine loader's PAGEZERO is not 0x170000000" >&2; exit 1; }
  cat > "$HELPER/Contents/Info.plist" <<HELPERPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.burghr.iodus.wineloader</string>
  <key>CFBundleExecutable</key><string>wine</string>
  <key>CFBundleName</key><string>iOdus Wine Loader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSBackgroundOnly</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.5</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict></plist>
HELPERPLIST
  cp "$WINELOADER_PROFILE" "$HELPER/Contents/embedded.provisionprofile"
  cat > "$LOADER_TMP/wineloader.entitlements" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.developer.cross-architecture-support</key><true/>
  <key>com.apple.application-identifier</key><string>$TEAM.com.burghr.iodus.wineloader</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM</string>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
</dict></plist>
ENTITLEMENTS
  # shellcheck disable=SC2086
  codesign --force $SIGN_FLAGS --entitlements "$LOADER_TMP/wineloader.entitlements" -s "$IDENTITY" "$HELPER"
  rm -rf "$LOADER_TMP"
else
  echo "Note: no Developer ID or no $WINELOADER_PROFILE: the app has no Wine loader helper (no native arm64 runtimes)."
fi

# shellcheck disable=SC2086
codesign --force $SIGN_FLAGS -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "Signature OK"

if [ "$NOTARIZE" = 1 ]; then
  [ "$DEVELOPER_ID" = 1 ] || { echo "Notarization needs a Developer ID identity." >&2; exit 1; }
  echo "== Notarize (profile $NOTARY_PROFILE)"
  ZIP="$ROOT/build/iOdus-notarize.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  spctl --assess --type execute -vv "$APP"
fi
du -sh "$APP"
echo "Built $APP ($VERSION, build $BUILD_NUMBER)"
