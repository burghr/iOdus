#!/bin/sh
# Makes a native arm64 runtime for iOdus from the release files of the Highball
# arm64 engine (https://github.com/gauthierpiarrette/highball-engine): Wine 11.18
# built for Apple silicon (ARM64X), FEX as Wine's x86-64 emulator, vkd3d-proton
# and DXVK, and KosmicKrisp (Mesa's Vulkan driver on Metal 4) with the Khronos
# Vulkan loader. x86-64 games run through FEX, not Rosetta 2.
#
# The runtime starts only through the signed Wine loader of the app
# (Contents/Helpers/WineLoader.app, built by build-app.sh): runtime.json names
# the link (signedLoader), and iOdus points it at the loader before each start.
# The iOdus Xbox DLLs go into an overlay folder that Wine searches first
# (WINEDLLPATH_PREPEND, Highball engine patch 0003); iOdus fills it from the app.
#
# Usage: make-fex-runtime.sh <engine.tar.gz> <renderers.tar.gz> <kosmickrisp.tar.gz> <output folder> [<id> <name> <release>]
#   engine:      engine-arm64-wine-11.18-*.tar.gz (a Highball release, or a build of
#                build-arm64.yml with extra patches for the alpha runtime)
#   renderers:   renderers-arm64-*.tar.gz
#   kosmickrisp: kosmickrisp-arm64-*.tar.gz
#   output:      for example ~/Library/Application Support/iOdus/Runtimes/highball-arm64-r5
#                (the folder name is the runtime ID, as for every runtime)
# Each archive needs its .sha256 file beside it (as the releases have them).
set -eu

