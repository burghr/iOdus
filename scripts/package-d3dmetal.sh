#!/bin/sh
# Makes a D3DMetal package (D3DMetal 3 or the D3DMetal 4 beta): the "redist"
# folder of Apple's Game Porting Toolkit, unchanged, with Apple's license,
# acknowledgements, and read-me files, and a short notice.
#
# Apple's license allows the free, non-commercial distribution of the Framework
# and of the Redistributables (sections 2A(iii) and 2C), unchanged and with
# Apple's notices. iOdus is free and open source; the package is never sold.
#
# Usage: package-d3dmetal.sh <folder with redist and Apple's .rtf files> <output folder>
#   The input folder: the contents of "Evaluation environment for Windows games
#   4.0 beta N.dmg" from Apple's Game Porting Toolkit 4 download.
set -eu

[ $# -eq 2 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
SRC=$1 OUT=$2
FRAMEWORK="$SRC/redist/lib/external/D3DMetal.framework"
[ -d "$FRAMEWORK" ] || { echo "No redist/lib/external/D3DMetal.framework in $SRC" >&2; exit 1; }
codesign --verify --strict -R='anchor apple' "$FRAMEWORK" || { echo "D3DMetal is not signed by Apple." >&2; exit 1; }
for f in License.rtf Acknowledgements.rtf; do
  [ -f "$SRC/$f" ] || { echo "Missing Apple's $f in $SRC" >&2; exit 1; }
done
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$FRAMEWORK/Versions/A/Resources/Info.plist")
NAME="d3dmetal-$VERSION"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/$NAME"
ditto "$SRC/redist" "$WORK/$NAME/redist"
for f in License.rtf Acknowledgements.rtf "Read Me.rtf"; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$WORK/$NAME/"
done
cat > "$WORK/$NAME/NOTICE.txt" <<EOF
D3DMetal $VERSION from Apple's Game Porting Toolkit (redist folder)

Copyright Apple Inc. All rights reserved.

These files are Apple's software, unchanged. They are distributed free of
charge, for non-commercial use only, under Apple's Software License Agreement
for Game Porting Toolkit (License.rtf), sections 2A(iii) and 2C. They are not
part of iOdus and are not under the iOdus license. Apple's license applies to
every use, including its restrictions: use on Apple-branded hardware only, no
modification, no reverse engineering, and no commercial distribution.

iOdus downloads this package for its D3DMetal 4 beta runtime. In that runtime,
Apple's d3d12.dll is renamed to d3d12_d3dmetal.dll on the player's Mac, with
its content unchanged, so that a separate d3d12.dll layer can load in front of
it.
EOF

# The framework keeps its signature through tar; check it in the package.
codesign --verify --strict -R='anchor apple' "$WORK/$NAME/redist/lib/external/D3DMetal.framework"
mkdir -p "$OUT"
(cd "$WORK" && tar -cJf "$OUT/$NAME.tar.xz" "$NAME")
(cd "$OUT" && shasum -a 256 "$NAME.tar.xz" > "$NAME.tar.xz.sha256")
cat "$OUT/$NAME.tar.xz.sha256"
echo "size $(stat -f %z "$OUT/$NAME.tar.xz")"
