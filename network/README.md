# wifi-bridge-guard

Installed on router, ap2 and ap3 (OpenWrt). Keeps inter-AP 802.11r (FT) working on the WPA3 SSID after a LuCI/uci change recreates `br-lan`.

## Problem

hostapd binds its FT key-exchange socket (RRB, ethertype 0x890d) to the bridge's ifindex when the BSS starts. If netifd later destroys and recreates the bridge, it silently moves the AP interfaces into the new bridge without restarting hostapd. hostapd keeps sending to the old ifindex (`l2_packet_send - send: No such device or address`), and every roam onto that AP falls back to a full SAE handshake, which means several seconds to minutes without connectivity.

Only the WPA3-SAE SSID is affected: with SAE the PMK exists only on the AP where the client authenticated, so FT has to fetch it over RRB. The WPA2-PSK SSID derives the key locally (`ft_psk_generate_local=1`).

Detection: an AP interface whose bridge (`/sys/class/net/<ap>/master`) has a higher ifindex than the AP interface itself.

## Files

| Device path | Source | Purpose |
|---|---|---|
| `/usr/sbin/wifi-bridge-guard` | `wifi-bridge-guard` | `check` reports stale bindings (exit 1). `fix` rechecks after 10 s and runs `wifi down; wifi up` if the problem persists. `delayed` waits 20 s and then runs `fix`. |
| `/etc/hotplug.d/net/90-wifi-bridge-guard` | `90-wifi-bridge-guard` | Runs `delayed` detached whenever a bridge device is added. |
| `/etc/crontabs/root` | — | `*/5 * * * * /usr/sbin/wifi-bridge-guard fix` as a fallback. |
| `/etc/sysupgrade.conf` | — | Lists both files so they survive owut/sysupgrade. The crontab is kept by default. |

All actions are logged with tag `wifi-bridge-guard`: `logread -e wifi-bridge-guard`.

## Cost

A restart only happens when the stale state is actually present. When it does, the AP's Wi-Fi drops for about 10 s. On ap3 and ap2, 5 GHz also needs a 60 s DFS CAC because they run on DFS channels.

## Install / update

```sh
for h in router ap2 ap3; do
  scp -O wifi-bridge-guard root@$h.example.org:/usr/sbin/wifi-bridge-guard
  scp -O 90-wifi-bridge-guard root@$h.example.org:/etc/hotplug.d/net/90-wifi-bridge-guard
  ssh root@$h.example.org 'chmod 755 /usr/sbin/wifi-bridge-guard
    grep -qx /usr/sbin/wifi-bridge-guard /etc/sysupgrade.conf || echo /usr/sbin/wifi-bridge-guard >> /etc/sysupgrade.conf
    grep -qx /etc/hotplug.d/net/90-wifi-bridge-guard /etc/sysupgrade.conf || echo /etc/hotplug.d/net/90-wifi-bridge-guard >> /etc/sysupgrade.conf
    grep -q wifi-bridge-guard /etc/crontabs/root || echo "*/5 * * * * /usr/sbin/wifi-bridge-guard fix" >> /etc/crontabs/root
    /etc/init.d/cron restart'
done
```

## Tests

`sh test.sh` checks the detection logic against a fake sysfs tree.
