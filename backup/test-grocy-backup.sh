#!/usr/bin/env bash
# Local test of the backup logic in grocy-backup.sh against a throwaway grocy container.
# Needs no server and no sudo; podman unshare stands in for root on the server.
set -euo pipefail

IMAGE=${IMAGE:-lscr.io/linuxserver/grocy:latest}
work=$(mktemp -d)
name=grocy-backup-test-$$
trap 'podman rm -f "$name" >/dev/null 2>&1; podman unshare rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$work/config" "$work/dest"
podman run -d --name "$name" -v "$work/config:/config:Z" "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
    podman exec "$name" curl -sfL -o /dev/null http://localhost/ 2>/dev/null && break
    sleep 1
done
[[ -f $work/config/data/grocy.db ]] || fail "grocy did not create a database"
podman exec "$name" php -r '$d = new PDO("sqlite:/config/data/grocy.db"); $d->exec("INSERT INTO equipment(name, description) VALUES (\"TestPC\", \"x\")");'

# The part of grocy-backup.sh that is installed on the server as the backup script.
{
    printf 'GROCY_USER=x\nGROCY_UID=0\nMOUNT=/\nDEST=%s\nKEEP=7\n' "$work/dest"
    awk "/<<'EOF'\$/{f=1;next} /^EOF\$/{if(f){exit}} f" "$(dirname "$0")/grocy-backup.sh" \
        | sed 's|^gp() .*$|gp() { podman "$@"; }|'
} > "$work/inner.sh"

for i in $(seq 1 9); do
    podman unshare bash "$work/inner.sh" || fail "run $i failed"
    sleep 1.1
done

n=$(ls "$work/dest" | wc -l)
[[ $n == 7 ]] || fail "expected 7 backups, found $n"
compgen -G "$work/dest/*.tmp" >/dev/null && fail ".tmp file left behind"
[[ -e $work/config/data/backup-snapshot.db ]] && fail "snapshot not cleaned up"

latest=$(ls -1t "$work/dest"/grocy-*.tar.zst | head -1)
mkdir "$work/restore"
zstd -dc "$latest" | podman unshare tar -C "$work/restore" -xf -
db=$(podman unshare find "$work/restore" -path '*/config/data/grocy.db')
[[ -n $db ]] || fail "grocy.db missing from backup"
podman unshare find "$work/restore" -name 'backup-snapshot.db' | grep -q . && fail "snapshot backed up under its old name"
podman unshare find "$work/restore" -path '*/config/data/config.php' | grep -q . || fail "config.php missing"
[[ $(podman unshare sqlite3 "$db" 'PRAGMA integrity_check') == ok ]] || fail "integrity_check"
[[ $(podman unshare sqlite3 "$db" "SELECT name FROM equipment WHERE name='TestPC'") == TestPC ]] \
    || fail "test entry missing from backed-up database"

echo "OK: 9 runs, 7 kept, database intact and restorable"
