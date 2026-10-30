#!/bin/sh
# Run ON THE PI as root, only after 20-… dry-runs passed.
# Stops the snap's timer, installs a systemd timer for the venv certbot,
# then removes the snap. /etc/letsencrypt is untouched and shared.
set -eu

systemctl disable --now snap.certbot.renew.timer

cat > /etc/systemd/system/certbot-renew.service <<'EOF'
[Unit]
Description=Renew Let's Encrypt certificates (venv certbot + dns-desec)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/certbot/bin/certbot renew --quiet
EOF

cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Twice-daily certbot renewal

[Timer]
OnCalendar=*-*-* 03,15:27:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer
systemctl list-timers certbot-renew.timer --no-pager

echo
echo "Verify the timer works before removing the snap:"
echo "  sudo systemctl start certbot-renew.service && journalctl -u certbot-renew -n 30"
echo "Then, once happy:"
echo "  sudo snap remove certbot"
