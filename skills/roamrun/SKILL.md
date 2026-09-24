---
name: roamrun
description: Run, install and debug iOS apps on a physical iPhone that is not on this Mac's network (e.g. the user is away and the Mac is at home), over Tailscale with RoamRun. Use when building to a real device, installing/launching with devicectl, attaching lldb, or when Xcode can't see the iPhone because it is on another network.
---

# RoamRun

RoamRun makes a paired iPhone on another network look local to Xcode, over
Tailscale. Drive it with the `roamrun` CLI, then build, install and launch with
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
If the bridge already runs in the menu bar app, just use it — `status` shows
the owner, and `up` refuses a device another process bridges.

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
