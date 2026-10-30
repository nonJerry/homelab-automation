# Shared constants and checks, sourced by every script.

MD_NAME=data
MD_DEV=/dev/md/$MD_NAME
LUKS_NAME=data-crypt
LUKS_DEV=/dev/mapper/$LUKS_NAME
KEYFILE=/etc/cryptsetup-keys.d/$LUKS_NAME.key
HEADER_BACKUP=/root/$LUKS_NAME-luks-header.img

# Expected size of the new disks in GB, with tolerance in percent.
DISK_SIZE_GB=${DISK_SIZE_GB:-}
DISK_SIZE_TOLERANCE_PCT=3

MOUNT=/srv/data
DATA_DIR=$MOUNT/nextcloud
DB_DIR=$MOUNT/db

# Dumps deliberately live off the array: RAID does not protect against filesystem errors or rm.
DB_BACKUP_DIR=/var/backups/nextcloud

NC_USER=nextcloud
NC_UID=$(id -u "$NC_USER")
COMPOSE=/opt/nextcloud/compose.yaml
UNIT=podman-compose@nextcloud.service

# Recipient for mdadm failure alerts. Empty = no notification.
MAILADDR=""

die() { echo "ERROR: $*" >&2; exit 1; }

confirm() {
    local answer
    read -r -p "$1 [type YES]: " answer
    [[ $answer == YES ]] || die "Aborted."
}

# Authenticate up front so background processes do not compete for the terminal.
need_sudo() {
    sudo -v || die "sudo authentication failed."
}

# cd / because the service user may not enter the caller's working directory.
nc_podman() {
    ( cd / && sudo runuser -u "$NC_USER" -- \
        env XDG_RUNTIME_DIR="/run/user/$NC_UID" podman "$@" )
}

# podman-compose prefixes the volume name with the project name; ask podman instead of guessing.
volume_path() {
    local v=$1 p name
    for name in "$v" "nextcloud_$v" "nextcloud-$v"; do
        p=$(nc_podman volume inspect "$name" --format '{{.Mountpoint}}' 2>/dev/null) || continue
        [[ -n $p ]] && { echo "$p"; return 0; }
    done
    return 1
}

size_matches() {
    [[ -n $DISK_SIZE_GB ]] || die "Set DISK_SIZE_GB, e.g. DISK_SIZE_GB=2000 $0"
    local bytes=$1 want=$((DISK_SIZE_GB * 1000000000)) tol
    tol=$((want / 100 * DISK_SIZE_TOLERANCE_PCT))
    (( bytes > want - tol && bytes < want + tol ))
}

# Refuses anything but an unused SATA disk of the expected size, to avoid wiping the wrong device.
require_blank_disk() {
    local dev=$1 base size
    base=$(basename "$dev")

    [[ $dev == /dev/sd[a-z] ]] || die "$dev is not a whole SATA device (expected /dev/sdX)."
    [[ -b $dev ]] || die "$dev does not exist."

    size=$(sudo blockdev --getsize64 "$dev") || die "$dev is not readable."
    size_matches "$size" \
        || die "$dev is $((size/1000000000)) GB, expected ~$DISK_SIZE_GB GB."

    [[ -n $(lsblk -no MOUNTPOINT "$dev" | tr -d ' \n') ]] \
        && die "$dev or one of its partitions is mounted."

    grep -qE "\b${base}[0-9]*\b" /proc/mdstat \
        && die "$dev already belongs to an md array."

    # Without sudo pvs sees nothing and the check would be useless.
    sudo pvs --noheadings -o pv_name 2>/dev/null | grep -qE "/dev/${base}[0-9]*\$" \
        && die "$dev is an LVM physical volume."

    return 0
}
