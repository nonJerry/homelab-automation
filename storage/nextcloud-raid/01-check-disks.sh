#!/usr/bin/env bash
# Read-only: finds the new disks and shows their SMART usage history.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

echo "=== All block devices ==="
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,MOUNTPOINTS
echo

need_sudo

found=0
for sys in /sys/block/sd*; do
    dev=/dev/$(basename "$sys")
    size=$(lsblk -bdno SIZE "$dev" 2>/dev/null) || continue
    [[ -n $size ]] || continue
    size_matches "$size" || continue
    found=$((found + 1))

    echo "=== $dev ($((size/1000000000)) GB) ==="
    sudo smartctl -i "$dev" | grep -E "Device Model|Serial Number|Firmware|User Capacity|Rotation Rate|SATA Version"
    echo "--- Usage history (factory new = single-digit power-on hours) ---"
    sudo smartctl -A "$dev" | grep -E "Power_On_Hours|Power_Cycle_Count|Total_LBAs_Written|Wear_Leveling|Percent" \
        || echo "(no matching SMART attributes found)"
    echo
done

echo "Found $found candidate(s) of ~$DISK_SIZE_GB GB."
(( found == 2 )) || echo "WARNING: expected two disks."
