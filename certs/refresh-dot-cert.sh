#!/usr/bin/env bash
# The DoT stack serves its own copy of the wildcard cert from /opt/subdns/tls/.
# That copy is NOT updated when the pi pushes a renewal, so it expires silently.
# Usage: refresh-subdns-cert.sh --check | --refresh | --install-hook | --remove-hook
set -uo pipefail

SRC_CERT=/etc/pki/tls/certs/fullchain.pem
SRC_KEY=/etc/pki/tls/private/privkey.pem
DST=/opt/subdns/tls
MODE=${1:---check}
[[ $EUID -eq 0 ]] || { echo "run as root (pkexec/sudo)"; exit 1; }

enddate() { openssl x509 -noout -enddate -in "$1" 2>/dev/null | cut -d= -f2; }
served()  {
    timeout 8 openssl s_client -connect "$1" -servername sub-hole.example.org </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2
}

report() {
    echo "shared cert  $SRC_CERT"
    echo "  expires: $(enddate $SRC_CERT)"
    echo "subdns copy  $DST/fullchain.pem"
    echo "  expires: $(enddate $DST/fullchain.pem)"
    ls -l "$DST" 2>&1 | sed 's/^/  /'
    echo "served on the wire:"
    for t in "198.51.100.10:853" "[2001:db8:f001::10]:853" \
             "198.51.100.10:8853" "[2001:db8:f001::10]:8853"; do
        printf "  %-40s %s\n" "$t" "$(served "$t" || echo '<no handshake>')"
    done
}

case $MODE in
--check) report ;;

--refresh)
    echo "before:"; report; echo
    ts=$(date +%Y%m%d-%H%M%S)
    mkdir -p "$DST"
    for f in fullchain.pem privkey.pem; do
        [[ -f $DST/$f ]] && cp -a "$DST/$f" "$DST/$f.bak-$ts"
    done
    install -o subdns -g subdns -m 644 "$SRC_CERT" "$DST/fullchain.pem"
    install -o subdns -g subdns -m 640 "$SRC_KEY"  "$DST/privkey.pem"
    restorecon -v "$DST"/*.pem 2>/dev/null

    # Must go through the unit: these containers share pihole's netns, so a plain
    # `podman restart` on one of them crash-loops.
    echo "restarting the subdns stack via its unit:"
    systemctl --machine=subdns@.host --user restart podman-compose@subdns.service || {
        echo "restart FAILED - restoring previous cert"
        for f in fullchain.pem privkey.pem; do
            [[ -f $DST/$f.bak-$ts ]] && mv "$DST/$f.bak-$ts" "$DST/$f"
        done
        exit 1
    }
    for _ in $(seq 1 20); do sleep 3; served "198.51.100.10:853" >/dev/null && break; done
    echo; echo "after:"; report
    echo
    echo "Now confirm it still RESOLVES (an expired cert and a dead resolver look the same"
    echo "to a handshake test). From another host, query a name that is neither local nor"
    echo "cached:"
    echo "  kdig +tls @198.51.100.10 -p 853 \$(openssl rand -hex 4).example.com A"
    ;;

--install-hook)
    cat > /etc/systemd/system/subdns-cert-sync.service <<'UNIT'
[Unit]
Description=Copy renewed wildcard cert into the subdns DoT stack
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/refresh-dot-cert.sh --refresh
UNIT
    cat > /etc/systemd/system/subdns-cert-sync.path <<'UNIT'
[Unit]
Description=Watch the shared wildcard cert for renewal
[Path]
PathChanged=/etc/pki/tls/certs/fullchain.pem
Unit=subdns-cert-sync.service
[Install]
WantedBy=paths.target
UNIT
    systemctl daemon-reload
    systemctl enable --now subdns-cert-sync.path
    systemctl status subdns-cert-sync.path --no-pager | head -5
    echo "installed: a renewal pushed by the pi now propagates to the DoT stack automatically."
    ;;

--remove-hook)
    systemctl disable --now subdns-cert-sync.path 2>/dev/null
    rm -f /etc/systemd/system/subdns-cert-sync.{path,service}
    systemctl daemon-reload
    echo "hook removed"
    ;;
*) echo "usage: $0 --check | --refresh | --install-hook | --remove-hook"; exit 1;;
esac
