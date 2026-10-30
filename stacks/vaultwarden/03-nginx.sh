#!/usr/bin/env bash
# nginx vhost + Anubis instance. Backs up everything it touches first.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

PROXY_INC=/etc/nginx/vaultwarden-proxy.inc
BACKUP_ROOT=/root/vaultwarden-backups
ACME_BACKEND=127.0.0.1:8081   # same path as in nextcloud.conf

check() {
    info "Files"
    for f in "$NGINX_CONF" "$PROXY_INC" "$ANUBIS_ENV" "$ANUBIS_POLICY"; do
        sudo test -f "$f" && ok "$f" || echo "   missing: $f"
    done

    info "nginx"
    local out; out=$(sudo nginx -t 2>&1)
    echo "$out" | sed 's/^/   /'
    # nginx still loads with [warn]; only [emerg] is fatal.
    echo "$out" | grep -q 'test is successful' \
        && ok "configuration loads$(echo "$out" | grep -q '\[warn\]' && echo ' (with warnings, see above)')" \
        || echo "   ERROR: configuration does not load"

    info "Anubis"
    systemctl is-active anubis@vault.service 2>/dev/null | sed 's/^/   active: /' \
        || echo "   anubis@vault is not running"

    info "Loopback chain"
    curl -fsS -m 5 "http://127.0.0.1:$PORT_BACKEND/alive" >/dev/null 2>&1 \
        && ok "backend $PORT_BACKEND" || echo "   down: backend $PORT_BACKEND"
    curl -fsS -m 5 -H "Host: $VW_HOST" "http://127.0.0.1:$PORT_ROUTER/alive" >/dev/null 2>&1 \
        && ok "router $PORT_ROUTER" || echo "   down: router $PORT_ROUTER"
}

write_proxy_inc() {
    sudo tee "$PROXY_INC" >/dev/null <<'EOF'
# Shared proxy headers, included from the Vaultwarden locations.
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
EOF
}

write_nginx() {
    sudo tee "$NGINX_CONF" >/dev/null <<EOF
# vault.example.org -- Vaultwarden.
#
# Split: the clients (mobile app, browser extension, desktop) only talk to
# /api/, /identity/ and /notifications/. They cannot solve a JS challenge --
# the extension even sends a browser-like User-Agent and would still get HTML
# where it expects JSON. So these paths go straight to the backend and never
# see Anubis. Only the web vault (the SPA under /) goes through Anubis.

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      "";
}

upstream anubis_vault { server 127.0.0.1:$PORT_ANUBIS; }
upstream vaultwarden  { server 127.0.0.1:$PORT_BACKEND; keepalive 4; }

