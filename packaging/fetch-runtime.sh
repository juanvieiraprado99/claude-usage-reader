#!/usr/bin/env bash
#
# Download a KOReader release and extract it as the bundled runtime.
#
#   ./packaging/fetch-runtime.sh [version] [platform]
#
# The platform name doubles as the KPM `supported_platforms` value, so use the
# names KPM knows: kindlehf, kindlepw2, kindle5, kindle.
#
#   kindlepw2  soft-float devices, needs /lib/ld-linux.so.3
#   kindlehf   hard-float devices, needs /lib/ld-linux-armhf.so.3
#
# Picking wrong shows up as `./luajit: not found` in crash.log - that is the
# missing ELF interpreter, not a missing file. The launcher checks for it.
#
# runtime/ is gitignored - it is rebuilt from here and only ships in releases.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Single source of truth for which KOReader release the runtime comes from.
VERSION="${1:-$(cat "$ROOT/packaging/KOREADER_VERSION")}"
PLATFORM="${2:-kindlepw2}"

RUNTIME="$ROOT/runtime"
TMP="$ROOT/.runtime-tmp"

ASSET="koreader-${PLATFORM}-${VERSION}.zip"
URL="https://github.com/koreader/koreader/releases/download/${VERSION}/${ASSET}"

echo "==> fetching $URL"
rm -rf "$TMP" && mkdir -p "$TMP"
curl -fL "$URL" -o "$TMP/$ASSET"

echo "==> extracting"
unzip -q "$TMP/$ASSET" -d "$TMP"

# The tarball unpacks a `koreader/` directory.
SRC="$TMP/koreader"
[ -d "$SRC" ] || { echo "unexpected archive layout in $TMP" >&2; exit 1; }

rm -rf "$RUNTIME"
mv "$SRC" "$RUNTIME"
rm -rf "$TMP"

# build.sh reads these to name the artifacts and fill the KPM manifest.
printf '%s\n' "$PLATFORM" > "$RUNTIME/.platform"
printf '%s\n' "$VERSION" > "$RUNTIME/.koversion"

echo "==> runtime ready at $RUNTIME ($(du -sh "$RUNTIME" | cut -f1), $PLATFORM)"
echo "    next: ./packaging/build.sh  (prunes it and builds the release zip)"
