#!/bin/bash
# Tests the state machine of mail-watch.sh against a curl stub.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/state" "$tmp/cred"
echo "https://example.invalid/hook" >"$tmp/cred/webhook"
cat >"$tmp/bin/curl" <<'EOF'
#!/bin/bash
[[ -e $CURL_FAIL ]] && exit 22
printf '%s\n' "$*" >>"$CURL_LOG"
cat >>"$CURL_STDIN"
EOF
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH" STATE_DIRECTORY="$tmp/state" CREDENTIALS_DIRECTORY="$tmp/cred"
export MAIL_WATCH_THRESHOLD=3 CURL_LOG="$tmp/curl.log" CURL_FAIL="$tmp/curl.fail" CURL_STDIN="$tmp/curl.stdin"
: >"$CURL_LOG"

failures=0
run() { "$here/mail-watch.sh" testtarget "$@" >/dev/null 2>&1; }
sent() { wc -l <"$CURL_LOG"; }
check() {
    if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected $3, got $2"; failures=$((failures + 1)); fi
}

run true
check "healthy sends nothing" "$(sent)" 0

run false; run false
check "no alert below threshold" "$(sent)" 0
run false
check "one alert at threshold" "$(sent)" 1
grep -q '@everyone testtarget unreachable since' "$CURL_LOG"
check "outage text" $? 0
grep -q 'example.invalid' "$CURL_LOG"
check "webhook not in arguments" $? 1
grep -qx 'url = "https://example.invalid/hook"' "$CURL_STDIN"
check "webhook passed via stdin" $? 0
run false; run false
check "no repeat during outage" "$(sent)" 1

run true
check "recovery reported" "$(sent)" 2
grep -q 'testtarget reachable again (down since' "$CURL_LOG"
check "recovery text" $? 0
run true
check "quiet afterwards" "$(sent)" 2

touch "$CURL_FAIL"
run false; run false; run false
check "failed send does not mark as reported" "$([[ -e $tmp/state/down ]] && echo yes || echo no)" no
rm "$CURL_FAIL"
run false
check "next run retries the send" "$(sent)" 3

run true
check "probe ok, exit code" $? 0
run false
check "probe failed, exit code" $? 1

exit $((failures > 0))
