#!/usr/bin/env bash
# Writes compose.yaml and the env skeleton, registers the unit and starts the
# stack -- loopback only, nginx follows in 03.
set -euo pipefail
cd "$(dirname "$0")" && . ./common.sh

# Must be replaced by hand; the stack is not started while any remain.
PLACEHOLDER='PLEASE-FILL-IN'

check() {
    info "Files"
    [[ -f $COMPOSE ]] && ok "$COMPOSE ($(stat -c '%a %U:%G' "$COMPOSE"))" || echo "   missing: $COMPOSE"
    if [[ -f $ENV_FILE ]]; then
        ok "$ENV_FILE ($(stat -c '%a %U:%G' "$ENV_FILE"))"
        # Only read key names, never values -- values do not belong in any log.
        if sudo grep -q "$PLACEHOLDER" "$ENV_FILE"; then
            echo "   OPEN: placeholders left in $(sudo grep -c "$PLACEHOLDER" "$ENV_FILE") line(s):"
            sudo grep -l "$PLACEHOLDER" "$ENV_FILE" >/dev/null
            sudo grep "$PLACEHOLDER" "$ENV_FILE" | cut -d= -f1 | sed 's/^/     /'
        else
            ok "no placeholders left"
        fi
        # "|| true": a finding must not abort --check via set -e.
        check_env_keys && ok "all required keys present" || true
    else
        echo "   missing: $ENV_FILE"
    fi

    info "Secrets"
    # Only permissions and size -- the content is never read.
    if sudo test -d "$SECRETS_DIR"; then
        ok "$SECRETS_DIR ($(sudo stat -c '%a %U:%G' "$SECRETS_DIR"))"
        for s in admin_token smtp_password; do
            if sudo test -f "$SECRETS_DIR/$s"; then
                if sudo grep -q "$PLACEHOLDER" "$SECRETS_DIR/$s"; then
                    echo "   OPEN: $s is still a placeholder"
                else
                    printf '   ok: %-14s %s, %s bytes\n' "$s" \
                        "$(sudo stat -c '%a %U:%G' "$SECRETS_DIR/$s")" \
                        "$(sudo stat -c '%s' "$SECRETS_DIR/$s")"
                fi
            else
                echo "   missing: $s"
            fi
        done
    else
        echo "   missing: $SECRETS_DIR"
    fi

    info "Image"
    vw_podman image exists "$VW_IMAGE" 2>/dev/null && ok "image present locally" \
        || echo "   missing: image not pulled yet"

    info "Service"
    sudo test -f "/home/$VW_USER/.config/containers/compose/projects/vaultwarden.env" \
        && ok "registered" || echo "   missing: registration (podman-compose systemd -a register)"
    vw_systemctl is-enabled "$UNIT" 2>/dev/null | sed 's/^/   enabled: /' || echo "   not enabled"
    vw_systemctl is-active "$UNIT" 2>/dev/null | sed 's/^/   active: /' || true

    info "Backend reachable?"
    curl -fsS -m 5 "http://127.0.0.1:$PORT_BACKEND/alive" >/dev/null 2>&1 \
        && ok "/alive responds on 127.0.0.1:$PORT_BACKEND" \
        || echo "   no response on 127.0.0.1:$PORT_BACKEND"
}

write_compose() {
    sudo tee "$COMPOSE" >/dev/null <<EOF
# Deliberately holds no secrets, only paths. Each value lives in its own file
# under $SECRETS_DIR and is mounted to /run/secrets/<name> (ro, rbind);
# Vaultwarden reads it via the *_FILE variables in vaultwarden.env.
secrets:
  admin_token:
    file: $SECRETS_DIR/admin_token
    # podman-compose otherwise mounts secrets without an SELinux label, which
    # makes them unreadable inside the container under enforcing.
    x-podman.relabel: z
  smtp_password:
    file: $SECRETS_DIR/smtp_password
    x-podman.relabel: z

services:
  vaultwarden:
    image: $VW_IMAGE
    restart: unless-stopped
    env_file: $ENV_FILE
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=32m
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges
    mem_limit: 512m
    pids_limit: 200
    # :z, not :Z -- the backup script accesses the same directory from the host,
    # and :Z would rewrite its label every time.
    secrets:
      - admin_token
      - smtp_password
    volumes:
      - $DATA_DIR:/data:z
    ports:
      - "127.0.0.1:$PORT_BACKEND:8080"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8080/alive"]
      interval: 60s
      timeout: 5s
      retries: 3
EOF
    sudo chown root:root "$COMPOSE"
    sudo chmod 0644 "$COMPOSE"
}

