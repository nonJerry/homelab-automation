#!/bin/sh
# Deploy the renewed wildcard cert to every OpenWrt router in router.txt.
#
# scp -O: OpenSSH 9+ speaks SFTP by default, which dropbear on OpenWrt lacks.
# router.txt is read on fd 3 so neither scp nor ssh can consume the loop's stdin.
set -u

domain="example.org"
hook_dir=/opt/cert-utils/pihole-hooks
key_location=/home/certmgr/.ssh/id_ed25519

if [ -z "${RENEWED_LINEAGE:-}" ] || [ ! -f "$RENEWED_LINEAGE/fullchain.pem" ]; then
    echo "update_router.sh: RENEWED_LINEAGE unset or invalid; refusing to run" >&2
    exit 1
fi

local_serial="$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -serial)"
rc=0

while read -r router <&3; do
    [ -n "$router" ] || continue
    case "$router" in \#*) continue ;; esac
    address="$router.$domain"

    http_code="$(curl -s -o /dev/null -w "%{http_code}" "$address" </dev/null)"
    if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
        echo "Skipping $router: no HTTP response (powered off?)" >&2
        rc=1
        continue
    fi

    echo "Updating $router..."
    if ! sudo scp -O -i "$key_location" -o BatchMode=yes -o ConnectTimeout=10 \
            "$RENEWED_LINEAGE/fullchain.pem" "root@$address:/etc/uhttpd.crt" </dev/null \
       || ! sudo scp -O -i "$key_location" -o BatchMode=yes -o ConnectTimeout=10 \
            "$RENEWED_LINEAGE/privkey.pem" "root@$address:/etc/uhttpd.key" </dev/null; then
        echo "  FAILED to copy cert to $router" >&2
        rc=1
        continue
    fi
    sudo ssh -n -i "$key_location" -o BatchMode=yes -o ConnectTimeout=10 \
        "root@$address" /etc/init.d/uhttpd restart

    # Verify what it actually serves rather than trusting the exit codes above.
    sleep 2
    remote_serial="$(echo | openssl s_client -connect "$address:443" \
        -servername "$address" 2>/dev/null | openssl x509 -noout -serial 2>/dev/null)"
    if [ "$remote_serial" = "$local_serial" ]; then
        echo "  $router now serves $local_serial"
    else
        echo "  WARNING: $router serves '$remote_serial', expected '$local_serial'" >&2
        rc=1
    fi
done 3< "$hook_dir/router.txt"

exit $rc
