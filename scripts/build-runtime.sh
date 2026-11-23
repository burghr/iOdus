#!/bin/sh
# Builds the Xbox runtime DLLs for iOdus from the pinned Xodus Wine source plus
# the patches in this repository:
#   - scripts/nexus-runtime-patches: copied from Xodus Nexus (MIT, see NOTICE.md),
#     only the patches for the DLLs that iOdus ships.
#   - scripts/runtime-patches: the iOdus patches.
# Wine is configured and built as x86_64 (through Rosetta on arm64), the same
# architecture as the GPTK Wine. Otherwise Wine wants aarch64 PE DLLs.
# Usage: build-runtime.sh <new work folder>
#        RESUME=configure build-runtime.sh <existing work folder>
#          continues after the source steps, for example after a configure error.
# The DLLs go to <work>/components.
set -eu

WORK=${1:?usage: build-runtime.sh <work folder>}
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
PATCHES="$SCRIPTS/nexus-runtime-patches"
LOCK="$PATCHES/lock.json"
JOBS=${JOBS:-8}
RESUME=${RESUME:-}
X86="arch -x86_64"
export PATH="/opt/homebrew/opt/bison/bin:$PATH"

if [ -z "$RESUME" ]; then
  [ -e "$WORK" ] && { echo "Refusing to overwrite $WORK" >&2; exit 1; }
  mkdir -p "$WORK"
fi
WORK=$(cd "$WORK" && pwd)
SRC="$WORK/wine-src"; BUILD="$WORK/wine-build"
OUT="$WORK/components"

lock() { python3 -c "import json,sys; d=json.load(open('$LOCK')); print(eval(sys.argv[1]))" "$1"; }

checkout() { # name target
  url=$(lock "d['sources']['$1']['url']"); commit=$(lock "d['sources']['$1']['commit']")
  mkdir -p "$2"
  git init --quiet "$2"
  git -C "$2" fetch --quiet --depth 1 --no-tags "$url" "$commit"
  git -C "$2" checkout --quiet --detach FETCH_HEAD
  [ "$(git -C "$2" rev-parse HEAD)" = "$commit" ] || { echo "Wrong $1 commit" >&2; exit 1; }
  echo "Checked out $1 $commit"
}

