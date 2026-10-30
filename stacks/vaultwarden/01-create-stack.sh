#!/usr/bin/env bash
# Creates the user, directories, SELinux context and systemd drop-ins.
# Does not start anything yet.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

MOUNT_DROPIN=/etc/systemd/system/user@$VW_UID.service.d/10-data-mount.conf
RESTART_DROPIN=/etc/systemd/user/$UNIT.d/restart.conf

check() {
    info "User"
    if id "$VW_USER" &>/dev/null; then
        ok "$VW_USER exists (uid $(id -u "$VW_USER"))"
        grep -q "^$VW_USER:" /etc/subuid || echo "   MISSING: subuid range"
        [[ $(loginctl show-user "$VW_USER" -p Linger --value 2>/dev/null) == yes ]] \
            && ok "linger enabled" || echo "   MISSING: linger"
    else
        echo "   missing: $VW_USER"
        getent passwd "$VW_UID" >/dev/null \
            && die "uid $VW_UID is taken by $(getent passwd "$VW_UID" | cut -d: -f1)."
    fi

    info "Directories"
    # sudo test, not [[ -d ]]: the data dir sits under a 700 parent admin cannot
    # enter, so an unprivileged check would report it missing.
    for d in "$STACK_DIR" "$DATA_DIR"; do
        sudo test -d "$d" && ok "$d: $(sudo stat -c '%a %U:%G' "$d")" || echo "   missing: $d"
    done
    mountpoint -q "$MOUNT" && ok "$MOUNT mounted" || echo "   MISSING: $MOUNT not mounted"

    info "SELinux"
    # matchpathcon answers the question that matters: which label the policy
    # assigns to this path.
    if matchpathcon "$DATA_DIR" 2>/dev/null | grep -q container_file_t; then
        ok "policy assigns container_file_t"
        sudo ls -Zd "$DATA_DIR" 2>/dev/null | grep -q container_file_t \
            && ok "label is applied on disk too" \
            || echo "   MISSING: label not applied on disk -- restorecon -R $MOUNT/vaultwarden"
    else
        echo "   missing: fcontext rule"
    fi
    # httpd_t must be allowed to connect to the router, otherwise 502 with no nginx log line.
    sudo semanage port -l 2>/dev/null | grep -E '^http_port_t' | grep -qw "$PORT_ROUTER" \
        && ok "port $PORT_ROUTER is http_port_t" || echo "   missing: port $PORT_ROUTER in http_port_t"

    info "Drop-ins"
    [[ -f $MOUNT_DROPIN ]] && ok "$MOUNT_DROPIN" || echo "   missing: $MOUNT_DROPIN"
    [[ -f $RESTART_DROPIN ]] && ok "$RESTART_DROPIN" || echo "   missing: $RESTART_DROPIN"

    info "Ports free?"
    for p in $PORT_BACKEND $PORT_ANUBIS $PORT_ROUTER $PORT_METRICS; do
        ss -tlnH | awk '{print $4}' | grep -qE "[:.]$p\$" \
            && echo "   IN USE: $p" || ok "$p free"
    done
}

apply() {
    need_sudo
    mountpoint -q "$MOUNT" || die "$MOUNT is not mounted."

    if ! id "$VW_USER" &>/dev/null; then
        getent passwd "$VW_UID" >/dev/null \
            && die "uid $VW_UID is taken. Adjust common.sh."
        sudo useradd -u "$VW_UID" -m -s /usr/sbin/nologin "$VW_USER"
    fi
    sudo loginctl enable-linger "$VW_USER"

    # 755 so sudo -u can cd into it; it holds no secrets (the env file gets 0640 in 02-compose.sh).
    sudo install -d -m 755 -o "$VW_USER" -g "$VW_USER" "$STACK_DIR"
    sudo install -d -m 700 -o "$VW_USER" -g "$VW_USER" "$MOUNT/vaultwarden" "$DATA_DIR"

    sudo semanage fcontext -a -t container_file_t '/srv/data/vaultwarden(/.*)?' 2>/dev/null \
        || sudo semanage fcontext -m -t container_file_t '/srv/data/vaultwarden(/.*)?'
    sudo restorecon -R "$MOUNT/vaultwarden"

    sudo semanage port -a -t http_port_t -p tcp "$PORT_ROUTER" 2>/dev/null \
        || sudo semanage port -m -t http_port_t -p tcp "$PORT_ROUTER" 2>/dev/null \
        || ok "port $PORT_ROUTER was already labelled"

    # Without RequiresMountsFor the lingering user manager starts Podman before the
    # mount, and Vaultwarden silently creates a fresh, empty vault in an empty /data.
    sudo install -d -m 755 "$(dirname "$MOUNT_DROPIN")"
    sudo tee "$MOUNT_DROPIN" >/dev/null <<EOF
[Unit]
RequiresMountsFor=$MOUNT
EOF

    # The unit template has no Restart=.
    sudo install -d -m 755 "$(dirname "$RESTART_DROPIN")"
    sudo tee "$RESTART_DROPIN" >/dev/null <<'EOF'
[Service]
Restart=on-failure
RestartSec=15
[Unit]
StartLimitIntervalSec=0
EOF

    sudo systemctl daemon-reload
    echo
    check
}

revert() {
    need_sudo
    confirm "Remove user $VW_USER and $STACK_DIR? $DATA_DIR is kept"
    vw_systemctl disable --now "$UNIT" 2>/dev/null || true
    sudo loginctl disable-linger "$VW_USER" 2>/dev/null || true
    sudo rm -f "$MOUNT_DROPIN" "$RESTART_DROPIN"
    sudo systemctl daemon-reload
    sudo userdel -r "$VW_USER" 2>/dev/null || true
    sudo rm -rf "$STACK_DIR"
    sudo semanage port -d -t http_port_t -p tcp "$PORT_ROUTER" 2>/dev/null || true
    sudo semanage fcontext -d '/srv/data/vaultwarden(/.*)?' 2>/dev/null || true
    echo "Data left untouched in $DATA_DIR."
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
