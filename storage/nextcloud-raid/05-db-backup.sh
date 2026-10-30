#!/usr/bin/env bash
# Sets up the daily MariaDB dump, on a different filesystem than the live database.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

KEEP=14

need_sudo
mountpoint -q "$MOUNT" || die "$MOUNT is not mounted. Run 03-create-array.sh first."

sudo install -d -m 700 -o root -g root "$DB_BACKUP_DIR"
backup_fs=$(df --output=target "$DB_BACKUP_DIR" | tail -1)
[[ $backup_fs != "$MOUNT" ]] \
    || die "$DB_BACKUP_DIR is on the array, so it would only back up itself."

echo "== Dump script =="
# No password on the host: the variables expand only inside the db container, never on a command line.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
sed -e "s|@MOUNT@|$MOUNT|g" -e "s|@BACKUP@|$DB_BACKUP_DIR|g" \
    -e "s|@USER@|$NC_USER|g" -e "s|@UID@|$NC_UID|g" -e "s|@KEEP1@|$((KEEP + 1))|g" \
    > "$tmp" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mountpoint -q @MOUNT@ || { echo "@MOUNT@ not mounted" >&2; exit 1; }
cd /
nc() { runuser -u @USER@ -- env XDG_RUNTIME_DIR=/run/user/@UID@ podman "$@"; }
c=$(nc ps -q --filter label=com.docker.compose.service=db | head -1)
[[ -n $c ]] || { echo "db container not found" >&2; exit 1; }
out=@BACKUP@/nextcloud-db-$(date +%Y%m%d-%H%M%S).sql.zst
nc exec "$c" sh -c 'MYSQL_PWD="$MYSQL_PASSWORD" exec mariadb-dump --single-transaction --quick --routines --events --triggers --default-character-set=utf8mb4 -u "$MYSQL_USER" "$MYSQL_DATABASE"' \
    | zstd -q -10 -T0 -o "$out.tmp"
zstd -dc "$out.tmp" | tail -1 | grep -q 'Dump completed' || { rm -f "$out.tmp"; echo "dump incomplete" >&2; exit 1; }
mv "$out.tmp" "$out"
ls -1t @BACKUP@/nextcloud-db-*.sql.zst | tail -n +@KEEP1@ | xargs -r rm -f --
SCRIPT
sudo install -m 700 -o root -g root "$tmp" /usr/local/sbin/nc-db-dump.sh
sudo bash -n /usr/local/sbin/nc-db-dump.sh

echo "== Systemd units =="
sudo tee /etc/systemd/system/nextcloud-db-dump.service >/dev/null <<UNIT
[Unit]
Description=Nextcloud MariaDB dump
RequiresMountsFor=$MOUNT
After=user@$NC_UID.service

[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/local/sbin/nc-db-dump.sh
UNIT

sudo tee /etc/systemd/system/nextcloud-db-dump.timer >/dev/null <<'UNIT'
[Unit]
Description=Daily Nextcloud database dump

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-db-dump.timer

echo "== Test run =="
if ! sudo systemctl start nextcloud-db-dump.service; then
    sudo journalctl -u nextcloud-db-dump.service -n 20 --no-pager
    die "Test run failed."
fi
# root must expand the glob; admin cannot read the directory.
sudo sh -c "for f in $DB_BACKUP_DIR/nextcloud-db-*.sql.zst; do echo \"\$f: \$(zstd -dc \"\$f\" | tail -1)\"; done"
echo
systemctl list-timers nextcloud-db-dump.timer --no-pager
