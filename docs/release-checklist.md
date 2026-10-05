# Release checklist

Unit tests and CI cover parsing, rules, relays on localhost and the status file.
The bridge itself only proves itself with a real device on another network, so
run this before tagging a release. Use a build of the release commit (a fresh
clone), quit any installed RoamRun first, and keep the device unlocked with its
screen on.

## What to run

Not everything every time. Always: items 1-4, 10, 12-14 (about 15 minutes).
On top, by what the release changed:

| Changed | Run |
|---|---|
| Bridge start/stop, helpers, status file, `up`/`down` | 5, 6, 8 |
| `run`, `logs`, launch options | 7 |
| Relays, tunnel ports, more than one device | 9, 18 |
| Home detection, Local Network | 11 |
| `roamrun ota`, the OTA server or `tailscale serve` | 15 |
| Pausing on cellular, sleep and wake | 16, 17, 18 |
| Device control, its library (`Rust/RoamRunDevice`), `idevice`'s version, the Keychain | 19-26 |
| Windows, menus, accessibility | UI at scale and for everyone |

`scripts/release-check.sh <name> <bundle id>` runs items 1-3, 5, the CLI half of 6, and 8
unattended (device away, app quit) and prints ok/FAIL per step. It kills helpers and removes
the status file, so it refuses to start while any bridge runs: `roamrun down` each first (an
`up -d` outlives its terminal).

Known, not regressions: a device (an iPhone, say) on USB can keep a bridged one from getting
Ready; unplug it. Xcode's session doesn't survive the Mac sleeping for minutes: iOS drops the
tunnel and Xcode has to run again.

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
   And with a `roamrun up <name> -d` running and the app quit: a second `roamrun up <name>`
   exits at once saying the first handles it (exit 0 when Ready or on this Wi‑Fi, 1 while it
   is coming up or retrying), and `<name>.log` in `~/Library/Logs/RoamRun/` is not rotated.
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

11. With the bridge run **from the app** (the checks below read the app's own
   state), turn RoamRun off in System Settings › Privacy & Security › Local Network
   and put the device on this Mac's Wi‑Fi: within ~10 s the window, the activity log,
   `roamrun status` and `roamrun doctor` (a `!` line) all say the local network is
   blocked, and the bridge keeps running. Turn it back on: the notice is gone within
   ~2 minutes and "On this Wi‑Fi" comes back.

## Over the air

15. On a real device — required whenever `roamrun ota` changed, which includes
    the release that introduced it. Store a build, open the printed address on it
    and install. Then check `tailscale serve status` shows one entry on the OTA
    port and nothing else moved, that quitting RoamRun gives it back, that
    force-quitting leaves it behind, and that opening RoamRun again reclaims it.

## Pausing and sleep

16. **Keep debugging on cellular** off, the device bridged away, then on cellular only:
    it shows Waiting for device · Cellular and stays that way for 30+ minutes: no error,
    no port scan in the log. Sleep the Mac for a minute meanwhile: on wake nothing is
    re-registered (no "re-announcing" while paused). Back on a Wi‑Fi: Ready again.
17. With an Xcode debug session running, sleep the Mac for a few seconds: the session
    carries on.
18. **Keep debugging on cellular** on, Ready on another Wi‑Fi, then on cellular only for ten
    minutes, then back on that Wi‑Fi → Ready again within a minute. Afterwards
    `/usr/bin/log show --last 30m --predicate 'subsystem == "io.github.mh-mobile.roamrun" AND (category == "relay" OR category == "status")'`
    shows one `Connection refused … dialing it at most every 3s` line for the spell (not
    one per dial), one `answers again` line at its end, and a `status` line for each
    change, the one on leaving Wi‑Fi with the tunnel relays still open. The `answers again`
    line's count of connections closed without dialing, over the spell's seconds, stays
    around 20 a second: far more means it now spins on the closed connections. (Without
    the hold it was ~12 a second — remotepairingd waits ~50 ms before it redials, and each
    dial took a round trip to the device as well; held, only the wait is left.)

## Device control (a device on iOS 27 or later)

