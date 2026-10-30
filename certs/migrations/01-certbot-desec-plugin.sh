#!/bin/sh
# Run ON THE PI as root.
# Migrates certbot from the snap to a venv + the official certbot-dns-desec
# plugin, and converts both renewal configs from --manual/dynv6 hooks to the
# plugin. Does NOT issue a new certificate and does NOT remove the snap yet.
set -eu

VENV=/opt/certbot
CREDS=/etc/letsencrypt/desec-credentials.ini
TS=$(date +%Y%m%d-%H%M%S)

if [ ! -s "$CREDS" ]; then
    echo "ABORTING: $CREDS missing." >&2
    echo "Create it first (the plugin's own format):" >&2
    echo "  sudo sh -c 'echo \"dns_desec_token = <token>\" > $CREDS'" >&2
    echo "  sudo chmod 600 $CREDS" >&2
    exit 1
fi
chmod 600 "$CREDS"

echo "== 1. venv + plugin (bookworm is PEP668-managed, so a venv is required)"
apt-get install -y python3-venv >/dev/null
python3 -m venv "$VENV"
"$VENV/bin/pip" install --upgrade pip >/dev/null
"$VENV/bin/pip" install certbot certbot-dns-desec
ln -sf "$VENV/bin/certbot" /usr/local/bin/certbot
"$VENV/bin/certbot" --version
"$VENV/bin/certbot" plugins --authenticators 2>&1 | grep -i desec \
    || { echo "dns-desec plugin not registered, aborting" >&2; exit 1; }

echo
echo "== 2. convert renewal configs (deploy hooks are kept)"
for c in /etc/letsencrypt/renewal/example.org.conf \
         /etc/letsencrypt/renewal/example.org-0001.conf; do
    [ -f "$c" ] || continue
    cp "$c" "$c.bak-$TS"
    # drop the manual authenticator and its dynv6 hooks; keep renew_hook
    sed -i '/^manual_auth_hook/d; /^manual_cleanup_hook/d; /^manual_public_ip_logging_ok/d; /^pref_challs/d' "$c"
    if grep -q '^authenticator' "$c"; then
        sed -i 's/^authenticator.*/authenticator = dns-desec/' "$c"
    else
        sed -i '/^\[renewalparams\]/a authenticator = dns-desec' "$c"
    fi
    sed -i '/^dns_desec_credentials/d; /^dns_desec_propagation_seconds/d' "$c"
    sed -i "/^authenticator = dns-desec/a dns_desec_credentials = $CREDS\ndns_desec_propagation_seconds = 90" "$c"
    echo "--- $c"
    grep -E 'authenticator|dns_desec|renew_hook' "$c"
done

echo
echo "== 3. dry-run both certs against staging (no rate limit consumed)"
"$VENV/bin/certbot" renew --cert-name example.org-0001 --dry-run
"$VENV/bin/certbot" renew --cert-name example.org --dry-run

echo
echo "Both dry-runs passed. Snap certbot is still installed and its timer is"
echo "still active - run 21-certbot-snap-cutover.sh to switch the timer over."
