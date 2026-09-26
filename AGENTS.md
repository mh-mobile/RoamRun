# Working on RoamRun

Guidance for agents changing this repository. (To *use* RoamRun from an agent,
see `skills/roamrun/SKILL.md` — installed with `roamrun init` or
`npx skills add mh-mobile/RoamRun`.)

## Build & run

- `make app` builds `RoamRun.app` (menu bar app and `roamrun` CLI in one binary);
  `make run` also launches it. Don't call `swift build` directly — `make` pins
  Xcode's toolchain and stamps the real SDK version (needed for Liquid Glass).
- `make install-cli` links `/usr/local/bin/roamrun` to the build in the repo
  folder (for development; the app's first screen / Settings link the copy that
  is running, e.g. `/Applications`). `make dmg` packages.
- `make test` runs the unit tests (log parsing, port attribution, status-file
  ownership, names). They never touch the real status/profile files or start a
  bridge — keep it that way (no `AppCoordinator` in tests).
- Only one RoamRun app runs at a time (matched by bundle id): a dev build won't
  start while an installed copy is running — quit that one first.
- UI screenshots without screen-recording rights: build with `make app SNAPSHOT=1`
  (dev only — rebuild with plain `make app` afterwards), then
  `MB_SNAPSHOT=/tmp/x.png [MB_SNAPSHOT_SHEET=add|settings] [MB_APPEARANCE=dark] RoamRun.app/Contents/MacOS/RoamRun`
  (Liquid Glass surfaces don't render in these; ask the user for a real screenshot.)

## Verify on a real iPhone before calling a change done

The bridge only proves itself end to end. After touching the relay, bridge,
watcher or CLI, check with the iPhone unlocked and its screen on:

1. `roamrun status <name> --wait 60` → ready
2. `xcrun devicectl device process launch --device <udid> <bundle id>`
3. lldb attach + a breakpoint hit (`device select`, `device process attach`)
4. `roamrun up <name> -d` / `down` leave no `dns-sd -P` or `log stream` behind

If `doctor` says the iPhone is asleep, ask the user to unlock it — that's not a
code bug.

Home/away decisions (bridge vs. "On this Wi-Fi") are logged at debug level,
one line each with the signal that decided: `log stream --level debug
--predicate 'subsystem == "io.github.mh-mobile.roamrun" AND category == "home"'`. The rules
live in `HomeRule` (ProxyBridge.swift) and are unit-tested — change them there.

Tunnel ports are the most Apple-dependent part: relays open for newest…newest+16
and are reaped outside newest−32…newest+16. Each discovered port is logged at
debug level with whether a lookahead relay was already there (hit/miss) and the
jump from the previous one: `log stream --level debug --predicate
'subsystem == "io.github.mh-mobile.roamrun" AND category == "tunnel"'`. Misses or large
jumps after an iOS update mean the window needs retuning.

## Releasing

0. Run docs/release-checklist.md on real devices.
1. Bump `CFBundleShortVersionString` (shown by `roamrun --version`) and
   `CFBundleVersion` (+1 each release) in `Info.plist`; commit, push, wait for CI.
2. Build the dmg from a fresh clone of that commit (a working copy can hold
   uncommitted changes): `make dmg` → `RoamRun-<version>.dmg`.
3. `gh release create v<version> RoamRun-<version>.dmg --target <that commit's full sha> --title "RoamRun <version>" --notes …`
   — the tag must point at the commit the dmg was built from. Keep the notes'
   claims in line with the README.
4. Homebrew tap (`mh-mobile/homebrew-tap`, `Casks/roamrun.rb`): set `version`
   and `sha256` (`shasum -a 256` of the dmg), `brew style` + `brew audit --cask --online`, push.

## Rules

- Keep the skill (`skills/roamrun/SKILL.md`) in sync with CLI behaviour; it
  ships inside the app for `roamrun init`.
- Never mention inspecting or reverse-engineering other products in anything
  committed (README, comments, commit messages). Credit public sources only.
- Keep comments short; no multi-line narration of what the code already says.
