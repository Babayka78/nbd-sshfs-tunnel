#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <disk_id>"
    echo "Example: $0 disk4"
    echo "Example: $0 /dev/disk4"
    exit 1
fi

DISK_ID="${1#/dev/}"
FS_TYPE="${2:-unknown}"

# Load config if exists, else use defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_HOST="pi"
LINUX_USER="pi"
if [ -f "$SCRIPT_DIR/tunnel.conf" ]; then
    source "$SCRIPT_DIR/tunnel.conf"
fi

# Select mount name based on filesystem
if [ "$FS_TYPE" = "ntfs" ]; then
    MOUNT_NAME="USB_NTFS"
elif [[ "$FS_TYPE" =~ ^ext[234]$ ]]; then
    UPPER_FS=$(echo "$FS_TYPE" | tr '[:lower:]' '[:upper:]')
    MOUNT_NAME="USB_${UPPER_FS}"
else
    MOUNT_NAME="USB_Drive"
fi

# Mount in a hidden folder in the home directory to avoid clutter,
# and to avoid requiring sudo for creating a folder in /Volumes.
# In Finder, this disk will still appear as "$MOUNT_NAME".
MOUNT_DIR="$HOME/.usb_mounts/$MOUNT_NAME"

# Atomic Lock.
# When launched from detector, the folder is already created.
# On manual launch, we create it; if it exists, it's a duplicate run.
LOCKFILE="/tmp/mount_nbd_${DISK_ID}.lock"
if [ -z "${FROM_DETECTOR:-}" ]; then
    if ! mkdir "$LOCKFILE" 2>/dev/null; then
        echo "❌ An active process already exists for /dev/$DISK_ID."
        exit 1
    fi
fi

# Cleanup: runs on any exit. Must never fail partway through.
cleanup() {
    trap - EXIT INT TERM  # prevent recursive re-entry if a new signal arrives during cleanup
    set +e  # CRITICAL: never let a failed command abort cleanup
    echo "Cleanup..."
    # 1. Unmount FUSE on Mac
    diskutil unmount force "$MOUNT_DIR" 2>/dev/null
    umount -f "$MOUNT_DIR" 2>/dev/null
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    # 2. Unmount and disconnect NBD on Pi
    ssh -o ConnectTimeout=3 "${LINUX_USER}@${LINUX_HOST}" 'sudo umount /mnt/mac_usb 2>/dev/null; sudo nbd-client -d /dev/nbd0 2>/dev/null' 2>/dev/null || true
    # 3. Kill the specific nbdkit instance on Mac
    if [ -f "/tmp/nbdkit_${DISK_ID}.pid" ]; then
        PID=$(cat "/tmp/nbdkit_${DISK_ID}.pid" 2>/dev/null)
        if [ -n "${PID:-}" ]; then
            kill "$PID" 2>/dev/null || true
        fi
        rm -f "/tmp/nbdkit_${DISK_ID}.pid" 2>/dev/null || true
    fi
    # 4. Remove askpass helper
    [ -n "${SUDO_ASKPASS:-}" ] && rm -f "$SUDO_ASKPASS" 2>/dev/null || true
    # 5. Kill watchdog
    kill "${WATCHDOG_PID:-}" 2>/dev/null || true
    # 6. Inhibitor: if disk is still physically present, prevent re-trigger.
    #    A background process removes it once the disk disappears.
    if [ -n "$(diskutil info "/dev/$DISK_ID" 2>/dev/null | awk -F': +' '/Device Identifier:/ {print $2}')" ]; then
        touch "/tmp/usb_inhibit_${DISK_ID}"
        ( 
          while [ -n "$(diskutil info "/dev/$DISK_ID" 2>/dev/null | awk -F': +' '/Device Identifier:/ {print $2}')" ]; do 
              sleep 2
          done
          rm -f "/tmp/usb_inhibit_${DISK_ID}"
        ) &
    fi
    # 7. ALWAYS remove lockfile — this line MUST execute
    rm -rf "$LOCKFILE"
    set -e
}
trap cleanup EXIT INT TERM

