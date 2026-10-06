#!/bin/bash
# The CLI half of docs/release-checklist.md (items 1-3, 5, 6, 8), with no one at the keyboard.
# Put the device away first (another Wi‑Fi, e.g. a phone's hotspot), unlocked with its screen
# on, and quit the RoamRun app and every other bridge (`roamrun down` each: an `up -d` outlives
# its terminal; this refuses to run beside one). Usage:
#   scripts/release-check.sh <device name> <bundle id of an app installed on it>
# ROAMRUN picks the binary (default: the one in RoamRun.app built here by `make app`).
set -u
name=${1:?device name}; bundle=${2:?bundle id}
rr=${ROAMRUN:-$(cd "$(dirname "$0")/.." && pwd)/RoamRun.app/Contents/MacOS/RoamRun}
status_file="$HOME/Library/Application Support/RoamRun/status.json"
failed=0
pass() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failed=1; }
ready_within() { "$rr" status "$name" --wait "$1" >/dev/null 2>&1; }
udid=$("$rr" status "$name" --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else d; print(d.get("udid") or "")')
[ -n "$udid" ] || { echo "no UDID known for $name"; exit 2; }
launch() { xcrun devicectl device process launch --device "$udid" --terminate-existing "$bundle" >/dev/null 2>&1; }
# This device's bridge and its helpers only: another device's are not this check's to kill.
bridge_pid() { "$rr" devices --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys
for d in json.load(sys.stdin):
    if d.get("name") == sys.argv[1] and d.get("pid"): print(d["pid"])' "$name"; }
# A helper runs under a watchdog shell, which is the bridge's child.
parent() { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
helper() {
    local bridge; bridge=$(bridge_pid); [ -n "$bridge" ] || return
    pgrep -f "$1" | while read -r p; do
        [ "$(ps -o comm= -p "$p")" = "$2" ] && [ "$(parent "$(parent "$p")")" = "$bridge" ] && echo "$p"
    done | head -1
}

# Items 5, 6 and 8 kill helpers, remove status.json and count what is left: with another bridge
# running they would break it, or pass on its account.
others=$("$rr" devices --json 2>/dev/null | /usr/bin/python3 -c 'import json,sys
print(", ".join(d["name"] for d in json.load(sys.stdin) if d.get("state") != "off"))')
[ -z "$others" ] || { echo "a bridge is running ($others): stop it first (roamrun down <name>, or quit the app)"; exit 2; }

# 1-3
"$rr" up "$name" -d >/dev/null 2>&1
ready_within 60 && pass "1 up -d, then Ready" || fail "1 not Ready within 60 s"
launch && pass "2 launch" || fail "2 launch"
shot=$(cd "${TMPDIR:-/tmp}" && "$rr" screenshot "$name" 2>/dev/null | grep '\.png$')
[ -s "$shot" ] && pass "3 screenshot: $shot" || fail "3 screenshot"

# 5: each helper killed, Ready again within ~30 s (60 allowed for the tick), then a launch
for h in "log stream:predicate process == \"remotepairingd\":/usr/bin/log" "dns-sd:dns-sd .*-P .*roamrun.local:/usr/bin/dns-sd"; do
    label=${h%%:*}; rest=${h#*:}; pattern=${rest%:*}; comm=${rest##*:}
    pid=$(helper "$pattern" "$comm")
    [ -n "$pid" ] || { fail "5 no $label to kill"; continue; }
    kill "$pid"; sleep 3
    ready_within 60 && pass "5 Ready again after killing $label" || fail "5 not Ready after killing $label"
    launch || launch && pass "5 launch after $label" || fail "5 launch after $label"   # one retry: the first can race the new tunnel
done

# 6 (the CLI half; the takeover from the app needs the app, see the checklist)
rm -f "$status_file"
for _ in $(seq 15); do [ -f "$status_file" ] && break; sleep 1; done
"$rr" status "$name" 2>/dev/null | head -1 | grep -q "Ready for Xcode" && pass "6 status.json written again" \
    || fail "6 status.json not back within 15 s"

# 8
"$rr" down "$name" >/dev/null 2>&1; sleep 3
left=$(ps -ax -o args | grep -E 'dns-sd .*-P .*roamrun.local|predicate process == "remotepairingd"' | grep -cv grep)
[ "$left" -eq 0 ] && pass "8 down leaves nothing behind" || fail "8 $left helper(s) left after down"

exit $failed
