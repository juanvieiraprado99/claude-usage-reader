#!/usr/bin/env bash
#
# Run the app on a KOReader emulator build - the fast iteration loop, no Kindle
# needed. Same environment the Kindle launcher sets up, pointed at the emulator
# runtime instead of the bundled one.
#
#   ./packaging/run-emulator.sh [path/to/koreader-checkout]
#
# Build the emulator once with:
#   git clone https://github.com/koreader/koreader.git
#   cd koreader && ./kodev fetch-thirdparty && ./kodev build
#
# On Windows this must run inside WSL2 (WSLg provides the X/Wayland display).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KOSRC="${1:-$HOME/koreader}"

# kodev names the output dir after the host triplet.
EMU="$(find "$KOSRC" -maxdepth 2 -type d -name koreader -path '*emulator*' | head -n1)"
if [ -z "$EMU" ]; then
    echo "no emulator build under $KOSRC" >&2
    echo "run './kodev build' there first, or pass the checkout path as \$1" >&2
    exit 1
fi

DATA="$ROOT/.emulator-data"
mkdir -p "$DATA"

# Kindle-ish screen. Override to match your device if the layout looks off.
export EMULATE_READER_W="${EMULATE_READER_W:-758}"
export EMULATE_READER_H="${EMULATE_READER_H:-1024}"
export EMULATE_READER_DPI="${EMULATE_READER_DPI:-212}"

export LD_LIBRARY_PATH="$EMU/libs:$EMU:${LD_LIBRARY_PATH:-}"
export LUA_PATH="$ROOT/app/?.lua;$EMU/frontend/?.lua;$EMU/?.lua;;"
export LUA_CPATH="$EMU/libs/?.so;;"
export CLAUDEUSAGE_DATA="$DATA"

echo "==> emulator: $EMU"
echo "==> app data: $DATA"
cd "$EMU"
exec ./luajit "$ROOT/app/app.lua"