# Check utilities
command -v diskutil >/dev/null || { echo "❌ diskutil not found"; exit 1; }
command -v sshfs >/dev/null || { echo "❌ sshfs not found"; exit 1; }
command -v ssh >/dev/null || { echo "❌ ssh not found"; exit 1; }
command -v nc >/dev/null || { echo "❌ nc not found"; exit 1; }

# Find nbdkit
NBDKIT_BIN="$(command -v nbdkit || true)"
[ -z "$NBDKIT_BIN" ] && [ -x /opt/homebrew/sbin/nbdkit ] && NBDKIT_BIN=/opt/homebrew/sbin/nbdkit
[ -z "$NBDKIT_BIN" ] && [ -x /usr/local/sbin/nbdkit ] && NBDKIT_BIN=/usr/local/sbin/nbdkit
[ -z "${NBDKIT_BIN:-}" ] && { echo "❌ nbdkit not found"; exit 1; }

[ -e "/dev/$DISK_ID" ] || { echo "❌ Disk /dev/$DISK_ID does not exist"; exit 1; }

echo "[0/6] Checking SSH to Raspberry Pi..."
ssh -o ConnectTimeout=3 "${LINUX_USER}@${LINUX_HOST}" true || { echo "❌ No SSH access to ${LINUX_HOST}"; exit 1; }

# Determine IP via route to Pi (selects the correct interface automatically)
PI_ROUTE_IF=$(route get "$(ssh -o ConnectTimeout=3 -G "${LINUX_USER}@${LINUX_HOST}" | awk '/^hostname / {print $2}')" 2>/dev/null | awk '/interface:/ {print $2}' || true)
if [ -n "$PI_ROUTE_IF" ]; then
    MAC_IP=$(ipconfig getifaddr "$PI_ROUTE_IF" || true)
fi
[ -z "${MAC_IP:-}" ] && MAC_IP=$(ipconfig getifaddr en0 || true)
[ -z "${MAC_IP:-}" ] && MAC_IP=$(ifconfig | awk '/inet / && !/127.0.0.1/ {print $2}' | head -n 1)
[ -z "${MAC_IP:-}" ] && { echo "❌ Failed to determine Mac IP address"; exit 1; }

echo "[1/6] Unmounting disk natively on macOS..."
if ! diskutil unmountDisk "/dev/$DISK_ID"; then
    echo "❌ Failed to unmount /dev/$DISK_ID. Is the disk busy?"
    exit 1
fi

echo "[2/6] Launching nbdkit in background (GUI password prompt if needed)..."
# Configure graphic AskPass for Sudo to avoid hanging in background (for launchd)
SUDO_ASKPASS="/tmp/askpass_nbdkit_${DISK_ID}.sh"
echo '#!/bin/bash' > "$SUDO_ASKPASS"
echo 'osascript -e "text returned of (display dialog \"Please enter your macOS password to grant raw access to the USB drive for tunneling to '"${LINUX_HOST}"'.\" default answer \"\" with hidden answer with title \"NBD-SSHFS Tunnel\")"' >> "$SUDO_ASKPASS"
chmod +x "$SUDO_ASKPASS"
export SUDO_ASKPASS

# Launch nbdkit via root helper. 
# The helper will monitor our process ($$) and kill nbdkit when we exit.
# This eliminates the need to enter a password when ejecting the drive!
sudo -A sh -c '
    NBDKIT_BIN="$1"
    PIDFILE="$2"
    DISK="$3"
    PARENT_PID="$4"
    BIND_IP="$5"
    
    # Run nbdkit bound only to the interface facing Pi — not exposed to all networks.
    "$NBDKIT_BIN" -P "$PIDFILE" -p 10810 -i "$BIND_IP" file "$DISK"
    
    # Wait until parent bash script dies
    while kill -0 "$PARENT_PID" 2>/dev/null; do
        sleep 2
    done
    
    # Parent died. Read the actual daemon PID from the file and kill it.
    if [ -f "$PIDFILE" ]; then
        NBDKIT_PID=$(cat "$PIDFILE" 2>/dev/null)
        [ -n "$NBDKIT_PID" ] && kill "$NBDKIT_PID" 2>/dev/null
        rm -f "$PIDFILE" 2>/dev/null
    fi
