#!/bin/sh
#
# KPM uninstall hook. KPM deletes the package directory itself; we only clean up
# what install.sh dropped outside of it.

KUAL_DIR="/mnt/us/extensions/claudeusage"
DATA_DIR="/mnt/us/claudeusage"

if [ "$1" = "upgrade" ]; then
    # Keep the KUAL shim and the data in place across upgrades.
    exit 0
fi

if [ -d "$KUAL_DIR" ]; then
    rm -rf "$KUAL_DIR"
    echo "removed the KUAL entry"
fi

# The encrypted token and the usage history are NOT deleted - removing an app
# should not silently destroy user data. Say so instead.
if [ -d "$DATA_DIR" ]; then
    echo "your data was kept at $DATA_DIR - delete it manually to wipe the stored token"
fi

exit 0