write_env() {
    [[ -f $ENV_FILE ]] && { ok "$ENV_FILE exists, left unchanged"; return; }
    sudo install -m 0640 -o root -g "$VW_USER" /dev/null "$ENV_FILE"
    sudo tee "$ENV_FILE" >/dev/null <<EOF
# 0640 root:$VW_USER -- admin may not read this.
# Rule for this stack: configuration lives ONLY here. The admin panel is used
# for actions only (invite, delete, reset 2FA), never for settings -- otherwise
# it writes data/config.json, which overrides this file.

DOMAIN=https://$VW_HOST

# The image listens on 80 by default, which fails with EACCES under
# cap_drop: ALL. Hence a port above 1024.
ROCKET_PORT=8080

# --- Registration: closed, invitation only ---
SIGNUPS_ALLOWED=false
SIGNUPS_VERIFY=true
# SIGNUPS_DOMAINS_WHITELIST stays EMPTY. It is not an extra gate but a door
# opener: once set, it overrides SIGNUPS_ALLOWED=false and anyone with an
# address at one of those domains can self-register.
#   is_signup_allowed() in config.rs 1540ff:
#   "The whitelist setting overrides the signups_allowed setting."
# It would also restrict org invites, emergency contacts and email changes to
# those domains, but the price is open self-registration -- a bad trade for a
# known set of users.
INVITATIONS_ALLOWED=true
INVITATION_EXPIRATION_HOURS=24
INVITATION_ORG_NAME=example

# --- Admin panel ---
# The Argon2 PHC string lives in secrets/admin_token, not here. That keeps it
# out of "podman inspect" and the process environment, and avoids the question
# of whether podman-compose expands its many \$ signs.
ADMIN_TOKEN_FILE=/run/secrets/admin_token
ADMIN_RATELIMIT_SECONDS=600
ADMIN_RATELIMIT_MAX_BURST=2
ADMIN_SESSION_LIFETIME=10

# --- Account and authentication ---
PASSWORD_HINTS_ALLOWED=false
EMAIL_CHANGE_ALLOWED=false
REQUIRE_DEVICE_EMAIL=true
EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE=true
EMERGENCY_ACCESS_ALLOWED=false
# Empty or "all" = anyone may create organizations, "none" = nobody, otherwise
# comma-separated email addresses. Only your account should own the org that
# carries the 2FA policy.
ORG_CREATION_USERS=$PLACEHOLDER
TRASH_AUTO_DELETE_DAYS=30

# --- Rate limits: generous for a handful of people ---
LOGIN_RATELIMIT_MAX_BURST=5
UNAUTHENTICATED_RATELIMIT_MAX_BURST=20

# --- Logging: to journald, no LOG_FILE. EXTENDED_LOGGING is required
#     by the fail2ban filters. ---
EXTENDED_LOGGING=true
LOG_LEVEL=info

# --- Proxy. IP_HEADER must match what nginx sets, otherwise fail2ban bans
#     the proxy instead of the attacker. 90-verify.sh measures this rather
#     than guessing. ---
IP_HEADER=X-Real-IP

# --- Icons: the fetcher is the only outbound connection in the product ---
ICON_SERVICE=internal
HTTP_REQUEST_BLOCK_NON_GLOBAL_IPS=true
HTTP_REQUEST_BLOCK_REGEX=^(.*\\.)?(local|home|lan|internal)$|^(192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|10\\.)|^fd

# --- Mail via Stalwart ---
# SMTP_FROM is a full sender address, not a domain:
#   right  vault@example.com
#   wrong  example.com
# The domain must be one Stalwart accepts (example.net or example.com), not
# example.org. SMTP_USERNAME is the Stalwart account name -- Stalwart enforces
# "sender = account".
SMTP_HOST=mail.example.net
SMTP_PORT=465
SMTP_SECURITY=force_tls
SMTP_FROM=$PLACEHOLDER
SMTP_FROM_NAME=example Vault
SMTP_USERNAME=$PLACEHOLDER
SMTP_PASSWORD_FILE=/run/secrets/smtp_password

# --- Off: decided against, or unused code paths ---
PUSH_ENABLED=false
SSO_ENABLED=false
EOF
}

