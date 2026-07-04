#!/bin/bash
# amber-cool daemon installer. Installs fanctl + a root LaunchDaemon that holds
# the configured fan mode (default: full blast), surviving reboot/sleep/crash.
#
# Build first, then run as root:
#   swift build -c release && sudo ./daemon/install.sh [initial-mode]
# initial-mode examples: "max" (default), "scale 7", "rpm 4000", "temp 65"
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo ./daemon/install.sh"; exit 1; fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BIN_SRC="$REPO_DIR/.build/release/fanctl"
PLIST_SRC="$SCRIPT_DIR/co.welf.amber-cool.plist"
PLIST_DST="/Library/LaunchDaemons/co.welf.amber-cool.plist"
MODE="${1:-}"
# Carry over the mode from a pre-rename amber-temp install unless one was given explicitly.
if [[ -z "$MODE" && -f /usr/local/etc/amber-temp/mode ]]; then
    MODE="$(cat /usr/local/etc/amber-temp/mode)"
fi
MODE="${MODE:-max}"

if [[ ! -x "$BIN_SRC" ]]; then
    echo "Missing $BIN_SRC — run 'swift build -c release' first."; exit 1
fi

echo "==> Stopping conflicting fan controllers (they fight over the SMC)..."
killall "Macs Fan Control" 2>/dev/null || true
killall "FanBar" 2>/dev/null || true

# Migrate: remove the pre-rename amber-temp daemon — two daemons would fight over the SMC.
if [[ -f /Library/LaunchDaemons/co.welf.amber-temp.plist ]]; then
    echo "==> Removing pre-rename amber-temp daemon"
    launchctl bootout system /Library/LaunchDaemons/co.welf.amber-temp.plist 2>/dev/null || true
    rm -f /Library/LaunchDaemons/co.welf.amber-temp.plist
fi

echo "==> Installing fanctl -> /usr/local/bin/fanctl"
install -d -m 755 /usr/local/bin /usr/local/etc/amber-cool /usr/local/var/log
install -m 755 "$BIN_SRC" /usr/local/bin/fanctl

echo "==> Writing initial mode: '$MODE'"
printf '%s\n' "$MODE" > /usr/local/etc/amber-cool/mode
# Make the mode file writable by the logged-in user so the menu bar app can change modes without root.
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null || echo root)"
chown "$CONSOLE_USER" /usr/local/etc/amber-cool/mode 2>/dev/null || true
chmod 666 /usr/local/etc/amber-cool/mode   # any user process (the menu bar app) can update the mode in place

echo "==> Installing LaunchDaemon"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "==> (Re)loading daemon"
launchctl bootout system "$PLIST_DST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DST"
launchctl enable system/co.welf.amber-cool 2>/dev/null || true

sleep 3
echo "==> Status:"
/usr/local/bin/fanctl read || true
echo
echo "Done. amber-cool is running in mode '$MODE'."
echo "Change mode any time:  echo 'scale 7' | sudo tee /usr/local/etc/amber-cool/mode"
echo "Stop & restore auto:   sudo ./daemon/uninstall.sh"
