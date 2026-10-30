#!/usr/bin/env bash
# Moves Nextcloud files and database onto the array and switches Compose
# to bind mounts.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

[[ ${BACKUP_DONE:-} == yes ]] \
    || die "Back up first, then run BACKUP_DONE=yes $0."

need_sudo
mountpoint -q "$MOUNT" || die "$MOUNT is not mounted. Run 03-create-array.sh first."
sudo test -d "$DATA_DIR" || die "$DATA_DIR is missing. Run 03-create-array.sh first."
sudo test -d "$DB_DIR" || die "$DB_DIR is missing. Run 03-create-array.sh first."
[[ -f $COMPOSE ]] || die "$COMPOSE not found."

grep -q '^\s*-\s*nextcloud:/var/www/html\s*$' "$COMPOSE" \
    || die "Volume line 'nextcloud:/var/www/html' missing in $COMPOSE."
grep -q '^\s*-\s*db:/var/lib/mysql\s*$' "$COMPOSE" \
    || die "Volume line 'db:/var/lib/mysql' missing in $COMPOSE."

echo "== Locating volumes =="
OLD_APP=$(volume_path nextcloud) || die "Volume 'nextcloud' not found."
OLD_DB=$(volume_path db) || die "Volume 'db' not found."
echo "  nextcloud -> $OLD_APP"
echo "  db        -> $OLD_DB"
sudo test -d "$OLD_APP" || die "$OLD_APP does not exist."
sudo test -d "$OLD_DB" || die "$OLD_DB does not exist."

# User data must live below the webroot, or it would not move with the volume.
datadir=$(sudo grep -oP "'datadirectory'\s*=>\s*'\K[^']+" "$OLD_APP/config/config.php" || true)
[[ $datadir == /var/www/html/data ]] \
    || die "datadirectory is '$datadir', expected /var/www/html/data. The plan does not fit."

app_bytes=$(sudo du -sb "$OLD_APP" | cut -f1)
db_bytes=$(sudo du -sb "$OLD_DB" | cut -f1)
free_bytes=$(df -B1 --output=avail "$MOUNT" | tail -1)
(( free_bytes > app_bytes + db_bytes )) || die "Not enough space on $MOUNT."

echo
echo "Files:     $OLD_APP  ($((app_bytes/1000000000)) GB)  ->  $DATA_DIR"
echo "Database:  $OLD_DB  ($((db_bytes/1000000000)) GB)  ->  $DB_DIR"
confirm "Stop the Nextcloud stack and move both?"

echo "== Stopping stack =="
sudo systemctl --machine="${NC_USER}@.host" --user stop "$UNIT"

# -HAX and --numeric-ids preserve hard links, ACLs, SELinux labels and the user namespace's sub-UIDs.
migrate() {
    local src=$1 dst=$2 diff_out
    echo "== Copying: $src -> $dst =="
    sudo rsync -aHAX --numeric-ids --info=progress2 "$src/" "$dst/"

    echo "-- Verifying copy --"
    diff_out=$(sudo rsync -naHAX --numeric-ids -i "$src/" "$dst/")
    if [[ -n $diff_out ]]; then
        echo "$diff_out" | head -20
        die "Copy of $src differs. Compose left unchanged."
    fi
    echo "identical."

    # The target directory must belong to the volume's mapped owner.
    sudo chown --reference="$src" "$dst"
    sudo chmod --reference="$src" "$dst"
}

migrate "$OLD_APP" "$DATA_DIR"
migrate "$OLD_DB" "$DB_DIR"

echo "== Switching Compose =="
sudo cp -a "$COMPOSE" "$COMPOSE.pre-bindmount"
# :z for files shared by app and cron, :Z for the database used only by db.
sudo sed -i \
    -e "s|^\(\s*\)-\s*nextcloud:/var/www/html\s*$|\1- $DATA_DIR:/var/www/html:z|" \
    -e "s|^\(\s*\)-\s*db:/var/lib/mysql\s*$|\1- $DB_DIR:/var/lib/mysql:Z|" \
    "$COMPOSE"
grep -nE "var/www/html|var/lib/mysql" "$COMPOSE"

echo "== Starting stack =="
sudo systemctl --machine="${NC_USER}@.host" --user start "$UNIT"

echo "== Waiting for healthy containers (up to 15 minutes) =="
# The first start relabels the bind mounts for SELinux and can take a while.
ok=0
for _ in $(seq 90); do
    status=$(nc_podman ps --format '{{.Names}} {{.Status}}' 2>/dev/null || true)
    app_ok=$(grep -c 'app.*healthy' <<<"$status" || true)
    db_ok=$(grep -c 'db.*healthy' <<<"$status" || true)
    echo "  app=$app_ok db=$db_ok"
    (( app_ok > 0 && db_ok > 0 )) && { ok=1; break; }
    sleep 10
done

echo
echo "== Status =="
sudo systemctl --machine="${NC_USER}@.host" --user --no-pager status "$UNIT" | head -5
nc_podman ps --format '{{.Names}}\t{{.Status}}' || true
df -h "$MOUNT" /home
echo

if (( ok == 0 )); then
    die "Not all containers became healthy. Rollback: restore $COMPOSE.pre-bindmount, restart the unit."
fi

echo "Once Nextcloud works properly in the browser, removing the old volumes frees the space:"
echo "  podman volume rm $(basename "$(dirname "$OLD_APP")") $(basename "$(dirname "$OLD_DB")")"
echo "Until then they are your rollback, together with $COMPOSE.pre-bindmount."
echo
echo "Next step: ./05-db-backup.sh"
