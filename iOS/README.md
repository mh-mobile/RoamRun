# RoamRun Introducer

An iOS app that stands in for `roamrun pair introduce` on the device itself: it announces a far
Mac's pairing offer on the device's own Wi-Fi, takes the one connection Settings makes to it, and
carries it to the far Mac over the Tailscale VPN already on the device. No Mac near the device is
needed. How it is used from the far Mac: the main README, "From the device itself".

It isn't part of `make app`, and isn't on the App Store: build it here. On the Home Screen and in Settings it is “RoamRun”: the whole name doesn't fit under an icon. `Sources/Introduction.swift`
mirrors `Sources/RoamRun/Introductions.swift` (the line formats and their rules); keep them identical.

## Build and run on a device

```
cd iOS
xcodegen generate
open RoamRunIntroducer.xcodeproj   # set your team under Signing, run on the iPhone
```

Or from the shell: `xcodebuild -project RoamRunIntroducer.xcodeproj -scheme RoamRunIntroducer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
No entitlements, no background modes: Local Network permission and `BGContinuedProcessingTask` carry it.

## Flow

No line is carried by hand: the app speaks the introducing side of `roamrun pair xcode --with`.

1. On the far Mac: Xcode › Device Hub › Pair Nearby Device, then `roamrun pair xcode --with <this iPhone's Tailscale name>`
   (RoamRun 0.5.0 or later: earlier ones take only a Mac after `--with`).
2. In the app: the far Mac's Tailscale name (typed once, kept). Tap **Introduce**; allow Local Network when asked.
   With `--qr` after `--with`, the far Mac draws a code in its terminal: the app's **Scan the far Mac's code**, or the iPhone's camera, opens the app with that
   name filled in (`roamrun-introducer://<far Mac's Tailscale name>`), and nothing is typed.
3. Settings › Privacy & Security › Developer Mode › Pair with “<far Mac>”, type the code Device Hub shows on the far Mac.
4. The app tells the far Mac, which saves this iPhone under its Tailscale name. There: `roamrun up`.

Device control (`look`, `tap`…) is paired the same way, with the RoamRun app open on the far Mac and
`roamrun pair control --with <this iPhone's Tailscale name>` there (`--qr` here too, for a far Mac the app
doesn't hold the name of): the app needs no other setting — the far Mac's
answer says which pairing it is. The code is made on the far Mac and shown here, in a notification and where iOS
shows the app's background task, over Settings.

**Carry the lines by hand** brings back the first form (the `rr-xcode-offer-v1:` line from `roamrun pair xcode`, pasted —
or read with the far Mac's name from the code `roamrun pair xcode --qr` draws —
copy the `rr-device-v1:` line the app shows to `roamrun devices add`), for a far Mac that can't be asked. The app
also shows that line when the far Mac didn't say whether it saved.

The far Mac's name and this iPhone's Tailscale name are kept between launches. The offer line isn't: it
only works while its Pair Nearby Device sheet is open on the far Mac, and each press makes another.

If the app says it could not see this iPhone's own announcement, check `roamrun devices` on the far
Mac first. An existing record can be used with `roamrun up <name>`. Otherwise, a Mac that already
has this iPhone saved can run `roamrun devices export <name>`; add that line on the far Mac. The
stand-in's “pairing was tried” message says a connection passed through it, not whether Xcode
accepted the code.

## Screens

`Sources/Session.swift` holds one introduction (its stage, the code, how it ended); `Sources/ContentView.swift` shows it:
a first screen (the far Mac last introduced, Scan, Edit), the three steps while it runs, and how it ended, with the
line to carry when there is one. To look at a screen without a far Mac, in a debug build:

```
SIMCTL_CHILD_INTRODUCER_PREVIEW=pairing xcrun simctl launch booted io.github.mh-mobile.roamrun.introducer
```

(`empty`, `asking`, `pairing`, `code`, `finishing`, `done`, `byhand`, `failed`.)

A far Mac is named as Tailscale names it — one word, a name under `ts.net`, or an address of Tailscale's — and neither
the question nor the pairing itself goes to an address that isn't Tailscale's, whatever a code, a link or a name led to.

## What to test on the device (unknowns the Mac can't answer)

- Does Settings list a host announced by an app on the same phone with Xcode's own TXT (model, flags…)? Does pairing go through to the far Mac's Xcode?
- Where does the connection from Settings come from (127.0.0.1, the Wi-Fi IPv4, a link-local IPv6)? The first accepted connection is logged:
  `log stream --level debug --predicate 'subsystem == "io.github.mh-mobile.roamrun.introducer"'` (via the Mac's Console for the device). Tighten the allowlist afterwards.
- Does `BGContinuedProcessingTask` keep the listener and the Bonjour record alive while Settings is in front? Does the task survive 5 minutes with progress advancing every 15 s?
- Does the phone's own `_remotepairing._tcp` record show up to the app, and does the resolved host match an own address (the device line depends on it)?
- By wire: does the far Mac see the connection come from this iPhone's Tailscale address (it answers no other), and does the
  connection to it last through the time in Settings?
- Does the record disappear from a Mac's `dns-sd -B _remotepairing-pairable-host._tcp local.` within seconds of Stop?

The icon is RoamRun's, edge to edge: `xcrun swift ../scripts/make-icon.swift --ios Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`.

## Check on this Mac

`Checks/relay-check.swift` compiles the engine for macOS and runs it under the test type `_rrtest._tcp`
(never the real one): a fake far Mac echoing on 127.0.0.1, a stranger refused, an allowed connection
relayed both ways, `.carried`, the record removed, and the deadline.

```
xcrun swiftc -swift-version 6 -parse-as-library -o /tmp/relay-check Sources/StandIn.swift Sources/Introduction.swift Sources/Wire.swift Checks/relay-check.swift && /tmp/relay-check
```
