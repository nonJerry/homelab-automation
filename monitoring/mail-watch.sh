#!/bin/bash
# Runs a probe and reports outage and recovery to a Discord webhook.
# Usage: mail-watch.sh <label> <probe command> [args ...]
set -u

label=$1
shift
state_dir=${STATE_DIRECTORY:-/var/lib/mail-watch}
threshold=${MAIL_WATCH_THRESHOLD:-10}
webhook=$(<"$CREDENTIALS_DIRECTORY/webhook")
fails_file=$state_dir/fails
since_file=$state_dir/since
down_file=$state_dir/down

notify() {
    # URL via stdin rather than as an argument, otherwise it shows up in /proc/*/cmdline.
    printf 'url = "%s"\n' "$webhook" | curl -fsS --max-time 15 -K - \
        -H 'Content-Type: application/json' \
        -d "{\"username\": \"Mail Watch\", \"content\": \"$1\"}" >/dev/null
}

if timeout 30 "$@"; then
    if [[ -e $down_file ]]; then
        notify "$label reachable again (down since $(<"$since_file"))" && rm -f "$down_file"
    fi
    echo 0 >"$fails_file"
    exit 0
fi

fails=0
[[ -r $fails_file ]] && fails=$(<"$fails_file")
fails=$((fails + 1))
echo "$fails" >"$fails_file"
((fails == 1)) && date '+%F %H:%M' >"$since_file"

if ((fails >= threshold)) && [[ ! -e $down_file ]]; then
    # Mark as reported only after a successful send, so the next run retries.
    notify "@everyone $label unreachable since $(<"$since_file")" && touch "$down_file"
fi
exit 1
