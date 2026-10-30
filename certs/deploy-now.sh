#!/bin/sh
# Run ON THE PI as root:  sudo sh 12-deploy-now.sh
# Pushes the CURRENT live cert to every router in router.txt.
# No renewal, no Let's Encrypt rate limit consumed.
#
# Runs as root on purpose: that is how certbot invokes renew_hook, and the
# deploy scripts' internal "sudo scp" is then simply a no-op. Running it as
# certmgr fails, because certmgr cannot read /etc/letsencrypt.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Must run as root: sudo sh $0" >&2
    exit 1
fi

RENEWED_LINEAGE=/etc/letsencrypt/live/example.org
export RENEWED_LINEAGE

for f in cert.pem fullchain.pem privkey.pem; do
    [ -f "$RENEWED_LINEAGE/$f" ] || {
        echo "Missing $RENEWED_LINEAGE/$f - wrong lineage?" >&2
        echo "Available:" >&2; ls /etc/letsencrypt/live/ >&2
        exit 1; }
done

echo "Deploying $(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -serial)"
echo "  expires $(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -enddate)"
echo

cd /opt/cert-utils/pihole-hooks
./update_router.sh
