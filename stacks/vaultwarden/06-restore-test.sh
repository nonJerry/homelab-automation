#!/usr/bin/env bash
# Restores the newest backup into a throwaway container and checks it; the live service is untouched.
# Needs the PRIVATE age key, which is not kept on the server: pass AGE_KEY=/path from removable media.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

AGE_KEY=${AGE_KEY:-}
WORK=/var/tmp/vw-restore-test
MARKER=$WORK/.last-test
TEST_PORT=8223
TEST_NAME=vw-restore-test

# The glob must be expanded by root: BACKUP_DIR is root-only.
newest_backup() {
    sudo find "$BACKUP_DIR" -maxdepth 1 -name 'vaultwarden-*.tar.zst.age' -printf '%T@ %p\n' \
        | sort -nr | head -1 | cut -d' ' -f2-
}

check() {
    info "Newest backup"
    local newest
    newest=$(newest_backup) || true
    [[ -n ${newest:-} ]] || { echo "   none found"; return; }
    sudo stat -c '   %n  %s bytes  %y' "$newest"

    info "Last restore test"
    # WORK is readable only by root and the service user.
    if sudo test -f "$MARKER"; then
        sudo cat "$MARKER" | sed 's/^/   /'
    else
        echo "   never - until then the backup is untested"
    fi
}

apply() {
    need_sudo
    [[ -n $AGE_KEY ]] || die "Set AGE_KEY=/path/to/private/key."
    [[ -r $AGE_KEY ]] || die "$AGE_KEY is not readable."
    command -v age >/dev/null || die "age is not installed."

    local newest
    newest=$(newest_backup)
    [[ -n $newest ]] || die "No backup found."
    info "Testing $newest"

    sudo rm -rf "$WORK"
    sudo install -d -m 700 "$WORK"
    sudo age -d -i "$AGE_KEY" "$newest" | sudo zstd -dc | sudo tar -C "$WORK" -xf -
    # The archive has no directory entries; the rootless container cannot use root-owned parents.
    sudo chown -R "$VW_USER:" "$WORK"

    local data="$WORK${DATA_DIR}"
    sudo test -f "$data/db.sqlite3" || die "db.sqlite3 missing from the archive."
    sudo test -f "$data/rsa_key.pem" || die "rsa_key.pem missing from the archive."

    # The host has no sqlite3, so the check runs in a throwaway container.
    info "integrity_check"
    local res
    res=$(vw_podman run --rm --cap-drop=ALL -v "$data:/d:z" --entrypoint sh "$VW_IMAGE" \
        -c 'apk add --no-cache sqlite >/dev/null 2>&1; sqlite3 /d/db.sqlite3 "PRAGMA integrity_check;"' 2>&1 | tail -1)
    [[ $res == ok ]] || die "integrity_check: $res"
    ok "integrity_check ok"

    info "Row counts"
    vw_podman run --rm --cap-drop=ALL -v "$data:/d:z" --entrypoint sh "$VW_IMAGE" \
        -c 'apk add --no-cache sqlite >/dev/null 2>&1; for t in users ciphers organizations; do printf "   %-16s %s\n" "$t" "$(sqlite3 /d/db.sqlite3 "select count(*) from $t;")"; done'

    info "Throwaway stack on 127.0.0.1:$TEST_PORT"
    vw_podman rm -f "$TEST_NAME" >/dev/null 2>&1 || true
    # Bitwarden clients refuse http even on loopback: throwaway certificate for 127.0.0.1 only.
    local tls="$WORK/tls"
    sudo install -d -m 700 -o "$VW_USER" -g "$VW_USER" "$tls"
    sudo openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
        -subj /CN=127.0.0.1 -addext subjectAltName=IP:127.0.0.1,DNS:localhost \
        -keyout "$tls/key.pem" -out "$tls/cert.pem" 2>/dev/null
    sudo chown "$VW_USER:" "$tls/key.pem" "$tls/cert.pem"
    vw_podman run -d --name "$TEST_NAME" \
        --cap-drop=ALL --security-opt no-new-privileges --read-only \
        --tmpfs /tmp:rw,noexec,nosuid,nodev,size=32m \
        -v "$data:/data:z" -v "$tls:/tls:z,ro" \
        -e "DOMAIN=https://127.0.0.1:$TEST_PORT" -e ROCKET_PORT=8080 \
        -e 'ROCKET_TLS={certs="/tls/cert.pem",key="/tls/key.pem"}' \
        -e SIGNUPS_ALLOWED=false -e ADMIN_TOKEN= \
        -p "127.0.0.1:$TEST_PORT:8080" "$VW_IMAGE" >/dev/null

    for _ in $(seq 20); do
        sudo curl -fsS -m 2 --cacert "$tls/cert.pem" "https://127.0.0.1:$TEST_PORT/alive" >/dev/null 2>&1 && break
        sleep 1
    done
    sudo curl -fsS -m 5 --cacert "$tls/cert.pem" "https://127.0.0.1:$TEST_PORT/alive" >/dev/null \
        || die "Throwaway stack does not respond."
    ok "responds on /alive"

    cat <<EOF

Now by hand: open an SSH tunnel and actually log in -
"running" does not mean "the data is there".

  ssh -N -L $TEST_PORT:127.0.0.1:$TEST_PORT admin@server.example.org
  Browser: https://127.0.0.1:$TEST_PORT/
  (Throwaway self-signed certificate: accept the browser warning once.)

Open an item and download an attachment. Afterwards:
  $0 --revert
EOF
    date '+Tested %F %T, archive: '"$(basename "$newest")" | sudo tee "$MARKER" >/dev/null
}

revert() {
    need_sudo
    vw_podman rm -f "$TEST_NAME" >/dev/null 2>&1 || true
    # Keep only the marker: the extracted files are a complete vault on a plaintext filesystem.
    sudo find "$WORK" -mindepth 1 -maxdepth 1 ! -name "$(basename "$MARKER")" -exec rm -rf {} +
    ok "Throwaway stack and extracted data removed"
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
