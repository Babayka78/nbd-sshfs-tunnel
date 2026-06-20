#!/usr/bin/env bash
set -euo pipefail

# Explicit PATH for launchd
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config if exists, else use defaults
LINUX_HOST="pi"
LINUX_USER="pi"
if [ -f "$SCRIPT_DIR/tunnel.conf" ]; then
    source "$SCRIPT_DIR/tunnel.conf"
fi

# Allow macOS a couple of seconds to finish mounting
sleep 2

for vol in /Volumes/*; do
    [ -d "$vol" ] || continue
    
    # Single diskutil info call, cache the result
    INFO=$(diskutil info "$vol" 2>/dev/null) || continue
    
    # Filter out internal disks and disk images
    DEVICE_LOCATION=$(echo "$INFO" | awk -F': ' '/Device Location:/ {gsub(/^[ \t]+/,"",$2); print $2}')
    if [ "$DEVICE_LOCATION" != "External" ]; then
        echo "$(date): SKIP $vol (Location: ${DEVICE_LOCATION:-unknown})" >> /tmp/usb_detector_debug.log
        continue
    fi

    PARENT_DISK=$(echo "$INFO" | awk '/Part of Whole:/ {print $NF}')
    DISK_ID=$(echo "$INFO" | awk '/Device Identifier:/ {print $NF}')

    # Find the FS type that macOS recognized
    FS_TYPE=$(echo "$INFO" | awk -F': ' '/File System Personality:/ {gsub(/^[ \t]+/,"",$2); print $2}' | tr '[:upper:]' '[:lower:]')

    if [[ "$FS_TYPE" != "ntfs" ]]; then
        echo "$(date): SKIP $vol (FS: ${FS_TYPE:-empty}, auto-mode handles NTFS only)" >> /tmp/usb_detector_debug.log
        continue
    fi
    
    TARGET_DISK="${PARENT_DISK:-$DISK_ID}"
    [ -z "$TARGET_DISK" ] && continue

    # Inhibitor check: after a clean Eject the mount script leaves a marker.
    # While the disk is still physically in the port, we skip it.
    # Once the disk is removed and re-inserted, the marker is stale — remove it.
    INHIBIT_FILE="/tmp/usb_inhibit_${TARGET_DISK}"
    if [ -f "$INHIBIT_FILE" ]; then
        if [ -e "/dev/$TARGET_DISK" ]; then
            echo "$(date): SKIP $vol (inhibited after Eject, disk still in port)" >> /tmp/usb_detector_debug.log
            continue
        else
            rm -f "$INHIBIT_FILE"
        fi
    fi
    
    # --- Self-healing: clean up stale state from a previous crashed run ---
    LOCKDIR="/tmp/mount_nbd_${TARGET_DISK}.lock"
    if [ -d "$LOCKDIR" ]; then
        # Lock exists. Is the tunnel actually alive?
        if mount | grep -qE ".*:/mnt/mac_usb on .*/\.usb_mounts/USB_"; then
            # Tunnel is alive — this is a genuine active session, skip.
            echo "$(date): SKIP $vol (tunnel active)" >> /tmp/usb_detector_debug.log
            continue
        fi
        # Tunnel is dead but lock survived — stale state. Clean up.
        echo "$(date): Stale lock for $TARGET_DISK found. Cleaning up..." >> /tmp/usb_detector_debug.log
        
        # Kill zombie nbdkit if PID file exists
        if [ -f "/tmp/nbdkit_${TARGET_DISK}.pid" ]; then
            PID=$(cat "/tmp/nbdkit_${TARGET_DISK}.pid" 2>/dev/null)
            if [ -n "${PID:-}" ]; then
                sudo -n kill "$PID" 2>/dev/null || true
            fi
        fi
        
        # Kill any lingering sshfs/umount
        umount -f ~/.usb_mounts/USB_* 2>/dev/null || true
        # Clean up Pi side (best effort)
        ssh -o ConnectTimeout=3 "${LINUX_USER}@${LINUX_HOST}" 'sudo umount /mnt/mac_usb 2>/dev/null; sudo nbd-client -d /dev/nbd0 2>/dev/null' 2>/dev/null || true
        
        # Remove stale lock and inhibitor
        rm -rf "$LOCKDIR" "/tmp/usb_inhibit_${TARGET_DISK}"
        echo "$(date): Stale state cleaned for $TARGET_DISK" >> /tmp/usb_detector_debug.log
    fi
    
    # Atomic lock — only one detector instance proceeds per disk
    if mkdir "$LOCKDIR" 2>/dev/null; then
        # Clear old logs and errors to ensure files relate only to the current session
        > /tmp/usb_detector.log
        > /tmp/usb_detector_debug.log
        rm -f /tmp/*.err 2>/dev/null || true
        
        echo "$(date): Detected $FS_TYPE on $TARGET_DISK. Launching mount script..." >> /tmp/usb_detector.log
        FROM_DETECTOR=1 nohup "$SCRIPT_DIR/mount_tunnel.sh" "$TARGET_DISK" "$FS_TYPE" > "/tmp/mount_${TARGET_DISK}.log" 2>&1 &
    fi
done