prepare_sources() {
  echo "== Verify the patch checksums"
  python3 - "$LOCK" "$PATCHES" <<'EOF'
import hashlib, json, sys
lock = json.load(open(sys.argv[1]))
for p in lock["patches"]:
    digest = hashlib.sha256(open(f"{sys.argv[2]}/{p['file']}", "rb").read()).hexdigest()
    if digest != p["sha256"]:
        sys.exit(f"Patch checksum mismatch: {p['file']}")
print(f"{len(lock['patches'])} patches match the lock")
EOF

  echo "== Check out the pinned sources"
  checkout wine "$SRC"
  checkout xgameruntime "$SRC/dlls/xgameruntime"

  echo "== Apply the patches from Xodus Nexus"
  python3 -c "
import json
for p in json.load(open('$LOCK'))['patches']: print(p['file'])
" | while read -r patch; do
    git -C "$SRC" apply --check "$PATCHES/$patch"
    git -C "$SRC" apply "$PATCHES/$patch"
    echo "Applied $patch"
  done

  echo "== Verify the patched sources against the lock"
  python3 - "$LOCK" "$SRC" <<'EOF'
import hashlib, json, sys
lock = json.load(open(sys.argv[1]))
files = lock["expectedSources"]
for rel, want in files.items():
    if hashlib.sha256(open(f"{sys.argv[2]}/{rel}", "rb").read()).hexdigest() != want:
        sys.exit(f"Source reproduction mismatch: {rel}")
print(f"{len(files)} patched source files match the lock")
EOF

  echo "== Apply the iOdus patches for the GPTK Wine"
  for patch in "$SCRIPTS"/runtime-patches/*.patch; do
    git -C "$SRC" apply --check "$patch"
    git -C "$SRC" apply "$patch"
    echo "Applied $(basename "$patch")"
  done

  echo "== Generate the Wine build files"
  if [ -f "$SRC/dlls/winevulkan/vk.xml" ]; then
    (cd "$SRC/dlls/winevulkan" && python3 make_vulkan -x vk.xml -X video.xml)
  fi
  (cd "$SRC" && perl tools/make_specfiles && autoreconf -fi >/dev/null 2>&1)
}

configure_and_build() {
  echo "== Configure Wine (x86_64)"
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  (cd "$BUILD" && $X86 env CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
    "$SRC/configure" --enable-win64 --without-x --without-wayland --without-freetype --disable-tests > configure.log 2>&1) \
    || { tail -30 "$BUILD/configure.log" >&2; exit 1; }

  echo "== Build the runtime DLLs"
  $X86 make -C "$BUILD" -j"$JOBS" \
    dlls/xgameruntime/x86_64-windows/xgameruntime.dll \
    dlls/windows.web/x86_64-windows/windows.web.dll \
    dlls/twinapi.appcore/x86_64-windows/twinapi.appcore.dll \
    dlls/wintypes/x86_64-windows/wintypes.dll > "$WORK/make.log" 2>&1 \
    || { tail -40 "$WORK/make.log" >&2; exit 1; }

  mkdir -p "$OUT"
  # winhttp is not built: the Wine 11 winhttp.dll crashes in GPTK Wine 7.7.
  # The iOdus winhttp proxy below takes its name and loads the GPTK one.
  for dll in xgameruntime windows.web twinapi.appcore; do
    cp "$BUILD/dlls/$dll/x86_64-windows/$dll.dll" "$OUT/"
  done
  # Wine 7.7 has no Windows.Foundation.Collections.PropertySet. iOdus registers
  # only that class to this copy of the Wine 11 wintypes.dll.
  cp "$BUILD/dlls/wintypes/x86_64-windows/wintypes.dll" "$OUT/iodus_wintypes.dll"

  # Wine 7.7 has only stubs in this API set. Forward it to twinapi.appcore.
  # The prefix needs the DLL override api-ms-win-core-psm-appnotify-l1-1-0=native.
  COMPAT="$(cd "$(dirname "$0")" && pwd)/runtime-compat"
  x86_64-w64-mingw32-gcc -shared -nostdlib -O2 -Wl,--entry,DllMain \
    -o "$OUT/api-ms-win-core-psm-appnotify-l1-1-0.dll" "$COMPAT/forwarder.c" "$COMPAT/psm-appnotify.def"
  # GPTK Wine 7.7 has no minidump API set. Forward it to dbghelp (DIRT 5).
  # It needs no DLL override: Wine has no builtin DLL with this name. The Wine 11
  # runtime has the API set in its schema instead (wine11-patches).
  x86_64-w64-mingw32-gcc -shared -nostdlib -O2 -Wl,--entry,DllMain \
    -o "$OUT/api-ms-win-core-debug-minidump-l1-1-0.dll" "$COMPAT/forwarder.c" "$COMPAT/debug-minidump.def"
  # D3DMetal answers E_INVALIDARG for unsupported multisample counts; Windows
  # answers S_OK with 0 levels. The proxy corrects that (GameMaker error dialogs).
  # The prefix needs the DLL override d3d11=native,builtin.
  x86_64-w64-mingw32-gcc -shared -O2 -Wall -o "$OUT/d3d11.dll" "$COMPAT/d3d11-proxy.c" "$COMPAT/d3d11-proxy.def"
  # GPTK Wine 7.7 has no WINHTTP_OPTION_URL. libHttpClient asks for it in each
  # request and closes the request without it (Xbox Live calls of the game fail).
  # Before Wine 11.4, it also refuses WINHTTP_OPTION_DECOMPRESSION on a request
  # (Disney Speedstorm); the proxy accepts it. iOdus adds it to the Wine 11.0 runtimes too.
  # The prefix needs the DLL override winhttp=native,builtin.
  x86_64-w64-mingw32-gcc -shared -O2 -Wall -o "$OUT/winhttp.dll" "$COMPAT/winhttp-proxy.c" "$COMPAT/winhttp-proxy.def"
  # The d3d12.dll layer for D3DMetal 4 (Highball, GPL-3.0), for
  # make-d3dmetal4-runtime.sh. Wine loads it as a builtin, so it gets the marker.
  x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o "$OUT/highball-d3d12-shim.dll" \
    "$COMPAT/highball-d3d12-shim.c" "$COMPAT/highball-d3d12-shim.def"
  $X86 "$BUILD/tools/winebuild/winebuild" --builtin "$OUT/highball-d3d12-shim.dll"
  # The PlayFab save proxy (Xodus Nexus, MIT). iodus-wine-launch puts it in front
  # of a game's PlayFabGameSave.dll; it is never copied into a prefix.
  mkdir -p "$OUT/compat"
  x86_64-w64-mingw32-gcc -shared -O2 -Wall -Wextra -Wl,--no-insert-timestamp -o "$OUT/compat/PlayFabGameSave.dll" \
    "$COMPAT/nexus-playfab-save-folder.c" "$COMPAT/nexus-playfab-session.c" "$COMPAT/nexus-playfab-save-folder.def"
  for f in "$OUT"/*.dll "$OUT"/compat/*.dll; do
    file -b "$f" | grep -q "PE32+ executable.*x86-64" || { echo "Not a 64-bit Windows DLL: $f" >&2; exit 1; }
  done
  echo "== Done"
  ls -l "$OUT"
}

case "$RESUME" in
  "") prepare_sources; configure_and_build ;;
  configure) configure_and_build ;;
  *) echo "Unknown RESUME value: $RESUME" >&2; exit 1 ;;
esac
