#!/usr/bin/env bash
#
# Headless smoke test of the app against a real KOReader runtime, in Docker.
# No Kindle, no WSL, no kodev build - works anywhere Docker runs.
#
#   ./packaging/run-docker.sh            # full runtime
#   ./packaging/run-docker.sh --pruned   # after applying prune.txt (what ships)
#
# It boots app/app.lua exactly like the Kindle launcher does, using the Linux
# x86_64 KOReader build, with SDL on the dummy video driver. Boot-order bugs and
# missing requires surface here.
#
# LIMITATION: the container has system libraries of its own, so a .so pruned
# from libs/ can still resolve from /usr/lib and the run passes where the Kindle
# fails (this is exactly how a pruned libzstd slipped through). Treat --pruned
# as a Lua-level check, not proof that libs/ is complete.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KOVER="${KOVER:-v2026.03}"
WORK="$ROOT/.docker-smoke"
PRUNED=0
[ "${1:-}" = "--pruned" ] && PRUNED=1

mkdir -p "$WORK"
TARBALL="$WORK/koreader-linux-x86_64-${KOVER}.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "==> fetching KOReader $KOVER (linux x86_64)"
    curl -fL --progress-bar \
        "https://github.com/koreader/koreader/releases/download/${KOVER}/koreader-linux-x86_64-${KOVER}.tar.xz" \
        -o "$TARBALL"
fi

cat > "$WORK/smoke.sh" <<'INNER'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq xz-utils libsdl3-0 ca-certificates >/dev/null 2>&1 \
  || apt-get install -y -qq xz-utils libsdl2-2.0-0 ca-certificates >/dev/null 2>&1

mkdir -p /opt/ko
tar -xJf /work/*.tar.xz -C /opt/ko
EMU="$(find /opt/ko -maxdepth 3 -name luajit -type f | head -n1 | xargs dirname)"

if [ "$PRUNED" = "1" ]; then
    before=$(du -sm "$EMU" | cut -f1)
    while IFS= read -r line; do
        case "$line" in ''|\#*) continue ;; esac
        rm -rf $EMU/$line
    done < /pkg/prune.txt
    echo "pruned runtime: ${before}M -> $(du -sm "$EMU" | cut -f1)M"
fi

mkdir -p /work/data
export LD_LIBRARY_PATH="$EMU/libs:$EMU:${LD_LIBRARY_PATH:-}"
export LUA_PATH="/app/?.lua;$EMU/frontend/?.lua;$EMU/?.lua;;"
export LUA_CPATH="$EMU/libs/?.so;;"
export CLAUDEUSAGE_DATA="/work/data"
export SDL_VIDEODRIVER=dummy
export EMULATE_READER_W=758
export EMULATE_READER_H=1024
export EMULATE_READER_DPI=212

cd "$EMU"
timeout 25 ./luajit /app/app.lua 2>&1 | grep -vE "^ffi\.(load|findlib)" | tail -40
INNER

echo "==> running smoke test (pruned=$PRUNED)"
MSYS_NO_PATHCONV=1 docker run --rm \
    -e PRUNED="$PRUNED" \
    -v "$WORK:/work" \
    -v "$ROOT/app:/app:ro" \
    -v "$ROOT/packaging:/pkg:ro" \
    debian:trixie-slim sh /work/smoke.sh
