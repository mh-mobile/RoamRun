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
   Then, with the app bridging it: delete `status.json` again and at once run
   `roamrun up <name> -d`. The CLI takes the device, and within ~10 s the app
   steps back — only one `dns-sd -P … roamrun.local` for that device is left
   (`ps -ax`). `roamrun down <name>` stops both (the app doesn't take it back).
7. Launch options, with an app that prints `ProcessInfo.processInfo.arguments`,
   its environment and the URL it opens (or check them in the debugger):
   `roamrun run <name> --logs --arg -RRTest --arg yes --env RR_VALUE=123 --url <a URL it handles>`
   → the log shows `-RRTest yes` and `RR_VALUE=123`, the app opens that URL's screen, and
   `roamrun screenshot <name>` shows it.
8. `roamrun down <name>` → no `dns-sd -P … roamrun.local` or `log stream` left (`ps -ax`).

## Two devices, both away (the multi-device path)

9. Bridge both from the app. Launch an app on each, a few times in turn: every
   launch works and each device only gets its own tunnel ports (Technical details).
   Then both at once, 15 rounds: every launch works and both stay Ready.
   `for i in $(seq 15); do for u in <udid1> <udid2>; do xcrun devicectl device process launch --device $u --terminate-existing <bundle id> & done; wait; done`
   Cold, 3 times: quit the app, wait ~20 s (no `dns-sd … roamrun.local` left), reopen it —
   both bridges start and set up their tunnels together — then launch on both at once
   as soon as both are Ready. A CoreDevice error 10004 ("process identifier … could not
   be determined") has so far been the launch racing the app, not the bridge (the device
   answered); retry it, and look closer if it repeats.

## Home

10. Put the device on this Mac's Wi‑Fi: the bridge shows "On this Wi‑Fi" within
   ~10 s, and Xcode still runs on it. Back on the hotspot: Ready again within ~40 s.

## Install paths

11. Download the release dmg in a browser, install, open: it opens with no
    Gatekeeper block (notarized; `spctl -a -vv /Applications/RoamRun.app` says
    "Notarized Developer ID"); the first screen offers the CLI.
12. `brew upgrade --cask roamrun` from the previous version: the app quits,
    is replaced and reopens without another Gatekeeper prompt.
13. Tap: `brew style --cask mh-mobile/tap/roamrun` and
    `brew audit --cask --online mh-mobile/tap/roamrun`. The audit sometimes
    hangs on the download; if so, compare `shasum -a 256` of the published dmg
    with the cask by hand.

## Debug logs worth a look after an iOS or Xcode update

- Home/away decisions: `log stream --level debug --predicate 'subsystem == "io.github.mh-mobile.roamrun" AND category == "home"'`
- Tunnel lookahead hits and port jumps: same with `category == "tunnel"` — misses
  or large jumps mean the relay window (+16 / −32) needs retuning.
