#!/usr/bin/env bash
# Runs the test matrix over both address families and prints a table.
# Runs from the workstation (LAN side of each rule); the outside view must come
# from the VPS -- the command for that is printed at the end.
set -uo pipefail
cd "$(dirname "$0")" && . ./common.sh 2>/dev/null || VW_HOST=vault.example.org

BASE="https://$VW_HOST"
# curl's default "curl/8.x" UA does NOT match the Mozilla rule, so every row runs
# twice, with and without a browser UA; testing only without skips the rule.
UA_BROWSER='Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0'

fails=0
backend_down=0

probe() { # name fam method path ua expectation [body]
    local name=$1 fam=$2 method=$3 path=$4 ua=$5 want=$6 body=${7:-}
    local out code ctype label
    local -a args=(-"$fam" -sS -m 10 -o /dev/null -X "$method"
                   -w '%{http_code} %{content_type}')
    if [[ -n $ua ]]; then args+=(-A "$ua"); label=Mozilla; else label="no UA"; fi
    # Without Content-Type Rocket returns 415, which says nothing about Anubis.
    # client_credentials never reaches the password check, so fail2ban counts no failed login.
    [[ -n $body ]] && args+=(-H 'Content-Type: application/x-www-form-urlencoded' -d "$body")

    out=$(curl "${args[@]}" "$BASE$path" 2>/dev/null)
    code=${out%% *}; ctype=${out#* }
    [[ -z $code || $code == 000 ]] && code="closed"

    local got verdict
    case $want in
        json)      got="$code ${ctype%%;*}"; [[ $code == 2* || $code == 4* ]] && [[ $ctype == application/json* ]] && verdict=OK || verdict=FAIL ;;
        html)      got="$code ${ctype%%;*}"; [[ $code == 2* ]] && [[ $ctype == text/html* ]] && verdict=OK || verdict=FAIL ;;
        ok)        got="$code"; [[ $code == 200 ]] && verdict=OK || verdict=FAIL ;;
        closed)    got="$code"; [[ $code == closed || $code == 444 ]] && verdict=OK || verdict=FAIL ;;
        *)         got="$code"; verdict="?" ;;
    esac
    # A 5xx never passes: an nginx error page is text/html too, and a check that
    # reports green on a dead service is worse than none.
    if [[ $code == 5* ]]; then verdict=FAIL; (( backend_down++ )); fi
    [[ $verdict == FAIL ]] && (( fails++ ))
    printf '  %-28s v%s  %-9s %-22s %s\n' "$name" "$fam" "$label" "$got" "$verdict"
}

echo "Test matrix $BASE  (LAN side; expected values see README.md)"
echo
for fam in 4 6; do
    echo "--- IPv$fam ---"
    # Client paths must return JSON regardless of UA; HTML means Anubis is wrongly in front.
    probe "/api/config"        "$fam" GET  /api/config            ""           json
    probe "/api/config"        "$fam" GET  /api/config            "$UA_BROWSER" json
    probe "/identity/.../token" "$fam" POST /identity/connect/token ""           json grant_type=client_credentials
    probe "/identity/.../token" "$fam" POST /identity/connect/token "$UA_BROWSER" json grant_type=client_credentials
    # Web vault: must show the challenge.
    probe "/ (web vault)"      "$fam" GET  /                      "$UA_BROWSER" html
    # LAN only.
    probe "/alive (LAN)"       "$fam" GET  /alive                 ""           ok
    probe "/admin (LAN)"       "$fam" GET  /admin                 "$UA_BROWSER" html
    # Always closed.
    probe "/events/"           "$fam" GET  /events/               ""           closed
    echo
done

echo "--- DNS ---"
for t in A AAAA; do
    printf '  internal %-4s %s\n' "$t" "$(dig +short "$t" "$VW_HOST" | tr '\n' ' ')"
    printf '  external %-4s %s\n' "$t" "$(dig +short @9.9.9.9 "$t" "$VW_HOST" | tr '\n' ' ')"
done

echo
echo "--- Certificate ---"
for fam in 4 6; do
    printf '  v%s  %s\n' "$fam" "$(echo | timeout 10 openssl s_client -"$fam" \
        -servername "$VW_HOST" -connect "$VW_HOST:443" 2>/dev/null \
        | openssl x509 -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
done

cat <<EOF

--- From outside (run on the vps-provider VPS) ---
The workstation cannot test these cells: from the LAN the name resolves to the
internal addresses. /alive and /admin MUST be rejected from outside.

  for f in 4 6; do for p in /api/config / /alive /admin; do
    printf '%s v%s -> ' "\$p" "\$f"
    curl -\$f -sS -m 10 -o /dev/null -w '%{http_code}\n' \\
      -A '$UA_BROWSER' https://$VW_HOST\$p || echo closed
  done; done

Expected: /api/config 200, / 200 (challenge), /alive and /admin rejected.

--- Cross-check IP_HEADER (on the server) ---
Until this shows the real client IP, fail2ban bans the proxy:

  journalctl -n 50 CONTAINER_NAME=vaultwarden_vaultwarden_1 | grep -oE 'IP: [0-9a-fA-F:.]+'
EOF

echo
if (( backend_down )); then
    cat <<'EOF'
Note: the 5xx cells mean "nginx is up, backend does not respond".
The run is still meaningful: / cells with 200 prove Anubis responds, and 502
on /api/ proves those paths bypass Anubis -- otherwise the same challenge would
appear there. Check the backend:
  curl -fsS http://127.0.0.1:8222/alive
  sudo -u vaultwarden XDG_RUNTIME_DIR=/run/user/1007 \
    systemctl --user status podman-compose@vaultwarden.service
EOF
fi
if (( fails )); then
    echo "$fails cell(s) not as expected."
    exit 1
fi
echo "All tested cells as expected."
