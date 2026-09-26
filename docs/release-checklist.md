# Release checklist

Unit tests and CI cover parsing, rules, relays on localhost and the status file.
The bridge itself only proves itself with a real device on another network, so
run this before tagging a release. Use a build of the release commit (a fresh
clone), quit any installed RoamRun first, and keep the device unlocked with its
screen on.

## One device, away (e.g. on a phone's hotspot)

1. `roamrun up <name> -d`, then `roamrun status <name> --wait 60` → Ready (exit 0).
2. `xcrun devicectl device process launch --device <udid> <bundle id>` → the app starts.
3. `roamrun screenshot <name>` → a PNG of the device's screen.
4. Xcode: Run with a breakpoint → it stops there.
5. Kill the bridge's `log stream`, then its `dns-sd -P` (`ps -ax | grep roamrun.local`):
   each time the bridge shows the error and is Ready again within ~30 s; launch again.
6. Delete `~/Library/Application Support/RoamRun/status.json` while it's Ready:
   `roamrun status <name>` shows it again within ~10 s.
7. `roamrun down <name>` → no `dns-sd -P … roamrun.local` or `log stream` left (`ps -ax`).

## Two devices, both away (the multi-device path)

8. Bridge both from the app. Launch an app on each, a few times in turn: every
   launch works and each device only gets its own tunnel ports (Technical details).
   Then both at once, 15 rounds: every launch works and both stay Ready.
   `for i in $(seq 15); do for u in <udid1> <udid2>; do xcrun devicectl device process launch --device $u --terminate-existing <bundle id> & done; wait; done`

## Home

9. Put the device on this Mac's Wi‑Fi: the bridge shows "On this Wi‑Fi" within
   ~10 s, and Xcode still runs on it. Back on the hotspot: Ready again within ~40 s.

## Install paths

10. Download the release dmg in a browser, install, open: Gatekeeper blocks it
    once; Open Anyway works; the first screen offers the CLI.
11. `brew upgrade --cask roamrun` from the previous version: the app quits,
    is replaced and reopens without another Gatekeeper prompt.
12. Tap: `brew style --cask mh-mobile/tap/roamrun` and
    `brew audit --cask --online mh-mobile/tap/roamrun`. The audit sometimes
    hangs on the download; if so, compare `shasum -a 256` of the published dmg
    with the cask by hand.

## Debug logs worth a look after an iOS or Xcode update

- Home/away decisions: `log stream --level debug --predicate 'subsystem == "com.roamrun.app" AND category == "home"'`
- Tunnel lookahead hits and port jumps: same with `category == "tunnel"` — misses
  or large jumps mean the relay window (+16 / −32) needs retuning.
