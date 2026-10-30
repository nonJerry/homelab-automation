# Shared constants and helpers, sourced by every script.
# Runs on the server as admin; sudo prompts for a password.

VW_USER=vaultwarden
VW_UID=1007
VW_HOST=${VW_HOST:-vault.example.org}

# Ports, verified free with ss -tlnH before assignment.
PORT_BACKEND=8222       # Vaultwarden, loopback only
PORT_ANUBIS=8925        # Anubis instance "vault"
PORT_ROUTER=8010        # internal nginx router behind Anubis
PORT_METRICS=9094       # Anubis metrics, loopback only

# Pinned by digest; the tag is only there for readability.
VW_IMAGE='docker.io/vaultwarden/server:1.37.3-alpine@sha256:9a905c5cf5df61bb827da3805e160170741c0b53b0c63bb07e1afd3d2e21b1c8'

# Data on the RAID, backups deliberately not: RAID survives a disk failure,
# but not corruption or an accidental rm.
MOUNT=/srv/data
DATA_DIR=$MOUNT/vaultwarden/data
BACKUP_DIR=/var/backups/vaultwarden

STACK_DIR=/opt/vaultwarden
COMPOSE=$STACK_DIR/compose.yaml
ENV_FILE=$STACK_DIR/vaultwarden.env
# One file per secret, read via _FILE, so secrets stay out of the process
# environment and out of "podman inspect".
SECRETS_DIR=$STACK_DIR/secrets
UNIT=podman-compose@vaultwarden.service

NGINX_CONF=/etc/nginx/conf.d/vaultwarden.conf
ANUBIS_ENV=/etc/anubis/vault.env
ANUBIS_POLICY=/etc/anubis/vault.botPolicies.yaml
BACKUP_KEY=/etc/vaultwarden/backup.age.pub

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "== $*"; }
ok() { echo "   ok: $*"; }

confirm() {
    local answer
    read -r -p "$1 [type YES]: " answer
    [[ $answer == YES ]] || die "Aborted."
}

need_sudo() {
    sudo -v || die "sudo authentication failed."
}

# Podman as the stack user. cd / because vaultwarden may not enter /home/admin.
vw_podman() {
    ( cd / && sudo runuser -u "$VW_USER" -- \
        env XDG_RUNTIME_DIR="/run/user/$VW_UID" podman "$@" )
}

vw_systemctl() {
    sudo -u "$VW_USER" XDG_RUNTIME_DIR="/run/user/$VW_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$VW_UID/bus" systemctl --user "$@"
}

# Every script takes --check|--apply|--revert; the default is --check.
MODE=${1:---check}
case $MODE in
    --check|--apply|--revert) ;;
    *) die "Usage: $0 [--check|--apply|--revert]" ;;
esac