' _ "$NBDKIT_BIN" "/tmp/nbdkit_${DISK_ID}.pid" "/dev/$DISK_ID" "$$" "$MAC_IP" &

# Wait for the port to open (user may take up to 60 seconds to enter password)
echo "Waiting for password input..."
for i in {1..30}; do
    if nc -z "$MAC_IP" 10810 2>/dev/null; then
        break
    fi
    sleep 2
done

# Check port
nc -z "$MAC_IP" 10810 || { echo "❌ nbdkit failed to start in time or incorrect password."; exit 1; }

echo "[3/6] Connecting Raspberry Pi via NBD..."
ssh "${LINUX_USER}@${LINUX_HOST}" "sudo nbd-client -t 120 $MAC_IP 10810 /dev/nbd0"

echo "[4/6] Auto-detecting and mounting partition on Raspberry Pi..."
ssh -T "${LINUX_USER}@${LINUX_HOST}" bash << 'EOF'
set -euo pipefail
sudo mkdir -p /mnt/mac_usb

# Give Linux kernel time to read partition table and create /dev/nbd0p1
sleep 4

# Auto-search: find the first partition with any filesystem (FSTYPE)
TARGET_PART=$(lsblk -ln -o NAME,FSTYPE /dev/nbd0 | awk '$2 != "" {print "/dev/"$1; exit}')

if [ -z "${TARGET_PART:-}" ]; then
    echo "No FS partitions found via lsblk, trying the raw disk"
    TARGET_PART="/dev/nbd0"
fi

TARGET_FS=$(sudo blkid -s TYPE -o value "$TARGET_PART" || true)
echo "Mounting node $TARGET_PART (FS: ${TARGET_FS:-unknown})"

    case "$TARGET_FS" in
        ntfs)
            sudo mount -t ntfs-3g -o big_writes "$TARGET_PART" /mnt/mac_usb
            ;;
        *)
            # For ext2, ext3, ext4 and other Linux FS, umask is not supported.
            # Mount normally, then grant full permissions to the root, 
            # so the Mac user can freely write files via SSHFS.
            sudo mount "$TARGET_PART" /mnt/mac_usb
            sudo chmod 777 /mnt/mac_usb 2>/dev/null || true
            ;;
    esac
EOF

echo "[5/6] Mounting back to Mac via SSHFS..."
mkdir -p "$MOUNT_DIR"

echo "==========================================="
echo "✅ Device /dev/$DISK_ID successfully tunneled!"
echo "It should appear in the Finder sidebar as a local disk ($MOUNT_NAME)!"
echo "You can click 'Eject', or simply physically pull out the flash drive —"
echo "the built-in Watchdog will notice and clean everything up automatically."
echo "==========================================="

# Launch watchdog: detect physical removal even when /dev node lingers
(
    while true; do
        sleep 2
        # diskutil returns empty Device Identifier for a ghost device node
        DI=$(diskutil info "/dev/$DISK_ID" 2>/dev/null | awk -F': +' '/Device Identifier:/ {print $2}')
        if [ -z "$DI" ]; then
            echo "Disk physically removed! Cleaning up..."
            kill -TERM $$ 2>/dev/null || true
            exit 0
        fi
    done
) &
WATCHDOG_PID=$!

# Added -o local flag so the disk is treated as native by the system
# and is guaranteed to appear in Finder sidebar with an Eject button.
# Mounted with maximum local network optimizations:
# - Ciphers=aes128-gcm@openssh.com (fastest algorithm with hardware acceleration)
# - auto_cache, defer_permissions (reduces minor checks overhead)
# - noappledouble (prevents mac from littering ._ and .DS_Store files which slow down sshfs)
sshfs "${LINUX_USER}@${LINUX_HOST}:/mnt/mac_usb" "$MOUNT_DIR" \
    -o volname="$MOUNT_NAME" \
    -o local \
    -o reconnect \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o Ciphers=aes128-gcm@openssh.com \
    -o auto_cache \
    -o defer_permissions \
    -o noappledouble \
    -o max_read=1048576 \
    -o max_write=1048576 \
    -f &
SSHFS_PID=$!
wait $SSHFS_PID
