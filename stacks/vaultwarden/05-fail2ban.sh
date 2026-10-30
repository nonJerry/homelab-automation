#!/usr/bin/env bash
# fail2ban filters and jails for Vaultwarden. Reads the journal rather than a
# file: no logrotate, and no SELinux question of fail2ban_t reading container_file_t.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

FILTER_USER=/etc/fail2ban/filter.d/vaultwarden.local
FILTER_ADMIN=/etc/fail2ban/filter.d/vaultwarden-admin.local
JAIL=/etc/fail2ban/jail.d/vaultwarden.local
# podman-compose prefixes the project name.
CONTAINER=vaultwarden_vaultwarden_1

check() {
    info "Files"
    for f in "$FILTER_USER" "$FILTER_ADMIN" "$JAIL"; do
        [[ -f $f ]] && ok "$f" || echo "   missing: $f"
    done

    info "Journal visible?"
    journalctl -n 1 --no-pager "CONTAINER_NAME=$CONTAINER" >/dev/null 2>&1 \
        && ok "CONTAINER_NAME=$CONTAINER returns entries" \
        || echo "   no entries -- is the stack running, and is the container named that?"

    info "Jails"
    sudo fail2ban-client status 2>/dev/null | sed 's/^/   /' || echo "   (requires root)"
    for j in vaultwarden vaultwarden-admin; do
        sudo fail2ban-client status "$j" 2>/dev/null | sed "s/^/   /" || true
    done

    info "Logged client IP"
    echo "   The jails are worthless as long as IP_HEADER is wrong."
    echo "   Recent failed logins in the journal:"
    journalctl --no-pager -n 200 "CONTAINER_NAME=$CONTAINER" 2>/dev/null \
        | grep -oE 'IP: [0-9a-fA-F:.]+' | sort | uniq -c | tail -5 | sed 's/^/     /' \
        || echo "     (none yet)"
    echo "   If this shows 127.0.0.1 or a 10.89.x address, IP_HEADER is wrong."
}

apply() {
    need_sudo

    sudo tee "$FILTER_USER" >/dev/null <<'EOF'
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*Username or password is incorrect\. Try again\. IP: <ADDR>\. Username:.*$
ignoreregex =
# Vaultwarden prefixes each line with its own timestamp; without this pattern
# fail2ban uses the journal's and findtime drifts.
datepattern = ^\[%%Y-%%m-%%d %%H:%%M:%%S
EOF

    sudo tee "$FILTER_ADMIN" >/dev/null <<'EOF'
[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*Invalid admin token\. IP: <ADDR>.*$
ignoreregex =
datepattern = ^\[%%Y-%%m-%%d %%H:%%M:%%S
EOF

    sudo tee "$JAIL" >/dev/null <<EOF
# backend and banaction are set in jail.local (systemd, firewallcmd-rich-rules).
# Rich rules cover v4 and v6 -- this matters: the apex has an AAAA record.
[vaultwarden]
enabled = true
filter = vaultwarden
journalmatch = CONTAINER_NAME=$CONTAINER
maxretry = 4
findtime = 10m
bantime = 1h
bantime.increment = true
bantime.maxtime = 7d

[vaultwarden-admin]
enabled = true
filter = vaultwarden-admin
journalmatch = CONTAINER_NAME=$CONTAINER
maxretry = 2
findtime = 1h
bantime = 1d
EOF

    # Test the filter against the real journal before reloading the service.
    info "Filter test against the journal"
    sudo fail2ban-regex "systemd-journal[journalmatch='CONTAINER_NAME=$CONTAINER']" \
        "$FILTER_USER" --print-no-missed 2>&1 | grep -E 'Lines:|matched' | sed 's/^/   /' || true

    sudo systemctl reload fail2ban || sudo systemctl restart fail2ban
    echo
    check
}

revert() {
    need_sudo
    confirm "Remove the Vaultwarden jails"
    sudo rm -f "$FILTER_USER" "$FILTER_ADMIN" "$JAIL"
    sudo systemctl reload fail2ban
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