[ $# -ge 4 ] || { sed -n '2,23p' "$0" >&2; exit 2; }
ENGINE=$1 RENDERERS=$2 KK=$3 OUT=$4
ID=${5:-$(basename "$OUT")}
NAME=${6:-Highball arm64 engine}
RELEASE=${7:-1}

[ "$ID" = "$(basename "$OUT")" ] || { echo "The folder name must be the runtime ID ($ID)." >&2; exit 1; }
[ -e "$OUT" ] && { echo "$OUT exists. Remove it first." >&2; exit 1; }
for f in "$ENGINE" "$RENDERERS" "$KK"; do
  [ -f "$f" ] || { echo "Missing $f" >&2; exit 1; }
  [ -f "$f.sha256" ] || { echo "Missing $f.sha256" >&2; exit 1; }
  want=$(cut -d' ' -f1 < "$f.sha256")
  have=$(shasum -a 256 "$f" | cut -d' ' -f1)
  [ "$want" = "$have" ] || { echo "SHA-256 mismatch: $f" >&2; exit 1; }
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$ID" "$WORK/renderers" "$WORK/kk"
R="$WORK/$ID"

# The engine: engine/ (Wine), frameworks/ (GStreamer), renderers/ (empty), tools/.
tar -xzf "$ENGINE" -C "$R"
[ -x "$R/engine/bin/wineserver" ] || { echo "No engine/bin/wineserver in $ENGINE" >&2; exit 1; }
# The engine's own loader is signed ad hoc and cannot run x86-64 code. The app's
# signed loader takes its place (signedLoader); bin/wine goes through the link.
rm -f "$R/engine/lib/wine/aarch64-unix/wine" "$R/engine/bin/wine"
ln -s ../lib/wine/aarch64-unix/wine "$R/engine/bin/wine"

# vkd3d-proton and DXVK.
tar -xzf "$RENDERERS" -C "$WORK/renderers"
mkdir -p "$R/renderers"
ditto "$WORK/renderers/renderers" "$R/renderers"
mkdir -p "$R/LICENSES/renderers"
cp "$WORK/renderers/licenses/"* "$R/LICENSES/renderers/"
cp "$WORK/renderers/BUILD.txt" "$R/LICENSES/renderers/BUILD.txt"

# KosmicKrisp, and the Khronos loader under the name winevulkan opens (libMoltenVK.dylib).
tar -xzf "$KK" -C "$WORK/kk"
ditto "$WORK/kk/renderers/kosmickrisp" "$R/renderers/kosmickrisp"
cp "$WORK/kk/lib/libMoltenVK.dylib" "$R/engine/lib/libMoltenVK.dylib"
mkdir -p "$R/LICENSES/kosmickrisp"
cp "$WORK/kk/licenses/"* "$R/LICENSES/kosmickrisp/"
cp "$WORK/kk/BUILD.txt" "$R/LICENSES/kosmickrisp/BUILD.txt"

cat > "$R/runtime.json" <<JSON
{
  "id": "$ID",
  "name": "$NAME",
  "wineVersion": "11.18",
  "release": $RELEASE,
  "wine": "engine/bin/wine",
  "wineserver": "engine/bin/wineserver",
  "libraries": "engine/lib",
  "signedLoader": "engine/lib/wine/aarch64-unix/wine",
  "components": ["xgameruntime.dll", "api-ms-win-core-psm-appnotify-l1-1-0.dll"],
  "overrides": {"api-ms-win-core-psm-appnotify-l1-1-0": "native"},
  "register": ["windows.web.dll"],
  "propertySet": "wintypes.dll",
  "overlay": {
    "folder": "xbox/wine/aarch64-windows",
    "files": {"windows.web.dll": "windows.web.dll", "twinapi.appcore.dll": "twinapi.appcore.dll", "wintypes.dll": "iodus_wintypes.dll"}
  },
  "environment": {
    "DYLD_FALLBACK_LIBRARY_PATH": "{root}/engine/lib:{root}/frameworks:{root}/frameworks/GStreamer.framework/Versions/1.0/lib",
    "DYLD_FALLBACK_FRAMEWORK_PATH": "{root}/frameworks",
    "GST_PLUGIN_PATH": "{root}/frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0",
    "VK_DRIVER_FILES": "{root}/renderers/kosmickrisp/kosmickrisp_icd.json",
    "VK_LOADER_LAYERS_DISABLE": "~implicit~",
    "MESA_SHADER_CACHE_DIR": "{prefix}/.mesa-cache",
    "MESA_SHADER_CACHE_MAX_SIZE": "4G",
    "WINEDLLPATH_PREPEND": "{root}/xbox/wine:{root}/renderers/vkd3d/wine",
    "WINEDLLOVERRIDES": "dxgi,d3d11,d3d10core,d3d12,d3d12core=n,b",
    "DXVK_RELAX_FEATURES": "1",
    "VKD3D_RELAX_DEVICE_CAPS": "1",
    "VKD3D_FEATURE_LEVEL": "12_0",
    "VKD3D_SHADER_MODEL": "6_6",
    "VKD3D_SHADER_CACHE_PATH": "C:\\\\vkd3d-cache"
  }
}
JSON
python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$R/runtime.json" || { echo "Bad runtime.json" >&2; exit 1; }

cat > "$R/SOURCES.md" <<EOF
# Sources of this runtime

A native arm64 runtime from the release files of the Highball arm64 engine
(https://github.com/gauthierpiarrette/highball-engine, LGPL-2.1-or-later):

| Archive | SHA-256 |
|---|---|
| $(basename "$ENGINE") | $(cut -d' ' -f1 < "$ENGINE.sha256") |
| $(basename "$RENDERERS") | $(cut -d' ' -f1 < "$RENDERERS.sha256") |
| $(basename "$KK") | $(cut -d' ' -f1 < "$KK.sha256") |

Each Highball release names its source: the pinned upstream archives
(inputs-arm64.json) and the patch series at the release's commit. The licenses
of the parts are in LICENSES/ and in the engine's own files. The Wine loader
that starts this runtime is in the iOdus app (Contents/Helpers/WineLoader.app).
EOF

mkdir -p "$(dirname "$OUT")"
mv "$R" "$OUT"
echo "== $OUT: $NAME (runtime $ID, release $RELEASE)"
