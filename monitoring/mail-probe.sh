#!/bin/bash
# Probes the mail path. "home": from the VPS through the tunnel to Stalwart.
# "vps": from the server over the internet to the VPS and back to Stalwart.
set -u

case ${1:-} in
home)
    exec 3<>/dev/tcp/10.0.100.2/2525 || exit 1
    # PROXY v2 header as sent by HAProxy: TCP4 10.0.100.1:0 -> 10.0.100.2:25
    printf '\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c\x0a\x00\x64\x01\x0a\x00\x64\x02\x00\x00\x00\x19' >&3
    read -r -t 10 line <&3 && [[ $line == 220* ]] || exit 1
    printf 'QUIT\r\n' >&3
    ;;
vps)
    # Fixed IP so a local DNS outage is not reported as a VPS outage.
    # openssl instead of curl: libcurl-minimal on EL10 has no smtps.
    printf 'QUIT\r\n' | timeout 20 openssl s_client -quiet -connect 203.0.113.25:465 \
        -servername mail.example.net -verify_hostname mail.example.net -verify_return_error 2>/dev/null \
        | grep -q '^220 '
    ;;
*)
    echo "usage: $0 home|vps" >&2
    exit 2
    ;;
esac
