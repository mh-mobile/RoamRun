---
name: roamrun
description: Reach a physical iPhone, iPad or Apple Vision Pro that is on another network than this Mac (the user is away, the Mac is at home) over Tailscale with RoamRun, so Xcode, xcodebuild, devicectl and lldb can use it as if it were local. Use when the device isn't visible to Xcode/devicectl because it's elsewhere, when the user mentions RoamRun, or to take a screenshot of such a device's screen.
---

# RoamRun

RoamRun makes a paired device on another network look local to Xcode, over
Tailscale ("iPhone" below means any of iPhone, iPad, Apple Vision Pro; the CLI
says "device"). Its job is **the connection**: once `roamrun status` says
ready, the device is an ordinary device to Apple's tools. Build, install,
launch and debug it however you normally would — your usual steps or another
skill for `xcodebuild` / `devicectl` / `lldb` — with the UDID from `roamrun`.
`roamrun run` is there for when you have nothing else.

## 1. Check it's installed

```sh
roamrun --help
```

If missing, the user installs RoamRun (`brew install --cask mh-mobile/tap/roamrun`
links the command too; or https://github.com/mh-mobile/RoamRun) and installs the command from the app's
first screen or Open RoamRun › ⚙ Settings › Command line tool › Install (or `make install-cli`
from the repo). If `roamrun status` or `doctor` says this skill is from another
RoamRun version, tell the user `roamrun init` updates it; some options here may
not match the installed CLI until then (`roamrun --help` is authoritative).

## 2. Things only the user can do — ask, don't retry

- **Unlock the iPhone and keep its screen on.** A sleeping iPhone is
  unreachable; a locked one refuses installs and launches.
- One-time setup: pair the iPhone with this Mac (USB + Trust, or with Xcode 27
  + iOS 27, Device Hub › + › Pair Nearby Device on the same Wi-Fi), turn on
  Developer Mode, then add it in the RoamRun app while
  it is on the Mac's Wi-Fi.
- Keep the iPhone on some Wi-Fi (tethering is fine; cellular alone is not).

## 3. Get the device ready

```sh
roamrun devices                       # saved devices + UDID
roamrun up iPhone -d                  # bridge in the background; returns when ready (exit 1 after 60 s if not — it keeps trying)
# Stop here unless all three pass — don't build or install on a device that isn't ready.
roamrun status iPhone --wait 60 --json > /tmp/rr.json || { roamrun doctor iPhone; exit 1; }   # act on doctor's first fail
UDID=$(jq -er '.[0].udid // empty' /tmp/rr.json) || exit 1         # for xcodebuild AND devicectl
jq -e '.[0].locked == false' /tmp/rr.json >/dev/null || { echo "ask the user to unlock the iPhone"; exit 1; }
```

`status --json` prints the JSON even when the device isn't ready (exit 1), so
check the exit code, not just the file. `locked` is `null` when it couldn't be
read — treat that like locked.

If the bridge already runs in the menu bar app, just use it — `status` shows
the owner, and `up` exits 0 when another process already has it ready (exit 1
if that one is still coming up). Status "On this Wi‑Fi" means the iPhone is on
the Mac's own network: no bridge is needed, Xcode sees it directly, and it
counts as ready. After a long build, check `roamrun status iPhone` again before
installing.

Leave the bridge running when you're done. Run `roamrun down iPhone` only if
the user asks: it also stops a bridge the menu bar app runs and takes the
device off the app's list of bridges to restore.

## 4. Build, install, launch

With your usual tools, using `$UDID` — e.g.:

```sh
xcodebuild -project App.xcodeproj -scheme App -destination "platform=iOS,id=$UDID" \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/App.app
xcrun devicectl device process launch --device "$UDID" com.example.App
```

Debugger: `lldb` → `device select $UDID` → `device process attach -n App`.

Or in one command from the project folder (checks readiness, lock state and
signing, and says what to do):

```sh
roamrun run iPhone [--scheme S] [--logs]   # --scheme: only if several; --logs: stream output
```

Only build projects the user trusts: their build scripts run on this Mac.
Prebuilt .ipa (e.g. from CI) or .app: `roamrun install iPhone App.ipa` checks
it's signed for this device (Debugging, Release Testing / Ad Hoc, Enterprise)
first; App Store / TestFlight builds can't be installed directly.

## 5. See what the app shows

`roamrun screenshot iPhone /tmp/shot.png` saves the device's screen as PNG and
prints the path — look at it after launching (or after a change) instead of
asking the user to describe the screen. It can't tap. To reach a screen
without the user, launch the app straight into it — with `roamrun run`
(builds first), then for each further screen relaunch without rebuilding:

```sh
roamrun run iPhone --url myapp://settings    # build, install, open a URL the app handles (its scheme or a universal link)

# next screens: relaunch only (app arguments go after "--"; environment via DEVICECTL_CHILD_*)
DEVICECTL_CHILD_DEMO_ACCOUNT=1 xcrun devicectl device process launch --terminate-existing \
  --device "$UDID" --payload-url myapp://profile com.example.App -- -ShowScreen profile
roamrun screenshot iPhone /tmp/profile.png
```

`roamrun run` and `roamrun logs` take these as options: `--url URL`,
`--arg A` once per word (a UserDefaults override `-Key value` is
`--arg -Key --arg value`) and `--env NAME=value`. With devicectl, `-e`
replaces every `DEVICECTL_CHILD_*` variable — use one or the other. Only the
app's own code decides what a URL, argument or variable does: look for its
handling in the project, or ask.

## 6. App output

`roamrun logs iPhone com.example.App` relaunches the app with its console
attached (print and os_log) and streams until Ctrl-C. It can't join an
already-running app, and never exits on its own — run it in the background:
`roamrun logs iPhone com.example.App > /tmp/app.log 2>&1 & sleep 20; kill $!`.

## 7. When something fails

- Run `roamrun doctor iPhone --json`; act on the first `"result": "fail"`. Its
  `fix` says what to do — if it involves the iPhone, ask the user.
- `ready: false` with a note that the iPhone is probably asleep, xcodebuild
  listing only simulators, or CoreDevice error 4016 → ask the user to unlock.
- `doctor` says Tailscale reaches the iPhone but the RemotePairing port doesn't
  answer → ask the user to toggle the VPN off/on in the iPhone's Tailscale app
  (iOS Tailscale sometimes shows "MagicSock function ReceiveIPv4 is not running"
  and stops passing data while looking connected), to keep the Tailscale app
  updated, and to check it's on Wi-Fi.
- `The peer is no longer reachable` → macOS rebuilds the control channel about
  every 42 s; retry the command once, then run `doctor`.

Exit codes: `0` ok/ready, `1` not ready or a check failed, `2` usage error.
In `--json`, compare `ready` or `state` (off, starting, waiting, preparing, ready, error, local); `status` is display text.
