#!/usr/bin/env bash
# Acceptance test: uses fio to check whether the disks have DRAM, then starts
# the long SMART self-test. The fio run erases all data on the devices.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

(( $# == 2 )) || die "Usage: $0 /dev/sdX /dev/sdY"
DISK1=$1 DISK2=$2
[[ $DISK1 != "$DISK2" ]] || die "Same device given twice."
command -v fio >/dev/null \
    || die "fio is missing. Install it just for this test (sudo dnf install fio) and remove it afterwards."

need_sudo
require_blank_disk "$DISK1"
require_blank_disk "$DISK2"

lsblk -d -o NAME,SIZE,MODEL,SERIAL "$DISK1" "$DISK2"
echo
echo "15 minutes of random 4K writes on both disks in parallel. Start this in tmux."
confirm "ALL DATA on $DISK1 and $DISK2 will be overwritten. Continue?"

# Random writes across the whole disk expose DRAM-less drives; sequential writes would hide it.
pids=()
for d in "$DISK1" "$DISK2"; do
    sudo fio --name="dramcheck-$(basename "$d")" --filename="$d" --direct=1 \
        --rw=randwrite --bs=4k --iodepth=32 --ioengine=libaio \
        --runtime=900 --time_based --norandommap --random_generator=lfsr \
        --output="/var/tmp/fio-$(basename "$d").log" &
    pids+=($!)
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
(( rc == 0 )) || die "fio failed, see /var/tmp/fio-*.log"

echo
for d in "$DISK1" "$DISK2"; do
    log=/var/tmp/fio-$(basename "$d").log
    echo "=== $d ==="
    grep -E 'write: IOPS=' "$log"
    grep -E '99\.99th' "$log" || true
done
echo
echo "With DRAM: four-digit IOPS. Without DRAM: a few hundred IOPS with latency spikes."
echo "Both disks should be close to each other."

echo
echo "== Long SMART self-test =="
for d in "$DISK1" "$DISK2"; do
    sudo smartctl -t long "$d" | grep -iE 'minutes|test will complete' || true
done
echo "Leave the server idle meanwhile, then check with:"
echo "  sudo smartctl -l selftest $DISK1"
echo "  sudo smartctl -l selftest $DISK2"
echo "fio is no longer needed: sudo dnf remove fio"
