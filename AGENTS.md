# Working on RoamRun

Guidance for agents changing this repository. (To *use* RoamRun from an agent,
see `skills/roamrun/SKILL.md` — installed with `roamrun init` or
`npx skills add mh-mobile/RoamRun`.)

## Build & run

- `make app` builds `RoamRun.app` (menu bar app and `roamrun` CLI in one binary);
  `make run` also launches it. Don't call `swift build` directly — `make` pins
  Xcode's toolchain and stamps the real SDK version (needed for Liquid Glass).
  It builds device control's Rust library first (`Rust/RoamRunDevice`), with the
  Rust its `rust-toolchain.toml` names (rustup fetches it); `CARGO=` picks another.
  After changing `Cargo.lock`: `make licenses`, and commit the file it writes; and `make audit`
  (CI runs it too, and every Monday): an advisory against a crate it pins is either a reason
  to change the crate or, looked into, a line in `scripts/audit-crates.py` saying why not.
- Device control keeps a key and a list (which devices are switched on) in the
  Keychain, which asks about a build signed ad hoc after every rebuild. `make app` signs with an Apple Development certificate
  when the keychain holds one (else ad hoc); `SIGN_ID=` picks another.
- `make install-cli` links `/usr/local/bin/roamrun` to the build in the repo
  folder (for development; the app's first screen / Settings link the copy that
  is running, e.g. `/Applications`). `make dmg` packages.
- `iOS/` is RoamRun Introducer, the app with which a device introduces a far Mac itself. It isn't
  part of `make app`: `cd iOS && xcodegen generate`, then Xcode (set a team). Its engine runs on a
  Mac under a test service type — the command is at the top of `iOS/Checks/relay-check.swift` — and
  `iOS/Sources/Introduction.swift` mirrors `Sources/RoamRun/Introductions.swift`: change both
  (and the code's short names: `codeURL` on the Mac, `Session.open` in the app).
- `Rust/roamrunctl/` is `pair introduce` for a machine that has no RoamRun (its own crate and
  `Cargo.lock`; not part of `make app`): `cargo build --locked && cargo test` there, and
  `scripts/local-check.py` for the mechanics on this Mac. Its version is RoamRun's (its `build.rs`
  reads `Info.plist`). `make audit` covers its lock too, and `make licenses` writes its
  `THIRD-PARTY-LICENSES.txt`, which its archives carry: both after changing its `Cargo.lock`.
- `make test` runs the unit tests (log parsing, port attribution, status-file
  ownership, names). They never touch the real status/profile files or start a
  real bridge — keep it that way (no `AppCoordinator` in tests). A bridge on a
  fully faked `BridgeEnv` is fine: it only opens relays on 127.0.0.1.
- Only one RoamRun app runs at a time (matched by bundle id): a dev build won't
  start while an installed copy is running — quit that one first.
- UI screenshots without screen-recording rights: build with `make app SNAPSHOT=1`
  (dev only — rebuild with plain `make app` afterwards), then
  `MB_SNAPSHOT=/tmp/x.png [MB_SNAPSHOT_SHEET=add|settings] [MB_APPEARANCE=dark] RoamRun.app/Contents/MacOS/RoamRun`
  (Liquid Glass surfaces and the main window's sidebar don't render in these; ask the
  user for a real screenshot.) Add `MB_FAKE_PROFILES=60` / `MB_FAKE_DEVICES=40` for many
  saved devices / devices on the network, some with long names — never saved to disk,
  and their bridges don't start. Also without `MB_SNAPSHOT`, to look at the live window
  (quit the installed RoamRun first: only one runs, so its bridges pause meanwhile).

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

What a bridge did earlier — each change of status or network, with what the relays
showed — is kept in the system log, without UDIDs or addresses: `log show --last 6h
--predicate 'subsystem == "io.github.mh-mobile.roamrun" AND category == "status"'`.

Tunnel ports are the most Apple-dependent part: relays open for newest…newest+16
and are reaped outside newest−32…newest+16. Each discovered port is logged at
debug level with whether a lookahead relay was already there (hit/miss) and the
jump from the previous one: `log stream --level debug --predicate
'subsystem == "io.github.mh-mobile.roamrun" AND category == "tunnel"'`. Misses or large
jumps after an iOS update mean the window needs retuning.

What `type` sent (keys, spaces among them, how long it took — never the text) is logged at
debug level: `log stream --level debug --predicate 'subsystem == "io.github.mh-mobile.roamrun"
AND category == "input"'`. Text that arrives short with a line here was dropped by the device.

## Releasing

0. Run docs/release-checklist.md on real devices.
1. Bump `CFBundleShortVersionString` (shown by `roamrun --version`) and
   `CFBundleVersion` (+1 each release) in `Info.plist`, on a `release/<version>` branch; open a
   pull request, wait for CI, merge. `main` takes changes by pull request only (a ruleset on
   GitHub: no direct push, no force push), whoever pushes. The release is the commit that merge
   makes on `main` — not the branch's own tip, which a squash leaves behind: wait for CI on it too.
2. In a fresh clone of that commit on `main` (a working copy can hold uncommitted changes), first
   `make roamrunctl-archives` → `roamrunctl-dist/`: roamrunctl's archives as CI built them from
   that same commit (it stops if no CI run of a push has passed for it), and their checksums.
   Then the dmg: `make release-dmg` → `RoamRun-<version>.dmg`, Developer ID
   signed, notarized and stapled — it fails otherwise (it checks `stapler validate`
   and `spctl`). It needs the Developer ID Application identity in the keychain,
   the notary profile from `xcrun notarytool store-credentials roamrun-notary`, and rustup.
   It fetches idevice from the fork at the commit `Cargo.toml` pins: that commit carries a tag
   there (`roamrun-<version>`) — tag a new pin before releasing, or the build stops when its branch goes.
   Plain `make dmg` is the ad-hoc developer build, never a release.
3. `gh release create v<version> RoamRun-<version>.dmg roamrunctl-dist/* --target <that commit's full sha> --title "RoamRun <version>" --notes …`
   — the tag must point at the commit the dmg was built from. Keep the notes'
   claims in line with the README.
4. Homebrew tap (`mh-mobile/homebrew-tap`, `Casks/roamrun.rb`): set `version`
   and `sha256` (`shasum -a 256` of the dmg), `brew style` + `brew audit --cask --online`, push.
   And `Formula/roamrunctl.rb`, from `Rust/roamrunctl/roamrunctl.rb`: the tag in `url`, the
   `sha256` of that tarball (`curl -L <url> | shasum -a 256`), `brew audit --formula`, and built
   once before the push — edited in the tap as Homebrew has it checked out (`cd "$(brew --repository mh-mobile/tap)"`),
   which is what this builds: `brew install --build-from-source mh-mobile/tap/roamrunctl && brew test roamrunctl`.
5. roamrunctl's install commands (its README) take the newest release's archives by name: once
   it is out, run each on its system — Linux, Windows, `brew install`, and
   `cargo install --locked --git … --tag v<version> roamrunctl` — and see `roamrunctl --version`
   say this version. The Introducer app (`iOS/`) isn't in a release: the notes say it is built from source.

## Rules

- Keep the skill (`skills/roamrun/SKILL.md`) in sync with CLI behaviour; it
  ships inside the app for `roamrun init`. Likewise `skills/roamrunctl/SKILL.md` with
  roamrunctl, whose archives carry it.
- Never mention inspecting or reverse-engineering other products in anything
  committed (README, comments, commit messages). Credit public sources only.
- Keep comments short; no multi-line narration of what the code already says.
