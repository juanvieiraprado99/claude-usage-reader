#!/usr/bin/env bash
#
# Build the installable artifacts:
#
#   ./packaging/fetch-runtime.sh          # once, or when bumping KOReader
#   ./packaging/build.sh                  # -> dist/
#
#   dist/claudeusage-<ver>-<platform>.zip   KUAL extension, unzip into /mnt/us/extensions/
#   dist/claudeusage_<ver>_<platform>.kpkg  KPM package, `;kpm install` / add-repo
#
# APP_VERSION must be three numbers - KPM manifests encode versions as
# [major, minor, patch]. CI sets it to <VERSION>.<run number>; local builds get
# <VERSION>.0.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/runtime"
DIST="$ROOT/dist"
STAGE="$DIST/claudeusage"

[ -d "$RUNTIME" ] || { echo "runtime/ missing - run packaging/fetch-runtime.sh first" >&2; exit 1; }

PLATFORM="$(cat "$RUNTIME/.platform" 2>/dev/null || echo kindlehf)"

APP_VERSION="${APP_VERSION:-$(cat "$ROOT/VERSION" 2>/dev/null).0}"
case "$APP_VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "bad APP_VERSION '$APP_VERSION' - expected major.minor.patch" >&2; exit 1 ;;
esac

echo "==> version $APP_VERSION, platform $PLATFORM"

echo "==> staging"
rm -rf "$DIST"
mkdir -p "$STAGE"
cp -r "$ROOT/extensions/claudeusage/." "$STAGE/"
cp -r "$ROOT/app" "$STAGE/app"
cp -r "$RUNTIME" "$STAGE/runtime"
rm -f "$STAGE/runtime/.platform" "$STAGE/runtime/.koversion"
chmod +x "$STAGE/bin/claudeusage.sh"

echo "==> pruning runtime"
before="$(du -sm "$STAGE/runtime" | cut -f1)"
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    # shellcheck disable=SC2086  # globs in prune.txt are intentional
    rm -rf $STAGE/runtime/$line
done < "$ROOT/packaging/prune.txt"
after="$(du -sm "$STAGE/runtime" | cut -f1)"
echo "    runtime ${before}M -> ${after}M"

# Catch the "pruned a library something still links against" class of bug, which
# only shows up on the device (the Docker smoke test resolves such libs from the
# container's own /usr/lib). Names are read out of the binaries; anything the
# Kindle firmware itself provides is whitelisted.
echo "==> checking libs/ for dangling dependencies"
SYSTEM_LIBS="libc.so libm.so libdl.so libpthread.so librt.so libgcc_s.so libstdc++.so libcrypt.so libutil.so libresolv.so libnsl.so ld-linux"
missing=""
for bin in "$STAGE/runtime/luajit" "$STAGE"/runtime/libs/*.so*; do
    [ -f "$bin" ] || continue
    for dep in $(grep -aoE '\blib[A-Za-z0-9_+-]+\.so(\.[0-9]+)*' "$bin" | sort -u); do
        # A soname may be a prefix of the on-disk name (libfoo.so.0 shipped as
        # libfoo.so.0.4.0), so match on prefix rather than exact filename.
        ls "$STAGE"/runtime/libs/"$dep"* >/dev/null 2>&1 && continue
        skip=0
        for sys in $SYSTEM_LIBS; do
            case "$dep" in "$sys"*) skip=1 ;; esac
        done
        [ "$skip" = 1 ] && continue
        case " $missing " in *" $dep "*) ;; *) missing="$missing $dep" ;; esac
    done
done
if [ -n "$missing" ]; then
    echo "!! possibly pruned but still referenced:$missing" >&2
    echo "   check prune.txt before shipping" >&2
fi

# AGPL-3.0: we redistribute KOReader, so the licence travels with the package.
cp "$ROOT/LICENSE" "$STAGE/LICENSE"

# --- KUAL extension ---------------------------------------------------------
# The staged folder IS the installable artifact - copy it to /mnt/us/extensions/.
# The zip is only for distribution, so a missing `zip` is not fatal.
if command -v zip >/dev/null; then
    ZIP="claudeusage-${APP_VERSION}-${PLATFORM}.zip"
    ( cd "$DIST" && zip -qr "$ZIP" claudeusage )
    echo "==> dist/$ZIP ($(du -sh "$DIST/$ZIP" | cut -f1))"
else
    echo "==> zip not found - skipping the archive, dist/claudeusage/ is ready to copy"
fi

# --- KPM package ------------------------------------------------------------
# kpm-helper.py is fetched on demand rather than vendored, so it tracks KPM.
HELPER="$ROOT/packaging/.kpm-helper.py"
if [ ! -f "$HELPER" ]; then
    echo "==> fetching kpm-helper.py"
    curl -fsSL https://raw.githubusercontent.com/KindleModding/KPM/main/kpm-helper.py -o "$HELPER"
fi

if ! python3 -c "" >/dev/null 2>&1; then
    echo "!! working python3 not found - skipping the .kpkg (the KUAL build is done)" >&2
    ls -1 "$DIST"
    exit 0
fi

echo "==> building .kpkg"
cp "$ROOT/packaging/kpkg/install.sh"   "$STAGE/install.sh"
cp "$ROOT/packaging/kpkg/launch.sh"    "$STAGE/launch.sh"
cp "$ROOT/packaging/kpkg/uninstall.sh" "$STAGE/uninstall.sh"
chmod +x "$STAGE/install.sh" "$STAGE/launch.sh" "$STAGE/uninstall.sh"

sed -e "s/@VERSION@/$(echo "$APP_VERSION" | tr '.' ',')/" \
    -e "s/@PLATFORMS@/\"$PLATFORM\"/" \
    "$ROOT/packaging/kpkg/manifest.json.in" > "$STAGE/manifest.json"

python3 "$HELPER" package pack "$STAGE" "$DIST"

ls -1 "$DIST"
echo
echo "install: copy dist/claudeusage/ into /mnt/us/extensions/ on the Kindle,"
echo "         or serve the .kpkg from a KPM repo and use ';kpm install claudeusage'"
