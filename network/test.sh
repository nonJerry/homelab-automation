#!/bin/sh
# Tests the stale-bridge detection of wifi-bridge-guard against a fake sysfs tree.
cd "$(dirname "$0")" || exit 1
fail=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

mkdev() { mkdir -p "$T/$1/$2"; echo "$3" > "$T/$1/$2/ifindex"; }
attach() { ln -s "../$3" "$T/$1/$2/master"; }

expect() {
	out=$(NET="$T/$1" sh ./wifi-bridge-guard check); rc=$?
	if [ "$rc" = "$2" ] && [ "$out" = "$3" ]; then echo "ok   $1"
	else echo "FAIL $1: rc=$rc out='$out' (want rc=$2 out='$3')"; fail=1; fi
}

# healthy: bridge older than APs (normal boot order)
mkdev good br-lan 9; mkdev good phy0-ap0 17; mkdev good phy1-ap0 18
attach good phy0-ap0 br-lan; attach good phy1-ap0 br-lan
expect good 0 ok

# router 2026-09-30: br-lan recreated after the APs
mkdev stale br-lan 23; mkdev stale phy0-ap0 17; mkdev stale phy1-ap0 18
attach stale phy0-ap0 br-lan; attach stale phy1-ap0 br-lan
expect stale 1 "phy0-ap0 br-lan
phy1-ap0 br-lan"

# only one AP in a recreated bridge, another in an old one
mkdev mixed br-lan 5; mkdev mixed br-iot 30; mkdev mixed phy0-ap0 20; mkdev mixed phy0-ap1 21
attach mixed phy0-ap0 br-lan; attach mixed phy0-ap1 br-iot
expect mixed 1 "phy0-ap1 br-iot"

# AP not in any bridge (mid-reattach) is ignored
mkdev loose br-lan 40; mkdev loose phy0-ap0 17
expect loose 0 ok

# numeric, not lexical, comparison (9 < 17)
mkdev numeric br-lan 9; mkdev numeric phy0-ap0 100
attach numeric phy0-ap0 br-lan
expect numeric 0 ok

exit $fail
