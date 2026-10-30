#!/bin/bash
# Tests the ListenAddress parser of sshd-wait-listen-addrs.
set -euo pipefail
cd "$(dirname "$0")"

input='port 22
listenaddress [2001:db8:f001::10]:22
listenaddress 198.51.100.10:22
listenaddress 0.0.0.0:22
listenaddress [::]:22
addressfamily any'
expected='2001:db8:f001::10
198.51.100.10'

actual=$(./sshd-wait-listen-addrs --parse <<<"$input")
if [[ $actual == "$expected" ]]; then
    echo "ok: parser"
else
    printf 'FAIL: parser\nexpected:\n%s\ngot:\n%s\n' "$expected" "$actual"
    exit 1
fi
