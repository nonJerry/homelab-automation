#!/usr/bin/env bash
# Encrypted daily backup to a different filesystem than the data.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

SCRIPT=/usr/local/sbin/vw-backup.sh
SERVICE=/etc/systemd/system/vaultwarden-backup.service
TIMER=/etc/systemd/system/vaultwarden-backup.timer
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=6

check() {
    info "Tools"
    command -v age >/dev/null && ok "age" || echo "   missing: age (dnf install age, from EPEL)"
    command -v zstd >/dev/null && ok "zstd" || echo "   missing: zstd"

    info "Key"
    if sudo test -f "$BACKUP_KEY"; then
        ok "$BACKUP_KEY present"
        sudo grep -q '^age1' "$BACKUP_KEY" && ok "looks like an age recipient" \
            || echo "   WARNING: does not start with age1 -- is this the public part?"
        sudo grep -q 'AGE-SECRET-KEY' "$BACKUP_KEY" \
            && echo "   SHOULD ABORT: this file contains a PRIVATE key."
    else
        echo "   missing: $BACKUP_KEY"
    fi

    info "Destination"
    [[ -d $BACKUP_DIR ]] && ok "$BACKUP_DIR ($(stat -c '%a %U:%G' "$BACKUP_DIR"))" \
        || echo "   missing: $BACKUP_DIR"
    if [[ -d $BACKUP_DIR ]]; then
        local bfs dfs
        bfs=$(sudo df --output=target "$BACKUP_DIR" | tail -1)
        dfs=$(sudo df --output=target "$DATA_DIR" | tail -1)
        [[ $bfs != "$dfs" ]] && ok "different filesystem than the data ($bfs vs $dfs)" \
            || echo "   ERROR: backup is on the same filesystem as the data."
    fi

    info "Units"
    [[ -f $SCRIPT ]] && ok "$SCRIPT" || echo "   missing: $SCRIPT"
    systemctl is-enabled vaultwarden-backup.timer 2>/dev/null | sed 's/^/   timer: /' \
        || echo "   timer not active"

    info "Existing backups"
    sudo find "$BACKUP_DIR" -name 'vaultwarden-*.tar.zst.age' -printf '%TY-%Tm-%Td %TH:%TM  %s  %p\n' 2>/dev/null \
        | sort | tail -5 | sed 's/^/   /' || echo "   none"
    # A stalled timer is otherwise invisible.
    local newest
    newest=$(sudo find "$BACKUP_DIR" -name 'vaultwarden-*.tar.zst.age' -mmin -2160 2>/dev/null | head -1)
    [[ -n ${newest:-} ]] && ok "newest backup is less than 36 h old" \
        || echo "   WARNING: no backup newer than 36 h"
}

