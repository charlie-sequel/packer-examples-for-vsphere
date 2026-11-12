#!/bin/bash
# Installs (or reinstalls) the weekly LaunchAgent that runs sync-upstream.sh --open-pr,
# pushing a sync branch + opening a GitHub PR when vmware/packer-examples-for-vsphere
# (develop branch) has updates. Idempotent — safe to re-run.
#
#   ./install-autosync.sh            install, weekly Monday 09:15 local
#   ./install-autosync.sh --uninstall  remove the LaunchAgent
set -euo pipefail

LABEL="com.sds.vsphere-packer-sync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/sync-upstream.sh"
LOG="$HOME/Library/Logs/sds-vsphere-packer-sync.log"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled $LABEL."
  exit 0
fi

chmod +x "$SCRIPT"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
        <string>--open-pr</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>1</integer>
        <key>Hour</key><integer>9</integer>
        <key>Minute</key><integer>15</integer>
    </dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

# Reload (modern bootstrap, with legacy fallback).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"

echo "Installed LaunchAgent '$LABEL' — runs weekly (Mon 09:15 local), opens a PR on new upstream commits."
echo "  Script : $SCRIPT --open-pr"
echo "  Log    : $LOG"
echo "  Test   : bash $SCRIPT --open-pr"
echo "  Remove : ./install-autosync.sh --uninstall"
