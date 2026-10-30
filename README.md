# homelab-automation

Operational scripts and systemd units from a self-hosted, dual-stack (IPv4 + IPv6) homelab:
a CentOS Stream server running every service as a **rootless Podman stack under its own
system account**, a Raspberry Pi running Pi-hole/Unbound and the certificate automation,
and several OpenWrt access points.

Everything here is in production use. Hostnames, domains and addresses are replaced with
documentation placeholders (`example.org`, `198.51.100.0/24`, `2001:db8::/32`, `router`,
`ap2`, `dnspi`, …).

## Design principles

- **Every installer is idempotent** and offers `--check | --apply | --revert`.
- **Verify the result, not the exit code**: certificate deploys compare the serial actually
  served on the wire, the zone installer queries the resolver before keeping a new zone.
- **Roll back automatically** when verification fails (`dns/subdns-zone-install`,
  `certs/refresh-dot-cert.sh`).
- **Both address families, always**: checks run with `-4` and `-6` explicitly.
- **Secrets never on the command line or in logs**: tokens come from `*_FILE` variables,
  `LoadCredential=` or stdin.

## Layout

| Path | What it does |
|---|---|
| `certs/` | Let's Encrypt wildcard certificate via DNS-01 at deSEC, renewed on the Pi, pushed to routers, Pi-hole and server |
| `certs/deploy-openwrt.sh` | certbot deploy hook: copies the cert to every OpenWrt router (`scp -O` for dropbear) and verifies the served serial |
| `certs/deploy-now.sh` | Push the current cert without renewing (no rate limit consumed) |
| `certs/verify-certs.sh` | Expiry and chain check of the cert each host actually serves, IPv4 and IPv6 |
| `certs/refresh-dot-cert.sh` + `systemd/subdns-cert-sync.*` | A `.path` unit copies each renewal into the DNS-over-TLS container stack, with rollback |
| `certs/migrations/` | One-time move from snap certbot with manual hooks to a venv certbot with the `certbot-dns-desec` plugin and a systemd timer |
| `dns/zone-resign` | Weekly DNSSEC re-signing of the internal zone, then push to the standby resolver |
| `dns/subdns-zone-install` | Validates (SOA, RRSIG) and installs the pushed zone on the standby resolver; rolls back if it stops answering |
| `dns/import.sh` | Bulk-import of the public zone (`rrsets.json`, not included) into deSEC via its API |
| `stacks/podman-compose/` | User-unit template that runs each rootless compose stack, plus a restart drop-in |
| `stacks/vaultwarden/` | Vaultwarden stack: service account, hardened compose file, nginx vhost behind Anubis, fail2ban, age-encrypted backups with retention, automated restore test, test matrix |
| `storage/nextcloud-raid/` | Disk checks, burn-in, RAID1 + LUKS2 + XFS creation, Nextcloud data migration, MariaDB dump (disk scripts take the expected size as `DISK_SIZE_GB=…`) |
| `backup/` | grocy SQLite snapshot backup with test, and the backup timers of all stacks |
| `boot/` | sshd waits until its literal listen addresses are assigned and past DAD; NetworkManager initrd-handover fix |
| `monitoring/` | End-to-end mail-path probe (SMTP with PROXY protocol, SMTPS), alerts to a webhook only after N failures and on recovery |
| `network/` | OpenWrt hotplug guard that restarts Wi-Fi when a recreated bridge breaks 802.11r key exchange |

## Certificate flow

```
certbot (venv, dns-desec)  ── DNS-01 ──>  deSEC
        │ renew_hook
        ├─> Pi-hole web UI + DoT (local)
        ├─> deploy-openwrt.sh ──scp -O──> router, ap2, ap3, ap4  (verify served serial)
        └─> server: /etc/pki/tls  ──.path unit──> refresh-dot-cert.sh ──> DoT stack (verify, else roll back)
```

Renewal and deployment run under a dedicated `certmgr` account with its own SSH key and a
narrow sudoers rule, not under the Pi's admin user.

## Vaultwarden backup key

`stacks/vaultwarden/04-backup.sh` encrypts with [age](https://age-encryption.org). Create
the recipient key before `--apply` and keep the identity file off the server:

```sh
age-keygen -o vw-backup.key        # keep offline
age-keygen -y vw-backup.key        # public recipient, goes into BACKUP_KEY on the server
```

## Tests

Offline tests that need neither root nor the real hosts:

```sh
bash boot/test.sh                  # sshd ListenAddress parser
sh network/test.sh                 # stale-bridge detection against a fake sysfs
bash monitoring/test-mail-watch.sh # alert state machine with a curl stub
bash backup/test-grocy-backup.sh   # backup + retention against a throwaway grocy container (needs podman)
```

CI runs ShellCheck and the first three tests on every push.

## Known limitations

- **Service uids are hard-coded** in the static unit copies (`After=user@<uid>.service`) and in a
  few checks. They match the host the files were taken from; adjust them when reusing.
- **The grocy backup lands on the same RAID array as the live data.** RAID covers a disk
  failure but not filesystem corruption or deletion; the Nextcloud and Vaultwarden backups
  already go to a separate filesystem.
- **Several scripts are host-specific installers**, not a generic tool: paths, account names and
  the nginx/Anubis setup they expect are those of this homelab.

## License

MIT, see [LICENSE](LICENSE).