server {
    listen 80;
    listen [::]:80;
    server_name $VW_HOST;

    # Certificate renewal must not go through Anubis.
    location /.well-known/acme-challenge/ {
        proxy_pass http://$ACME_BACKEND;
        include $PROXY_INC;
    }
    # Plain HTTP would bypass Anubis, and its cookie is flagged Secure -- a
    # plaintext request would loop on the challenge forever.
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $VW_HOST;

    # Must match on both levels; the smaller value wins, and the 413 shows up
    # in the mobile client as a silent upload failure.
    client_max_body_size 525m;

    # Seven proxy headers (five from the include plus Upgrade/Connection) exceed
    # the default of 64 -- otherwise nginx -t warns on every run.
    proxy_headers_hash_max_size 1024;
    proxy_headers_hash_bucket_size 128;

    # HSTS only. Vaultwarden sets X-Frame-Options, Referrer-Policy,
    # X-Content-Type-Options and a full CSP itself, and deliberately omits them
    # on /webauthn-connector.html and the other 2FA connector pages because the
    # browser extension loads them in a frame. A blanket X-Frame-Options here
    # overrides that and breaks 2FA setup; the admin panel reports it under
    # "HTTP Response validation". HSTS does belong here: the backend does not
    # know about it, and it is a property of TLS termination.
    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains; preload" always;

    location /.well-known/acme-challenge/ {
        proxy_pass http://$ACME_BACKEND;
        include $PROXY_INC;
    }

    # --- LAN only ----------------------------------------------------------
    # Two independent locks: the network here, and in the application the
    # Argon2 token with ADMIN_RATELIMIT_MAX_BURST=2.
    location ^~ /admin {
        if (\$local_network = 0) { return 444; }
        proxy_pass http://vaultwarden;
        include $PROXY_INC;
    }
    # Liveness and version timing only help an attacker.
    location = /alive {
        if (\$local_network = 0) { return 444; }
        proxy_pass http://vaultwarden;
        include $PROXY_INC;
    }

    # --- Fully closed ------------------------------------------------------
    # Org events are off (ORG_EVENTS_ENABLED). Blocked so that a future change
    # of default does not silently expose them.
    location ^~ /events/    { return 444; }
    location ^~ /api/events { return 444; }

    # --- Clients: without Anubis ------------------------------------------
    location ^~ /api/       { proxy_pass http://vaultwarden; include $PROXY_INC; }
    location ^~ /identity/  { proxy_pass http://vaultwarden; include $PROXY_INC; }
    location ^~ /icons/     { proxy_pass http://vaultwarden; include $PROXY_INC; }
    location ^~ /attachments/ { proxy_pass http://vaultwarden; include $PROXY_INC; }

    # Since 1.3x the WebSocket runs on the same port as everything else.
    location ^~ /notifications/ {
        proxy_pass http://vaultwarden;
        include $PROXY_INC;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # --- Web vault: through Anubis ----------------------------------------
    # The SPA loads assets from paths (/app/, /css/, /locales/) that change with
    # each web-vault version. An allowlist would break on every update, so /
    # catches everything else -- unknown paths reach the backend and get a 404.
    location / {
        proxy_pass http://anubis_vault;
        include $PROXY_INC;
    }
}

# Internal router. Only Anubis reaches it, hence no listen [::].
server {
    listen 127.0.0.1:$PORT_ROUTER;
    server_name _;
    client_max_body_size 525m;
    proxy_headers_hash_max_size 1024;
    proxy_headers_hash_bucket_size 128;

    # Recover the real client from what Anubis passes along.
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    real_ip_header X-Real-IP;

    location / {
        proxy_pass http://vaultwarden;
        include $PROXY_INC;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF
}

write_anubis() {
    sudo install -d -m 755 /etc/anubis
    # 0600: REDIRECT_DOMAINS and COOKIE_DOMAIN are not secret, but the file sits
    # next to ones that are -- same permissions, one rule.
    sudo install -m 0600 -o root -g root /dev/null "$ANUBIS_ENV"
    sudo tee "$ANUBIS_ENV" >/dev/null <<EOF
BIND=127.0.0.1:$PORT_ANUBIS
TARGET=http://127.0.0.1:$PORT_ROUTER
# The default would be wildcard port 9090 -- public AND Cockpit's port.
METRICS_BIND=127.0.0.1:$PORT_METRICS
POLICY_FNAME=$ANUBIS_POLICY
COOKIE_DOMAIN=example.org
# Without this the service is an open redirector. Matches per hostname.
REDIRECT_DOMAINS=$VW_HOST
# The default strips RFC1918/ULA -- i.e. exactly every LAN client here.
XFF_STRIP_PRIVATE=false
DIFFICULTY=4
EOF

    sudo tee "$ANUBIS_POLICY" >/dev/null <<'EOF'
bots:
  - import: (data)/bots/_deny-pathological.yaml
  - import: (data)/common/keep-internet-working.yaml

  # Second safety net. nginx already routes these paths around Anubis; if a
  # rule there ever slips, the clients still do not break here. The browser
  # extension sends a Mozilla UA yet cannot solve the challenge -- hence path,
  # not User-Agent.
  - name: vaultwarden-clients
    path_regex: ^/(api|identity|notifications|icons|attachments|sends)/
    action: ALLOW

  - import: (data)/meta/ai-block-aggressive.yaml
  - import: (data)/crawlers/_allow-good.yaml

  - name: generic-browser
    user_agent_regex: Mozilla
    action: CHALLENGE
EOF
}

apply() {
    need_sudo
    sudo test -f /etc/anubis/ed25519.key \
        || die "/etc/anubis/ed25519.key missing -- Anubis is not set up."

    local stamp; stamp=$(date +%Y%m%d-%H%M%S)
    sudo install -d -m 700 "$BACKUP_ROOT/$stamp"
    for f in "$NGINX_CONF" "$PROXY_INC" "$ANUBIS_ENV" "$ANUBIS_POLICY"; do
        sudo test -f "$f" && sudo cp -a "$f" "$BACKUP_ROOT/$stamp/"
    done
    ok "backup in $BACKUP_ROOT/$stamp"

    write_proxy_inc
    write_nginx
    write_anubis

    sudo nginx -t || die "nginx -t failed. Nothing reloaded."
    sudo systemctl enable --now anubis@vault.service
    sudo systemctl reload nginx
    echo
    check
}

revert() {
    need_sudo
    confirm "Remove vaultwarden.conf and anubis@vault"
    sudo systemctl disable --now anubis@vault.service 2>/dev/null || true
    sudo rm -f "$NGINX_CONF" "$PROXY_INC" "$ANUBIS_ENV" "$ANUBIS_POLICY"
    sudo nginx -t && sudo systemctl reload nginx
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
