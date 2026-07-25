#!/bin/sh
#
# KPM install hook. Runs from inside the unpacked package directory.
#
# KPM already put the payload (runtime/, app/, bin/) in place; all we add is a
# KUAL shim so the app also shows up in the KUAL menu, and the data directory.
# App data lives OUTSIDE the package so a `kpm upgrade` never wipes the token.

set -e

DATA_DIR="/mnt/us/claudeusage"
KUAL_DIR="/mnt/us/extensions/claudeusage"

mkdir -p "$DATA_DIR"

if [ -d /mnt/us/extensions ]; then
    mkdir -p "$KUAL_DIR/bin"
    # config.xml is what makes KUAL notice the extension at all; menu.json alone
    # is silently ignored.
    cp config.xml "$KUAL_DIR/config.xml"
    cp menu.json "$KUAL_DIR/menu.json"
    # The shim never hardcodes the install path - `kpm launch` resolves it.
    cat > "$KUAL_DIR/bin/claudeusage.sh" <<'EOF'
#!/bin/sh
exec kpm launch claudeusage
EOF
    chmod +x "$KUAL_DIR/bin/claudeusage.sh"
    echo "KUAL entry installed at $KUAL_DIR"
fi

chmod +x bin/claudeusage.sh runtime/luajit 2>/dev/null || true

# One-time import from the retired KOReader plugin.
for f in claudeusage.lua claudeusage_history.lua; do
    if [ -f "/mnt/us/koreader/settings/$f" ] && [ ! -f "$DATA_DIR/$f" ]; then
        cp "/mnt/us/koreader/settings/$f" "$DATA_DIR/$f"
        echo "imported $f from the old KOReader plugin"
    fi
done

echo "Claude Usage installed. Launch from KUAL, or: kpm launch claudeusage"
exit 0
