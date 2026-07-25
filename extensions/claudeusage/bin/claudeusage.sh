#!/bin/sh
#
# Claude Usage - KUAL launcher.
#
# Runs the app on the bundled KOReader runtime. Nothing outside this extension
# directory is required: runtime/ ships its own luajit, .so libs, fonts and
# frontend/.
#
# The Kindle-specific handling below is lifted from runtime/koreader.sh - keep
# the two in sync when bumping the bundled runtime.

export LC_ALL="en_US.UTF-8"

# /mnt/us is vfat+fuse: a script running from there can break under it. KOReader
# works around this by re-exec'ing a copy from /var/tmp, so do the same. The
# extension path travels in the environment because $0 changes after the copy.
if [ "$(dirname "$0")" != "/var/tmp" ]; then
    CU_EXT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    export CU_EXT_DIR
    cp -pf "$0" /var/tmp/claudeusage.sh
    chmod 777 /var/tmp/claudeusage.sh
    exec /var/tmp/claudeusage.sh "$@"
fi

EXT_DIR="$CU_EXT_DIR"
RUNTIME_DIR="$EXT_DIR/runtime"
APP_DIR="$EXT_DIR/app"
LOG="$EXT_DIR/crash.log"

# Data lives outside the package: a KPM upgrade replaces the whole install
# directory, and that must never take the stored token with it.
if mkdir -p /mnt/us/claudeusage 2>/dev/null; then
    DATA_DIR="/mnt/us/claudeusage"
else
    DATA_DIR="$EXT_DIR/settings"
fi

# Stopping the framework gives us the screen entirely, but restarting it on the
# way out replays the whole Kindle boot animation - several seconds every time
# the app closes. So by default we leave it running and just freeze the window
# manager, which is what KOReader does on FW >= 5.7.2. Flip to "yes" only if the
# status bar or clock manages to repaint over the app.
STOP_FRAMEWORK="no"

# Same vfat workaround for fbink, which we use to report failures on screen.
if [ -f "$RUNTIME_DIR/fbink" ]; then
    cp -pf "$RUNTIME_DIR/fbink" /var/tmp/fbink 2>/dev/null
    chmod 777 /var/tmp/fbink 2>/dev/null
fi

say() {
    if [ -x /var/tmp/fbink ]; then
        /var/tmp/fbink -q -y -4 -- "$1"
    else
        eips 3 20 "$1"
    fi
}

if [ ! -f "$RUNTIME_DIR/luajit" ]; then
    say "Claude Usage: runtime missing"
    exit 1
fi

# A runtime built for the wrong platform fails as a bare "./luajit: not found",
# because it is the ELF interpreter that is missing, not the binary. Catch that
# up front and say something useful instead.
LOADER="$(strings "$RUNTIME_DIR/luajit" 2>/dev/null | grep -m1 '^/lib/ld-linux')"
[ -z "$LOADER" ] && LOADER="$(grep -ao '/lib/ld-linux[a-z0-9.-]*' "$RUNTIME_DIR/luajit" 2>/dev/null | head -n 1)"
if [ -n "$LOADER" ] && [ ! -e "$LOADER" ]; then
    say "Claude Usage: wrong build ($LOADER missing)"
    {
        echo "runtime needs $LOADER, which this device does not have"
        echo "uname -m: $(uname -m)"
        echo "uname -r: $(uname -r)"
        [ -f /etc/prettyversion.txt ] && cat /etc/prettyversion.txt
    } >>"$LOG"
    sleep 3
    exit 1
fi

mkdir -p "$DATA_DIR"

# One-time import from the retired KOReader plugin, so an upgrading user keeps
# the encrypted token, the PIN counter and the 5h history.
for f in claudeusage.lua claudeusage_history.lua; do
    if [ -f "/mnt/us/koreader/settings/$f" ] && [ ! -f "$DATA_DIR/$f" ]; then
        cp "/mnt/us/koreader/settings/$f" "$DATA_DIR/$f"
    fi
done

# The physical keys are locked while the framework owns them.
[ -e /proc/keypad ] && echo unlock >/proc/keypad
[ -e /proc/fiveway ] && echo unlock >/proc/fiveway

# --- Kindle framework -------------------------------------------------------
FRAMEWORK_STOPPED="no"
AWESOME_STOPPED="no"
PILLOW_DISABLED="no"

# Save the current screen either way, so we can hand the user back something
# sensible instead of our last frame.
cat /dev/fb0 >/var/tmp/claudeusage-fb.dump 2>/dev/null

if [ "$STOP_FRAMEWORK" = "yes" ]; then
    lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null \
        && PILLOW_DISABLED="yes"

    # CRITICAL: stopping the framework job sends US a SIGTERM when we were
    # launched from KUAL. Without this trap the launcher dies right here, the
    # app never starts, and the screen is left blank.
    trap "" TERM
    stop lab126_gui >/dev/null 2>&1 && FRAMEWORK_STOPPED="yes"
    usleep 1250000 2>/dev/null || sleep 2   # let the teardown finish
    trap - TERM
else
    # Framework stays up: hide its chrome and freeze the window manager, or the
    # clock and status bar keep repainting on top of us.
    lipc-set-prop com.lab126.pillow disableEnablePillow disable 2>/dev/null \
        && PILLOW_DISABLED="yes"
    killall -STOP awesome 2>/dev/null && AWESOME_STOPPED="yes"
fi

restore_framework() {
    if [ "$FRAMEWORK_STOPPED" = "yes" ]; then
        cd / && start lab126_gui >/dev/null 2>&1
    else
        [ "$AWESOME_STOPPED" = "yes" ] && killall -CONT awesome 2>/dev/null
        if [ -f /var/tmp/claudeusage-fb.dump ]; then
            cat /var/tmp/claudeusage-fb.dump >/dev/fb0 2>/dev/null
        fi
        if [ "$PILLOW_DISABLED" = "yes" ]; then
            lipc-set-prop com.lab126.pillow disableEnablePillow enable 2>/dev/null
            lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home 2>/dev/null
        fi
    fi
    rm -f /var/tmp/claudeusage-fb.dump
}
trap restore_framework EXIT INT TERM

# --- Runtime environment ----------------------------------------------------
export LD_LIBRARY_PATH="$RUNTIME_DIR/libs:$RUNTIME_DIR:$LD_LIBRARY_PATH"
export LUA_PATH="$APP_DIR/?.lua;$RUNTIME_DIR/frontend/?.lua;$RUNTIME_DIR/?.lua;;"
export LUA_CPATH="$RUNTIME_DIR/libs/?.so;;"
export CLAUDEUSAGE_DATA="$DATA_DIR"

# Keep the log bounded, and record both streams - a Lua traceback goes to stderr
# but the KOReader logger writes to stdout.
if [ -f "$LOG" ]; then
    tail -c 200000 "$LOG" >"$LOG.new" 2>/dev/null && mv -f "$LOG.new" "$LOG"
fi
echo "=== $(date) launching claudeusage ===" >>"$LOG"

cd "$RUNTIME_DIR" || exit 1
./luajit "$APP_DIR/app.lua" >>"$LOG" 2>&1
STATUS=$?

if [ "$STATUS" -ne 0 ]; then
    say "Claude Usage failed (exit $STATUS) - see crash.log"
    sleep 3
fi

exit $STATUS
