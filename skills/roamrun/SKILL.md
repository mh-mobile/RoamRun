---
name: roamrun
description: Run, install and debug iOS/iPadOS/visionOS apps on a physical iPhone, iPad or Apple Vision Pro that is not on this Mac's network (e.g. the user is away and the Mac is at home), over Tailscale with RoamRun. Use when building to a real device, installing/launching with devicectl, attaching lldb, or when Xcode can't see the iPhone because it is on another network.
---

# RoamRun

RoamRun makes a paired iPhone on another network look local to Xcode, over
Tailscale. iPad and Apple Vision Pro work the same way; "iPhone" below means
any of them (the CLI says "device"). Drive it with the `roamrun` CLI, then build, install and launch with
Apple's own tools (`xcodebuild`, `xcrun devicectl`, `lldb`).

## 1. Check it's installed

```sh
roamrun --help
```

If missing, the user installs the RoamRun app
(https://github.com/mh-mobile/RoamRun), then Settings › Command line tool ›
Install (or `make install-cli` from the repo).

## 2. Things only the user can do — ask, don't retry

- **Unlock the iPhone and keep its screen on.** A sleeping iPhone is
  unreachable; a locked one refuses installs and launches.
- One-time setup: pair the iPhone with this Mac (USB + Trust, or with Xcode 27
  + iOS 27, Device Hub › + › Pair Nearby Device on the same Wi-Fi), turn on
  Developer Mode, then add it in the RoamRun app while
  it is on the Mac's Wi-Fi.
- Keep the iPhone on some Wi-Fi (tethering is fine; cellular alone is not).

## 3. Recipe

Shortest path, from the project folder once the device is ready:

```sh
roamrun up iPhone -d                              # skip if it's on this Mac's Wi-Fi
roamrun run iPhone --scheme App [--logs]          # build → install → launch (--logs: stream output)
```

`run` checks reachability, lock state and signing first and says what to do.
Step by step, when you need more control:

```sh
roamrun devices                       # saved iPhones + UDID
roamrun up iPhone -d                  # bridge in the background; returns when ready
roamrun status iPhone --wait 60 --json > /tmp/rr.json || roamrun doctor iPhone
UDID=$(jq -r '.[0].udid' /tmp/rr.json)       # works for xcodebuild AND devicectl
jq -e '.[0].locked != true' /tmp/rr.json >/dev/null || echo "ask the user to unlock the iPhone"

xcodebuild -project App.xcodeproj -scheme App -destination "platform=iOS,id=$UDID" \
  -derivedDataPath build -allowProvisioningUpdates build
roamrun status iPhone --json | jq -e '.[0].ready' >/dev/null   # re-check after a long build
xcrun devicectl device install app --device "$UDID" build/Build/Products/Debug-iphoneos/App.app
xcrun devicectl device process launch --device "$UDID" com.example.App
roamrun down iPhone                   # when finished (optional)
```

Debugger: `lldb` → `device select $UDID` → `device process attach -n App`.

Prebuilt .ipa (e.g. from CI) or .app: `roamrun install iPhone App.ipa` — checks
it's signed for this device (Debugging, Release Testing / Ad Hoc, Enterprise)
before installing; App Store / TestFlight builds can't be installed directly.

App output (print and os_log): `roamrun logs iPhone com.example.App` relaunches
the app with its console attached and streams until Ctrl-C — use it instead of
the launch step. It can't join an already-running app. It never exits on its
own, so run it in the background and stop it when done:
`roamrun logs iPhone com.example.App > /tmp/app.log 2>&1 & sleep 20; kill $!`.
If the bridge already runs in the menu bar app, just use it — `status` shows
the owner, and `up` refuses a device another process bridges. Status
"On this Wi‑Fi" means the iPhone is on the Mac's own network: no bridge is
needed, Xcode sees it directly, and it counts as ready.

## 4. When something fails

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
