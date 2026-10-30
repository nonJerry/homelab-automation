#!/usr/bin/env bash
# Checks the cert actually served by every host, both families.
# Runs correctly on the pi too: the custom /usr/local/openssl-4 build has no
# CA store, which made every host read as INVALID in the previous version.
set -u
CA=""
for c in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
  [ -r "$c" ] && { CA="-CAfile $c"; break; }
done

printf '%-28s %-4s %-26s %s\n' HOST FAM NOT_AFTER RESULT
check() {
  local host=$1 port=$2 fam=$3 extra=$4 out enddate
  out=$(timeout 12 openssl s_client -"$fam" -connect "$host:$port" $extra $CA </dev/null 2>&1)
  enddate=$(printf '%s' "$out" | openssl x509 -noout -enddate 2>/dev/null)
  enddate=${enddate#notAfter=}
  if [ -z "$enddate" ]; then
    printf '%-28s %-4s %-26s %s\n' "$host:$port" "v$fam" "-" "NO CERT / UNREACHABLE"
  elif printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
    printf '%-28s %-4s %-26s %s\n' "$host:$port" "v$fam" "$enddate" "OK"
  else
    printf '%-28s %-4s %-26s %s\n' "$host:$port" "v$fam" "$enddate" "*** INVALID ***"
  fi
}

for f in 4 6; do
  for h in router ap2 ap3 ap4 hole sub-hole cloud nas dashboard office; do
    check "$h.example.org" 443 "$f" "-servername $h.example.org"
  done
  check dns.example.org 853 "$f" ""
  echo
done