19. No pairing of RoamRun's own yet (remove it on the device's page, and RoamRun's entry on
    the device under Settings › Privacy & Security › Developer Mode), and no key from a build
    signed otherwise (a developer's: the Keychain asks about it for this one —
    `security delete-generic-password -s io.github.mh-mobile.roamrun.device-control`), device on this Mac's
    Wi‑Fi: **Device control › Set Up…**, pick RoamRun on the device, enter the code → the page
    says connected; the Keychain asked nothing; `~/Library/Application Support/RoamRun/`
    holds `device-pairing-<UDID>.sealed` (0600) with no `private_key` in it
    (`grep -c -a private_key` → 0).
    The switch beside **Device control** is on. Switched off: `roamrun look <name>` fails with
    "switched off" and `roamrun status <name>` says so; quit and reopen RoamRun: still off. On
    again: `look` works. On a spare Mac or VM only (it costs the pairing): with RoamRun quit,
    delete the Keychain item for account `pairings` and add one of your own
    (`security add-generic-password -s io.github.mh-mobile.roamrun.device-control -a pairings -w
    $(printf 'x%.0s' {1..32})`), open this release and **Pair Again…** → macOS asks about the
    item (a key another program put there isn't read unasked); deny it. The same for the list of what
    is switched on, with a device that was switched off: with RoamRun quit, delete the item for
    account `allowed` and add one with `-A` (and once with `-T <the app's binary>`) holding
    `["<shasum -a 256 of its device-pairing-<UDID>.sealed>"]`; open RoamRun → macOS asks about the
    item (deny it), and the device's switch reads off. If it reads on without a question, the list
    can be forged: not released so. (`security add-generic-password -s
    io.github.mh-mobile.roamrun.device-control -a allowed -A -w '["<that digest>"]'`; afterwards
    delete that item with `security delete-generic-password -s … -a allowed` and switch on in the app.)
20. `roamrun look <name> /tmp/a.png`, then `tap`, `swipe`, `type`, `paste`, `press home` and
    `elements`, a `look` after each: each did what it says. The same through `roamrun mcp`
    from an agent.
21. Connected on a Wi‑Fi, then that Wi‑Fi off (cellular only): `look` still answers, and a
    minute later too.
22. Quit and reopen RoamRun: connected again without a prompt. Install this release over
    the previous one: the same.
23. Remove RoamRun's entry on the device: `roamrun status <name>` and the page say the
    pairing can no longer be used and offer **Pair Again…**, which works. (If they say instead
    that something else answers at the device's address, this iOS refuses before it proves
    itself: note it — the build then takes a removed pairing for a stranger, and isn't released so.)
    Also with the pairing in place: lock the device, then restart it, and each time before it
    is unlocked look at `roamrun status <name>` — it says not connected (the app keeps trying),
    not that something else answers at the device's address; note it if it does.
24. Into a note, the device's keyboard an English one: `roamrun type <name> "<600 numbered
    characters>"` and a `look` right after — the last of them is there (none still on their
    way); once more in another app's field (a search field, a message draft not sent): the pace
    was measured in a note. Then, each time while `roamrun type <name> "<2000 characters>"` runs:
    switch the device off on its page; interrupt the command (Ctrl-C); **Remove…** the pairing —
    the typing stops within a moment, where it had got to and no further, and the command (where
    it still runs) says it was told to stop. Set it up again, then **Remove Device**: its
    `.sealed` file is gone.
25. `roamrun pairing create <name> ~/k.json --as "RoamRun (check)"`, the code entered on the
    device: the file is written (0600) and the device lists "RoamRun (check)" beside this
    Mac's own entry. On another Mac that reaches the device (or a macOS VM on the tailnet):
    `roamrun pairing import k.json` → the device is in `roamrun devices`, `look` works, the
    file is gone. Remove "RoamRun (check)" on the device: that Mac's `status` says the pairing
    can no longer be used, and this Mac's still connects.
26. On a Mac whose pairing was made by a build before 0.3.0's release (developers' only: no
    release had device control): **Pair Again…** → the device lists a second "RoamRun (…)"
    entry; remove the older one there (it is every idevice-built tool's) → this Mac still
    connects.

## Install paths

12. Download the release dmg in a browser, install, open: it opens with no
    Gatekeeper block (notarized; `spctl -a -vv /Applications/RoamRun.app` says
    "Notarized Developer ID"); the first screen offers the CLI.
13. `brew upgrade --cask roamrun` from the previous version: the app quits,
    is replaced and reopens without another Gatekeeper prompt.
14. Tap: `brew style --cask mh-mobile/tap/roamrun` and
    `brew audit --cask --online mh-mobile/tap/roamrun`. The audit sometimes
    hangs on the download; if so, compare `shasum -a 256` of the published dmg
    with the cask by hand.

## UI at scale and for everyone

- `make app SNAPSHOT=1` (rebuild with plain `make app` afterwards), then
  `MB_FAKE_PROFILES=60 MB_FAKE_DEVICES=40` (see AGENTS.md):
  the sidebar, the Add Device list and the menu scroll instead of running off screen,
  long names truncate instead of pushing buttons away; also at the smallest window size.
- VoiceOver (⌘F5) or Accessibility Inspector on the main window, the Add Device sheet,
  the menu and the menu bar icon: every button says what it does, the chosen device in
  Add Device reads as selected, the connection line reads "Connected" / "Not connected",
  and the menu bar icon reads "RoamRun: <status>". With Reduce Motion on, the status
  icon doesn't spin.

## Debug logs worth a look after an iOS or Xcode update

- What a bridge did and when (kept by the system, no `--level debug`): `log show` with
  `category == "status"`, as in item 18.
- Home/away decisions: `log stream --level debug --predicate 'subsystem == "io.github.mh-mobile.roamrun" AND category == "home"'`
- Tunnel lookahead hits and port jumps: same with `category == "tunnel"` — misses
  or large jumps mean the relay window (+16 / −32) needs retuning.
