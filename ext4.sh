#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Manual Linux Disk (ext4) Mount Launcher ==="
echo "Searching for connected disks..."

DISK_ID=$(diskutil list external physical | grep -oE "disk[0-9]+$" | head -n 1)

if [ -z "$DISK_ID" ]; then
    echo "❌ Error: No external disks found. Please insert a drive and try again."
    exit 1
fi

echo "✅ Found external disk: /dev/$DISK_ID"
echo "🚀 Launching tunnel via Raspberry Pi..."

# Launch the main tunnel script, hardcoding the FS type as ext4
nohup "$SCRIPT_DIR/mount_tunnel.sh" "$DISK_ID" ext4 > /tmp/manual_mount.log 2>&1 &

echo "✅ Command dispatched! Please wait for the password prompt (it may appear in the background)."