# Checks key names only, never values. Returns 1 if anything is missing.
check_env_keys() {
    local missing=() k
    for k in DOMAIN ROCKET_PORT SIGNUPS_ALLOWED ADMIN_TOKEN_FILE; do
        sudo grep -qE "^$k=" "$ENV_FILE" || missing+=("$k")
    done
    # SMTP is optional, but half-configured Vaultwarden aborts with
    # "Both SMTP_USERNAME and SMTP_PASSWORD need to be set".
    if sudo grep -qE '^SMTP_(HOST|USERNAME)=' "$ENV_FILE"; then
        for k in SMTP_HOST SMTP_FROM SMTP_USERNAME SMTP_PASSWORD_FILE; do
            sudo grep -qE "^$k=" "$ENV_FILE" || missing+=("$k")
        done
    fi
    # Catch what Vaultwarden would only reject at startup: SMTP_FROM must be an address.
    if sudo grep -qE '^SMTP_FROM=' "$ENV_FILE" \
       && ! sudo grep -qE '^SMTP_FROM=[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}' "$ENV_FILE"; then
        echo "   ERROR: SMTP_FROM is not a full address." >&2
        echo "     expected e.g. vault@example.com, not just the domain" >&2
        return 1
    fi

    (( ${#missing[@]} == 0 )) && return 0

    echo "   MISSING in $ENV_FILE:" >&2
    printf '     %s\n' "${missing[@]}" >&2
    cat >&2 <<EOF

   The env file is never overwritten once it exists, so it may come from an
   older version of this script. Add the keys with
   'sudoedit $ENV_FILE', typically:
     ADMIN_TOKEN_FILE=/run/secrets/admin_token
     SMTP_PASSWORD_FILE=/run/secrets/smtp_password
   Or move the file away and let it be regenerated (values are lost):
     sudo mv $ENV_FILE $ENV_FILE.alt && $0 --apply
EOF
    return 1
}

write_secrets() {
    sudo install -d -m 0700 -o "$VW_USER" -g "$VW_USER" "$SECRETS_DIR"
    for s in admin_token smtp_password; do
        sudo test -f "$SECRETS_DIR/$s" && continue
        # 0400 owned by the stack user: rootless maps container root to exactly
        # this user, so nothing more is needed.
        printf '%s' "$PLACEHOLDER" | sudo install -m 0400 -o "$VW_USER" -g "$VW_USER" \
            /dev/stdin "$SECRETS_DIR/$s"
    done
    # No chcon needed: "x-podman.relabel: z" in compose.yaml relabels on every mount.
}

apply() {
    need_sudo
    id "$VW_USER" &>/dev/null || die "User $VW_USER missing. Run 01-create-stack.sh first."

    if sudo test -f "$ENV_FILE"; then
        # get_env_str_value panics if both KEY and KEY_FILE are set.
        for k in ADMIN_TOKEN SMTP_PASSWORD; do
            sudo grep -qE "^$k=" "$ENV_FILE" \
                && die "$ENV_FILE sets both $k AND ${k}_FILE. Vaultwarden aborts on that -- remove the $k= line."
        done
        # An existing env file is never overwritten, so it may come from an older
        # version of this script and lack keys.
        check_env_keys || die "Missing keys in $ENV_FILE -- see above."
    fi

    write_compose
    write_env
    write_secrets

    local unfilled=0
    sudo grep -q "$PLACEHOLDER" "$ENV_FILE" && unfilled=1
    for s in admin_token smtp_password; do
        sudo grep -q "$PLACEHOLDER" "$SECRETS_DIR/$s" 2>/dev/null && unfilled=1
    done

    if (( unfilled )); then
        echo
        echo "Skeleton written. Still open in $ENV_FILE:"
        sudo grep "$PLACEHOLDER" "$ENV_FILE" | cut -d= -f1 | sed 's/^/  /'
        echo
        echo "Secrets live in separate files under $SECRETS_DIR so they do not"
        echo "show up in the process environment or in 'podman inspect'."
        echo "Fill them in without going through the shell history:"
        echo
        echo "  # Admin token: the binary prompts for it, never pass it as an argument"
        echo "  podman run --rm -it $VW_IMAGE /vaultwarden hash"
        echo "  sudo install -m 0400 -o $VW_USER -g $VW_USER /dev/null $SECRETS_DIR/admin_token"
        echo "  sudoedit $SECRETS_DIR/admin_token       # paste the PHC string"
        echo
        echo "  # SMTP password of your own Stalwart account"
        echo "  sudoedit $SECRETS_DIR/smtp_password"
        echo
        echo "Vaultwarden trims the file content (util.rs, get_env_str_value), so a"
        echo "trailing newline is fine -- a password with leading or trailing spaces"
        echo "is not. Then:"
        echo "  sudoedit $ENV_FILE   # remaining placeholders"
        echo
        echo "NO CONTAINER IS RUNNING YET. Running the same command again will find"
        echo "no placeholders and start the stack:"
        echo "  $0 --apply"
        return
    fi

    vw_podman pull "$VW_IMAGE"

    # "podman-compose up" only STARTS an existing container without recreating it,
    # so it would keep a stale environment. The data lives in the bind mount.
    vw_systemctl stop "$UNIT" 2>/dev/null || true
    ( cd "$STACK_DIR" && sudo runuser -u "$VW_USER" -- \
        env XDG_RUNTIME_DIR="/run/user/$VW_UID" podman-compose down ) 2>/dev/null || true

    # "systemd -a register" only writes this one file but always prints its notice,
    # which would bury the real output on every run.
    local reg_file="/home/$VW_USER/.config/containers/compose/projects/vaultwarden.env"
    if sudo test -f "$reg_file"; then
        ok "project already registered"
    else
        ( cd "$STACK_DIR" && sudo runuser -u "$VW_USER" -- \
            env XDG_RUNTIME_DIR="/run/user/$VW_UID" podman-compose systemd -a register )
    fi
    vw_systemctl daemon-reload
    vw_systemctl enable --now "$UNIT"

    echo "waiting for /alive ..."
    for _ in $(seq 30); do
        curl -fsS -m 2 "http://127.0.0.1:$PORT_BACKEND/alive" >/dev/null 2>&1 && break
        sleep 2
    done
    echo
    check
}

revert() {
    need_sudo
    confirm "Stop the stack and remove compose.yaml/env? $DATA_DIR is kept"
    vw_systemctl disable --now "$UNIT" 2>/dev/null || true
    sudo rm -f "$COMPOSE" "$ENV_FILE"
}

case $MODE in
    --check) check ;;
    --apply) apply ;;
    --revert) revert ;;
esac
