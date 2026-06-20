#!/usr/bin/env bash
set -euo pipefail

DATETIME=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="/tmp/test_result_${DATETIME}.log"

# Group all output and redirect it to the log file
{
    echo "=== Pi Tunnel Verification ==="
    
    MOUNT_LINE=$(mount | grep -E '\.usb_mounts' | tail -n 1 || true)
    if [ -z "$MOUNT_LINE" ]; then
        echo "[ FAIL ] No active Pi tunnels found."
    else
        MOUNT_PATH=$(echo "$MOUNT_LINE" | awk '{print $3}')
        echo "[ OK ] Tunnel detected: $MOUNT_PATH"

        echo -e "\n=== Testing Disk Access ==="
        TEST_FILE="$MOUNT_PATH/.test_write_${DATETIME}"
        
        if touch "$TEST_FILE" 2>/dev/null; then
            if rm -f "$TEST_FILE" 2>/dev/null; then
                echo "[ OK ] Write access verified (test file created and removed successfully)."
            else
                echo "[ WARN ] Write access verified, but failed to remove test file (possible filesystem permissions error)."
            fi
        else
            echo "[ FAIL ] Disk is Read-Only or inaccessible."
        fi
    fi

    echo -e "\n=== Checking System Logs (/tmp) ==="
    
    LOG_FILES=(/tmp/usb_detector*.log /tmp/mount_*.log /tmp/manual_mount.log)
    FOUND_LOGS=0
    for f in "${LOG_FILES[@]}"; do
        if [ -e "$f" ]; then
            FOUND_LOGS=1
            echo "[ INFO ] Content of $f:"
            echo "----------------------------------------"
            tail -n 15 "$f"
            echo "----------------------------------------"
        fi
    done
    if [ "$FOUND_LOGS" -eq 0 ]; then
        echo "[ INFO ] No .log files found."
    fi

    if ls /tmp/*.err 1>/dev/null 2>&1; then
        for f in /tmp/*.err; do
            if [ -s "$f" ]; then
                echo "[ WARN ] Error file found: $f"
            fi
        done
    else
        echo "[ OK ] No .err files found."
    fi

    if ls /tmp/nbdkit_*.pid /tmp/mount_nbd_*.lock 1>/dev/null 2>&1; then
        echo "[ WARN ] Active PIDs or locks detected:"
        ls -ld /tmp/nbdkit_*.pid /tmp/mount_nbd_*.lock 2>/dev/null || true
    else
        echo "[ OK ] No active PIDs or locks found."
    fi

} > "$LOG_FILE" 2>&1

# Print the log contents to the console at the very end
cat "$LOG_FILE"
echo -e "\n[ INFO ] Test results saved to: $LOG_FILE"
