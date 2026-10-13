# Pairing a Mac the device was never near: details

<p align="center">English | <a href="far-mac.ja.md">日本語</a></p>

The [README](../README.md#pairing-a-far-mac-for-xcode) has the commands for the usual case,
where both Macs are on one tailnet. This document has the other way of doing it, what each side
checks, what the far Mac needs, and what was tried.

It all needs iOS 27 and Xcode 27. Names are Tailscale names. "The introducing Mac" is the one on
the device's Wi-Fi; "the far Mac" is the one that comes to be paired.

## With a line carried by hand

Without a tailnet connection between the two Macs, the same exchange is carried as two lines of
text:

```sh
# on the far Mac: Device Hub › + › Pair Nearby Device, leave “Waiting to pair.” open, then
roamrun pair xcode                                           # prints that Mac's offer to pair, one line

# on the introducing Mac, with the device saved in RoamRun:
roamrun pair introduce <offer> --host cloud-mac --to iPhone
#   on the device: Settings › Privacy & Security › Developer Mode › Pair with “cloud-mac”,
#   and the code Device Hub shows on the far Mac
#   it ends by itself and, when a pairing was tried, prints the device as a line

# on the far Mac again:
roamrun devices add <line>                                   # the device, saved without a key or a UDID
roamrun up iPhone
```

Each command prints its line alone on standard output, so with ssh to the far Mac nothing has to
be copied by hand:

```sh
OFFER=$(ssh cloud-mac roamrun pair xcode) &&
LINE=$(roamrun pair introduce "$OFFER" --host cloud-mac --to iPhone) &&
ssh cloud-mac roamrun devices add "$LINE"
```

None of this needs the RoamRun app open on the far Mac. The app lists the device when it is next
opened, or within seconds if it is open.

`roamrun pair xcode --qr` draws the offer as a QR code in the terminal, for the Introducer app to
read; the app then shows the line for `roamrun devices add <line>`. If the terminal's window is
too small for the code, the command says the size it needs.

## What each side does and checks

**The far Mac**, while `pair xcode --with` or `pair control --with` runs:

- It listens on its Tailscale address, port 41830. Only one of the two commands can wait at a
  time. A firewall on the far Mac has to let RoamRun in; when the firewall is on, the command says
  so as it starts.
- It answers only the machine it was given, which it checks by its address and by the machine
  Tailscale says holds that address at that moment.
- For Xcode's pairing, it saves the device when a pairing was tried. "Saved" is not "paired":
  `roamrun up` shows whether the pairing was made. For device control, it keeps the pairing only
  once it is made.

**The introducing Mac**, while `pair introduce` runs:

- It announces the far Mac's offer on its Wi-Fi, under the name Tailscale has for that Mac, and
  carries the device's connection to it over the tailnet. It listens for nothing on the tailnet.
- It takes connections from the device's own address on that Wi-Fi only. It has that address from
  Tailscale, and asks the device when Tailscale has not talked to it lately.
- It does not start when Tailscale reaches the device only through a relay or over IPv6, or when
  the device was saved by its address rather than as a Tailscale device.
- It says whose Mac the far one is, as Tailscale has it — yours, another person's, or a shared
  (tagged) machine — before it announces anything. It introduces only the Mac you name with
  `--host`.
- It stops when the device has tried to pair, or after five minutes. It also stops on Ctrl-C, when
  this Mac's address changes, and when the far Mac's command ends. It then says that nothing is
  announced or listening, or, if its announcement's helper may still be running, says that
  `roamrun doctor` will tell.
- It cannot tell whether the pairing was made: a wrong code looks the same from there as one not
  yet typed.

The pairing itself is made between the device and the far Mac: its Xcode, or for device control
its RoamRun app. No key leaves either, and none passes through the introducing Mac. If a
connection between the two Macs is lost on the way, each side says what to do; the commands with
a line carried by hand, above, need no such connection.

## What it needs

- **A device that has been paired with something before, saved in RoamRun on the introducing
  Mac.** A device with no pairing at all does not announce itself, so RoamRun has nothing to add
  it from: pair it once first, with any Mac on its Wi-Fi. The introducing Mac need not be that Mac,
  nor be paired with the device itself. The Introducer app and `roamrunctl` need nothing saved:
  they see the device's announcement at the time.
- **The device on the introducing Mac's own Wi-Fi** for that one step: not a guest or isolated
  network, and not a hotspot behind it.
- **Someone at the far Mac's screen**, or on screen sharing, to press the button in Device Hub and
  read its code.
- **Tailscale on the far Mac that stays signed in.** A Mac joined with an ephemeral key is signed
  out when it restarts.

## After the pairing

- **Debugging from the far Mac needs the device's OS symbols there.** Xcode copies them from the
  device on first contact, about 6 GB, which hardly moves over Tailscale's relay servers. Copying
  `~/Library/Developer/Xcode/iOS DeviceSupport/<model> <version> (<build>)` from a Mac that has it
  works: with it, `lldb` on the far Mac attached and reached a breakpoint in about 20 seconds;
  without it, `lldb` waited four minutes and attached nothing. `devicectl`, `roamrun run` and
  `roamrun logs` do not need the symbols.
- **Macs made from one image are one Mac to the device.** Pairing a second replaces the first's
  entry on the device, and removing it cuts off both.
- **A pairing made on a rented or cloud Mac stays with that machine's disk, image and snapshots**
  until it is removed on the device.
- **What the far Mac has saved of the device is a copy of the introducing Mac's.** If that stops
  matching — the device's Bonjour record changed — add the device again on the introducing Mac,
  run `roamrun devices export <name>` there, and `roamrun devices add <line>` on the far Mac. For a
  device already saved there, that takes the line's record. When the device's address, port or
  Tailscale name moved too, use `--replace <name>`, with the app and that device's bridge stopped.

## What was tried

With an iPhone 15 Pro on iOS 27 and Xcode 27, and a virtual Mac as the far one:

- By line and by name: the pairing, `devices add`, the bridge Ready, `devicectl` launch, and `lldb`
  at a breakpoint — with the far Mac reaching the device directly and through Tailscale's relay
  servers — and both Macs using the device at the same moment.
- An introducing Mac that was not itself paired with the device did the same.
- With the Introducer app: Xcode's pairing by name and by hand, with the bridge Ready afterwards,
  and device control's pairing, with `roamrun look` afterwards.
- With `roamrunctl` introducing from Ubuntu 24.04 and from Windows 11 on ARM: Xcode's pairing with
  the bridge Ready afterwards, and device control's pairing.
- On 2026-10-13, with RoamRun 0.7.0: by name for Xcode (the bridge Ready on the far Mac), by name
  for device control (a look from the far Mac, and a second try refused on both sides), and device
  control's pairing through the Introducer app. With an Apple Vision Pro: the pairing by name, the
  far Mac's command ending by itself, and the bridge Ready there.

Not tried: an iPad, a far Mac with an older RoamRun than the introducing one, a far Mac that is not virtual, a far Mac of another Tailscale user or a tagged
one, a Mac shared in from another tailnet, an introducing Mac with its firewall on.
