#!/bin/bash
# Installs the sshd boot-order drop-in on server.example.org. Usage: sudo ./install.sh [--check|--apply|--revert]
set -euo pipefail
cd "$(dirname "$0")"

BIN=/usr/local/libexec/sshd-wait-listen-addrs
DROPIN_DIR=/etc/systemd/system/sshd.service.d
DROPIN=$DROPIN_DIR/10-wait-listen-addrs.conf

check() {
    systemctl show sshd -p After -p Wants -p ExecStartPre | sed 's/^/   /'
    if [[ -x $BIN ]]; then
        # shellcheck disable=SC1091
        OPTIONS=$(. /etc/sysconfig/sshd 2>/dev/null; echo "${OPTIONS:-}")
        # shellcheck disable=SC2086
        echo "   addresses: $(/usr/sbin/sshd -T $OPTIONS | "$BIN" --parse | tr '\n' ' ')"
        # shellcheck disable=SC2086
        "$BIN" $OPTIONS && echo "   wait script: all addresses ready"
    fi
    ss -lnt '( sport = :22 )' | sed 's/^/   /'
}

case ${1:---check} in
--check)
    check ;;
--apply)
    install -m 755 -o root -g root -Z sshd-wait-listen-addrs "$BIN"
    install -d -m 755 "$DROPIN_DIR"
    install -m 644 -o root -g root -Z 10-wait-listen-addrs.conf "$DROPIN"
    systemd-analyze verify sshd.service
    systemctl daemon-reload
    check ;;
--revert)
    rm -f "$DROPIN" "$BIN"
    rmdir --ignore-fail-on-non-empty "$DROPIN_DIR"
    systemctl daemon-reload
    check ;;
*)
    echo "usage: $0 [--check|--apply|--revert]" >&2; exit 2 ;;
esac
