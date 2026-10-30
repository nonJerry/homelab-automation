#!/usr/bin/env bash
# Daily grocy backup to the RAID, 7 generations. Runs on the server as admin.
# Usage: ./grocy-backup.sh [--check|--apply|--revert]
set -euo pipefail

GROCY_USER=grocy
GROCY_UID=1008
MOUNT=/srv/data
BACKUP_DIR=$MOUNT/backup/grocy
KEEP=7

SCRIPT=/usr/local/sbin/grocy-backup.sh
SERVICE=/etc/systemd/system/grocy-backup.service
TIMER=/etc/systemd/system/grocy-backup.timer

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "== $*"; }
ok() { echo "   ok: $*"; }

MODE=${1:---check}
case $MODE in
    --check|--apply|--revert) ;;
    *) die "Usage: $0 [--check|--apply|--revert]" ;;
esac

check() {
    info "Target"
    mountpoint -q "$MOUNT" && ok "$MOUNT mounted" || echo "   ERROR: $MOUNT not mounted"
    sudo test -d "$BACKUP_DIR" && ok "$BACKUP_DIR" || echo "   missing: $BACKUP_DIR"

    info "Units"
    [[ -f $SCRIPT ]] && ok "$SCRIPT" || echo "   missing: $SCRIPT"
    systemctl is-enabled grocy-backup.timer 2>/dev/null | sed 's/^/   timer: /' || echo "   timer not active"
    systemctl list-timers grocy-backup.timer --no-pager 2>/dev/null | sed -n 2p | sed 's/^/   /'

    info "Existing backups"
    sudo find "$BACKUP_DIR" -name 'grocy-*.tar.zst' -printf '%TY-%Tm-%Td %TH:%TM  %s  %p\n' 2>/dev/null \
        | sort | sed 's/^/   /'
    # Otherwise a stalled timer goes unnoticed.
    [[ -n $(sudo find "$BACKUP_DIR" -name 'grocy-*.tar.zst' -mmin -2160 2>/dev/null | head -1) ]] \
        && ok "latest backup is less than 36 h old" \
        || echo "   WARNING: no backup newer than 36 h"
}

write_script() {
    sudo tee "$SCRIPT" >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
GROCY_USER=$GROCY_USER
GROCY_UID=$GROCY_UID
MOUNT=$MOUNT
DEST=$BACKUP_DIR
KEEP=$KEEP
EOF
    sudo tee -a "$SCRIPT" >/dev/null <<'EOF'

mountpoint -q "$MOUNT" || { echo "$MOUNT not mounted" >&2; exit 1; }
cd /
gp() { runuser -u "$GROCY_USER" -- env XDG_RUNTIME_DIR="/run/user/$GROCY_UID" podman "$@"; }

cid=$(gp ps -q --filter name=grocy | head -1)
[[ -n $cid ]] || { echo "grocy container not running" >&2; exit 1; }
cfg=$(gp inspect "$cid" --format '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}')
[[ -d $cfg/data ]] || { echo "/config mount not found: '$cfg'" >&2; exit 1; }
compose=$(gp inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')

# Consistent snapshot while running; a cp of the live DB could be torn.
snap=data/backup-snapshot.db
out=$DEST/grocy-$(date +%Y%m%d-%H%M%S).tar.zst
trap 'rm -f -- "$cfg/$snap" "$out.tmp"' EXIT
rm -f -- "$cfg/$snap"
php_code='$d = new PDO("sqlite:/config/data/grocy.db"); $d->exec("VACUUM INTO " . $d->quote($argv[1]));'
gp exec "$cid" sh -c 'exec "$(command -v php || command -v php85)" -r "$0" "$1"' "$php_code" "/config/$snap"
head -c 15 "$cfg/$snap" | grep -q 'SQLite format 3' || { echo "snapshot is not an SQLite file" >&2; exit 1; }

tar -C / --warning=no-file-changed -cf - \
        --exclude="${cfg#/}/data/grocy.db" --exclude="${cfg#/}/data/grocy.db-*" \
        --exclude="${cfg#/}/data/viewcache" --exclude="${cfg#/}/log" \
        --transform="s|${snap}\$|data/grocy.db|" \
        "${cfg#/}" \
        $( [[ -n $compose && -d $compose ]] && echo "${compose#/}" ) \
    | zstd -q -10 -T0 -o "$out.tmp"
[[ -s $out.tmp ]] || { echo "output empty" >&2; exit 1; }
mv "$out.tmp" "$out"

ls -1t "$DEST"/grocy-*.tar.zst | tail -n +"$(( KEEP + 1 ))" | xargs -r rm -f --
EOF
    sudo chown root:root "$SCRIPT"
    sudo chmod 0700 "$SCRIPT"
}

write_units() {
    sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=grocy backup
RequiresMountsFor=$MOUNT
After=user@$GROCY_UID.service

[Service]
Type=oneshot
UMask=0077
ExecStart=$SCRIPT
EOF

    sudo tee "$TIMER" >/dev/null <<'EOF'
[Unit]
Description=Daily grocy backup

[Timer]
OnCalendar=*-*-* 03:40:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

apply() {
    sudo -v || die "sudo authentication failed."
    mountpoint -q "$MOUNT" || die "$MOUNT is not mounted."
    sudo install -d -m 700 -o root -g root "$BACKUP_DIR"
    write_script
    sudo bash -n "$SCRIPT"
    write_units
    sudo systemctl daemon-reload
    sudo systemctl enable --now grocy-backup.timer

    info "First run"
    if ! sudo systemctl start grocy-backup.service; then
        sudo journalctl -u grocy-backup.service -n 20 --no-pager
        die "Test run failed."
    fi
    info "Contents of the new backup"
    sudo sh -c "f=\$(ls -1t $BACKUP_DIR/grocy-*.tar.zst | head -1) && zstd -dc \"\$f\" | tar -tvf - | grep -E 'grocy.db|storage/' | head -5" | sed 's/^/   /'
    check
}

revert() {
    sudo -v || die "sudo authentication failed."
    sudo systemctl disable --now grocy-backup.timer 2>/dev/null || true
    sudo rm -f "$SERVICE" "$TIMER" "$SCRIPT"
    sudo systemctl daemon-reload
    echo "Timer removed; existing backups in $BACKUP_DIR are kept."
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
