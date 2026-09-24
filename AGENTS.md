# Working on RoamRun

Guidance for agents changing this repository. (To *use* RoamRun from an agent,
see `skills/roamrun/SKILL.md` — installed with `roamrun init` or
`npx skills add mh-mobile/RoamRun`.)

## Build & run

- `make app` builds `RoamRun.app` (menu bar app and `roamrun` CLI in one binary);
  `make run` also launches it. Don't call `swift build` directly — `make` pins
  Xcode's toolchain and stamps the real SDK version (needed for Liquid Glass).
- `make install-cli` links `/usr/local/bin/roamrun`; `make dmg` packages.
- UI screenshots without screen-recording rights:
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

## Rules

- Keep the skill (`skills/roamrun/SKILL.md`) in sync with CLI behaviour; it
  ships inside the app for `roamrun init`.
- Never mention inspecting or reverse-engineering other products in anything
  committed (README, comments, commit messages). Credit public sources only.
- Keep comments short; no multi-line narration of what the code already says.
