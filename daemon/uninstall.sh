#!/bin/bash
# amber-cool daemon uninstaller. Stops the daemon, restores macOS automatic fan
# control, and removes installed files. Run as root: sudo ./daemon/uninstall.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo ./daemon/uninstall.sh"; exit 1; fi

PLIST_DST="/Library/LaunchDaemons/co.welf.amber-cool.plist"

echo "==> Stopping daemon"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true

echo "==> Restoring macOS automatic fan control"
/usr/local/bin/fanctl auto 2>/dev/null || true

echo "==> Removing files"
rm -f "$PLIST_DST"
rm -f /usr/local/bin/fanctl
rm -rf /usr/local/etc/amber-cool

echo "Done. Fans are back under macOS control."
