---
name: roamrun
description: Reach a physical iPhone, iPad or Apple Vision Pro that is on another network than this Mac (the user is away, the Mac is at home) over Tailscale with RoamRun, so Xcode, xcodebuild, devicectl and lldb can use it as if it were local. Use when the device isn't visible to Xcode/devicectl because it's elsewhere, when the user mentions RoamRun, or to take a screenshot of such a device's screen. Also to install a build on a device without the bridge — over cellular or Wi-Fi, and on devices never paired with this Mac — when installing is all that is needed.
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
- Keep the iPhone on some Wi-Fi with internet access. Joining another
  device's hotspot is fine — a second iPhone's Personal Hotspot, a pocket
  router, café Wi-Fi. Cellular alone is not, and neither is the iPhone sharing
  its *own* Personal Hotspot (then it isn't on Wi-Fi itself).
- If the user really has no Wi-Fi to join, there is no bridge and none of the
  commands below work. `roamrun ota [<name>] <App.ipa> [--replace]` is the one
  that still does: it publishes the build so the user can install it from the
  device itself. It needs neither Wi-Fi nor pairing with this Mac, so it is also
  the way onto a device that has neither — but when the bridge is available the
  bridge is better, and this is not a substitute for it. An Ad Hoc build still
  needs Developer Mode on to *launch* (iOS 16+): the switch appears under
  Settings › Privacy & Security once it is installed, so tell the user that
  before they think the build is broken. It installs only — no debugging, no logs, no screenshots — and
  it needs an .ipa signed for Release Testing (Ad Hoc) or Enterprise, which
  needs a paid Apple Developer account. You can't produce that .ipa from a
  Development signing setup: export one with `xcodebuild -exportArchive`
  and `"method": "release-testing"` if the team already has an Ad Hoc profile,
  or ask the user (Xcode › Product › Archive › Distribute App › Release Testing). RoamRun.app also has to be
  running on the Mac — it serves the page, the CLI only stores the build.
  **Anyone on the tailnet can open that page and install the build** — say so
  before suggesting it. Give the user the address it prints: the QR code is only
  drawn on a terminal, so it won't reach them through you — `roamrun doctor`
  prints it again. Its "Over the air" check is a `warning`, not a `fail`, when the
  page isn't published (the app isn't open, or it needs up to half a minute), so
  read that section rather than only doctor's first fail. `--replace` keeps one row
  per version and build number instead of stacking one per rebuild. Tell them what
  they'll get and let them decide. The name is optional: without one the build is
  checked against every device RoamRun knows and it says which are covered, which
  is what you want when you don't know which device the user has to hand. A build
  covering none of the devices it knows is stored with a warning rather than
  refused, because the profile may name one this Mac has never seen — relay the
  warning as it is written, including which devices it could not check.

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
counts as ready while CoreDevice can reach it (`ready` true; when CoreDevice
reports it unavailable or can't be asked, it stays `state` local with `ready`
false and a `detail`; before the UDID is known CoreDevice isn't asked, and `ready`
follows the bridge alone). `ready` says nothing about the lock: a reachable device
can be `ready` true and `locked` true, so check `locked` separately, as above.
So when the user wants to know that it works *over
Tailscale* (e.g. trying it at home before going out), "Ready for Xcode"
(`state` ready) is that; "On this Wi‑Fi" (`state` local) means it didn't use
Tailscale — have them move the iPhone to another network first. After a long
build, check `roamrun status iPhone` again before installing.

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

To put a file **on** the device — a fixture to import, an image to test with —
use the app's own container, or the clipboard, which needs no app at all:

```sh
xcrun devicectl device copy to --device "$UDID" --source local.png \
  --domain-type appDataContainer --domain-identifier com.example.App --destination Documents/in.png
xcrun devicectl device pasteboard copy --file local.png --type public.png --device "$UDID"
```

`copy from` brings one back and `info files` lists them (nothing deletes).
`pasteboard paste` reads the clipboard, and looks for text unless given `--type`.
Neither reaches the photo library.

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
In `--json`, `ready` says whether Xcode can use the device now; `state` (off, starting, waiting, preparing, ready, error, local) says how RoamRun is handling it; `status` is display text. `network` is `wifi` or `cellular` while ready over the bridge. `cellular` means a session set up while Ready for Xcode on another Wi‑Fi is still running on cellular (a device that goes from "On this Wi‑Fi" straight to cellular loses its session). Every build you install then uses the user's cellular data, and a new session needs Wi‑Fi again. While waiting, `cellular` means RoamRun closed the session because the device is on cellular and the user left **Keep debugging on cellular** off. Ask the user to join Wi‑Fi; turning the setting on only helps the next time the device leaves Wi‑Fi. Don't retry.
