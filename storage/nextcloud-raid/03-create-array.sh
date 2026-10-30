#!/usr/bin/env bash
# Builds RAID 1 -> LUKS -> XFS and mounts it at $MOUNT.
# Erases all data on the given devices.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

(( $# == 2 )) || die "Usage: $0 /dev/sdX /dev/sdY"
DISK1=$1 DISK2=$2
[[ $DISK1 != "$DISK2" ]] || die "Same device given twice."

need_sudo
require_blank_disk "$DISK1"
require_blank_disk "$DISK2"
[[ -e $MD_DEV ]] && die "$MD_DEV already exists."
[[ -e $LUKS_DEV ]] && die "$LUKS_DEV already exists."
mountpoint -q "$MOUNT" && die "$MOUNT is already mounted."

lsblk -d -o NAME,SIZE,MODEL,SERIAL "$DISK1" "$DISK2"
confirm "Create RAID 1 on $DISK1 + $DISK2 and wipe both completely?"

echo "== Discarding cells =="
# No discard passes through LUKS later; release the burn-in blocks now.
for d in "$DISK1" "$DISK2"; do
    sudo blkdiscard "$d" || echo "WARNING: blkdiscard on $d failed, continuing."
done

echo "== Creating GPT partitions =="
# 100 MiB headroom so a slightly smaller replacement disk still fits the array.
for d in "$DISK1" "$DISK2"; do
    sudo wipefs -a "$d"
    # Without -- parted reads -100MiB as an option.
    sudo parted -s -a optimal "$d" -- mklabel gpt mkpart primary 1MiB -100MiB set 1 raid on
done
sudo udevadm settle

echo "== Creating RAID 1 =="
# mdadm prompts for level 1 ("boot device"); the devices were checked above.
printf 'y\n' | sudo mdadm --create "$MD_DEV" --name="$MD_NAME" --level=1 --raid-devices=2 \
    --metadata=1.2 --bitmap=internal "${DISK1}1" "${DISK2}1"

sudo mdadm --detail --scan "$MD_DEV" | sudo tee -a /etc/mdadm.conf >/dev/null
if [[ -n $MAILADDR ]] && ! sudo grep -q '^MAILADDR' /etc/mdadm.conf; then
    echo "MAILADDR $MAILADDR" | sudo tee -a /etc/mdadm.conf >/dev/null
fi

echo "== Creating LUKS =="
sudo install -d -m 700 -o root -g root /etc/cryptsetup-keys.d
sudo dd if=/dev/urandom of="$KEYFILE" bs=512 count=1 status=none
sudo chmod 400 "$KEYFILE"
sudo chown root:root "$KEYFILE"
sudo cryptsetup luksFormat --type luks2 --batch-mode "$MD_DEV" "$KEYFILE"

# Second keyslot with a passphrase keeps the array readable without the system disk's keyfile.
echo
echo "Now set a passphrase for the array (second keyslot)."
echo "It is the only way to reach the data if the system disk fails."
sudo cryptsetup luksAddKey "$MD_DEV" --key-file "$KEYFILE"

sudo cryptsetup luksHeaderBackup "$MD_DEV" --header-backup-file "$HEADER_BACKUP"
sudo chmod 400 "$HEADER_BACKUP"

sudo cryptsetup open --key-file "$KEYFILE" "$MD_DEV" "$LUKS_NAME"

luks_uuid=$(sudo cryptsetup luksUUID "$MD_DEV")
# No discard: TRIM through LUKS would reveal which blocks are in use.
echo "$LUKS_NAME UUID=$luks_uuid $KEYFILE luks" | sudo tee -a /etc/crypttab >/dev/null

echo "== Filesystem and mount =="
sudo mkfs.xfs -L "$MD_NAME" "$LUKS_DEV"
sudo install -d -m 755 "$MOUNT"
# -p bypasses the blkid cache, which is still stale right after mkfs.
fs_uuid=$(sudo blkid -p -s UUID -o value "$LUKS_DEV")
[[ -n $fs_uuid ]] || die "Could not determine the UUID of the new filesystem."
echo "UUID=$fs_uuid $MOUNT xfs defaults,nofail 0 0" | sudo tee -a /etc/fstab >/dev/null
sudo systemctl daemon-reload
sudo mount "$MOUNT"

sudo install -d -m 755 "$DATA_DIR"
sudo install -d -m 755 "$DB_DIR"

echo "== Making SELinux labels persistent =="
# Policy entry, otherwise a later restorecon resets the bind mounts' labels.
for d in "$DATA_DIR" "$DB_DIR"; do
    sudo semanage fcontext -a -t container_file_t "${d}(/.*)?" 2>/dev/null \
        || sudo semanage fcontext -m -t container_file_t "${d}(/.*)?"
done
sudo restorecon -R "$MOUNT"

echo "== Enforcing boot order =="
# Otherwise the service user's Podman manager starts before the mount and MariaDB creates an empty database.
sudo install -d -m 755 "/etc/systemd/system/user@${NC_UID}.service.d"
printf '[Unit]\nRequiresMountsFor=%s\n' "$MOUNT" \
    | sudo tee "/etc/systemd/system/user@${NC_UID}.service.d/10-nextcloud-mount.conf" >/dev/null
sudo systemctl daemon-reload

echo
echo "== Result =="
cat /proc/mdstat
df -h "$MOUNT"
echo "Used LUKS keyslots (must be two):"
sudo cryptsetup luksDump "$MD_DEV" | grep -E '^  [0-9]+: luks2'
echo
echo "Back up NOW, outside this machine:"
echo "  - the passphrase you just set"
echo "  - $HEADER_BACKUP  (contains both keyslots, as sensitive as the disks)"
echo "  - $KEYFILE"
echo
echo "The initial RAID sync continues in the background; the array is already usable."
echo "Next step: ./04-migrate-nextcloud.sh"