write_script() {
    sudo tee "$SCRIPT" >/dev/null <<EOF
#!/usr/bin/env bash
# Called by the timer. Has the server create a consistent SQLite snapshot,
# stores it encrypted and prunes old backups.
set -euo pipefail

DATA=$DATA_DIR
DEST=$BACKUP_DIR
STACK=$STACK_DIR
VW_USER=$VW_USER
VW_UID=$VW_UID
KEY=$BACKUP_KEY
KEEP_DAILY=$KEEP_DAILY
KEEP_WEEKLY=$KEEP_WEEKLY
KEEP_MONTHLY=$KEEP_MONTHLY
MOUNT=$MOUNT
EOF
    sudo tee -a "$SCRIPT" >/dev/null <<'EOF'

mountpoint -q "$MOUNT" || { echo "$MOUNT not mounted" >&2; exit 1; }

# Dumps and live data must not share a filesystem: RAID survives a disk
# failure, but not corruption or an rm.
[[ $(df --output=target "$DEST" | tail -1) != $(df --output=target "$DATA" | tail -1) ]] \
    || { echo "backup is on the same filesystem as the data" >&2; exit 1; }

cd /
vw() { runuser -u "$VW_USER" -- env XDG_RUNTIME_DIR="/run/user/$VW_UID" podman "$@"; }

cid=$(vw ps -q --filter label=com.docker.compose.service=vaultwarden | head -1)
[[ -n $cid ]] || { echo "container is not running" >&2; exit 1; }

# The built-in command uses the SQLite backup API, so it is consistent without
# stopping the service. A cp is not: in WAL mode the copy would be torn.
vw exec "$cid" /vaultwarden backup

snap=$(ls -1t "$DATA"/db_*.sqlite3 2>/dev/null | head -1 || true)
[[ -n $snap ]] || { echo "no snapshot created in $DATA" >&2; ls -la "$DATA" >&2; exit 1; }
trap 'rm -f -- "$snap"' EXIT
head -c 15 "$snap" | grep -q 'SQLite format 3' \
    || { echo "snapshot is not an SQLite file" >&2; exit 1; }

ts=$(date +%Y%m%d-%H%M%S)
out=$DEST/vaultwarden-$ts.tar.zst.age

# config.json holds the admin token hash and possibly the SMTP password, the
# stack dir holds secrets in plaintext -- so always encrypt; the private key is not on this host.
tar -C / --warning=no-file-changed -cf - \
        --transform='s|/db_[0-9_]*\.sqlite3$|/db.sqlite3|' \
        "${snap#/}" \
        "${DATA#/}/rsa_key.pem" \
        $( [[ -d $DATA/attachments ]] && echo "${DATA#/}/attachments" ) \
        $( [[ -d $DATA/sends ]] && echo "${DATA#/}/sends" ) \
        $( [[ -f $DATA/config.json ]] && echo "${DATA#/}/config.json" ) \
        "${STACK#/}" \
    | zstd -q -10 -T0 \
    | age -R "$KEY" -o "$out.tmp"

[[ -s $out.tmp ]] || { rm -f "$out.tmp"; echo "output is empty" >&2; exit 1; }
mv "$out.tmp" "$out"
chmod 600 "$out"

# Weekly and monthly copies as hardlinks -- they cost no space.
[[ $(date +%u) == 7 ]] && { mkdir -p "$DEST/weekly"; ln -f "$out" "$DEST/weekly/$(basename "$out")"; }
[[ $(date +%d) == 01 ]] && { mkdir -p "$DEST/monthly"; ln -f "$out" "$DEST/monthly/$(basename "$out")"; }

# weekly/ and monthly/ do not exist until the first Sunday or first of the month.
prune() { { ls -1t "$1"/vaultwarden-*.tar.zst.age 2>/dev/null || true; } | tail -n +"$(( $2 + 1 ))" | xargs -r rm -f --; }
prune "$DEST" "$KEEP_DAILY"
prune "$DEST/weekly" "$KEEP_WEEKLY"
prune "$DEST/monthly" "$KEEP_MONTHLY"
EOF
    sudo chown root:root "$SCRIPT"
    sudo chmod 0700 "$SCRIPT"
}

write_units() {
    sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Vaultwarden backup (encrypted)
RequiresMountsFor=$MOUNT
After=user@$VW_UID.service

[Service]
Type=oneshot
UMask=0077
ExecStart=$SCRIPT
EOF

    sudo tee "$TIMER" >/dev/null <<'EOF'
[Unit]
Description=Daily Vaultwarden backup run

[Timer]
OnCalendar=*-*-* 03:10:00
RandomizedDelaySec=15m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

apply() {
    need_sudo
    command -v age >/dev/null || die "age missing. See README.md (Vaultwarden backup key)."
    sudo test -f "$BACKUP_KEY" || die "$BACKUP_KEY missing. See README.md (Vaultwarden backup key)."
    sudo grep -q 'AGE-SECRET-KEY' "$BACKUP_KEY" \
        && die "$BACKUP_KEY contains a private key. Only the public recipient belongs on this host."

    sudo install -d -m 700 -o root -g root "$BACKUP_DIR"
    write_script
    write_units
    sudo systemctl daemon-reload
    sudo systemctl enable --now vaultwarden-backup.timer

    info "First run"
    sudo systemctl start vaultwarden-backup.service \
        || sudo journalctl -u vaultwarden-backup.service -n 15 --no-pager -o cat
    sudo systemctl status vaultwarden-backup.service --no-pager -n 10 | sed 's/^/   /' || true
    echo
    check
}

revert() {
    need_sudo
    confirm "Remove the backup timer? Existing backups are kept"
    sudo systemctl disable --now vaultwarden-backup.timer 2>/dev/null || true
    sudo rm -f "$SERVICE" "$TIMER" "$SCRIPT"
    sudo systemctl daemon-reload
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
