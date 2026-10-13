# roamrunctl: what was tried

A record of what [roamrunctl](../Rust/roamrunctl/README.md) was run against, and what it wasn't. Each item is
one sitting, not a guarantee; how it is meant to work is in the README and in
[roamrunctl-reference.md](roamrunctl-reference.md).

## Holding and using a device (0.7.0)

Tried against a device (iPhone 15 Pro, iOS 27.0) after the reviews, with the Linux build CI made (arm64, an
Ubuntu VM on the tailnet) as the using machine and a Mac beside the device, once each:

- Pairings an earlier build had saved on the VM were listed and opened as they were.
- A: `look`; and through `roamrunctl mcp`: devices, press, look, tap, look, elements. A tap before any look, and a
  second tap on one look, were refused.
- `pair control --to` on the Mac: announced, picked on the device, the code typed, tried over the tailnet and kept.
- B as it is now: `sign <name> --for <the VM>` on the Mac; the VM, with nothing set up, listed the device, looked
  at it with no key, and saved which machine signs for it on that first use; the same `mcp` calls went through. The
  Mac said one signature for each connection. With `sign` ended the VM was refused at once and told what to run
  there; with the device removed on the Mac while `sign` ran, the request was refused on both sides ("signs for …
  no more").
- `pair control --with <the Mac> --passphrase` on the VM, introduced by this crate's `pair introduce --host` on
  the Mac: paired and kept under the passphrase. Without one given, `look` was refused; typed, it looked; given by
  `ROAMRUNCTL_PASSPHRASE_FILE`, `mcp` ran. The VM's earlier pairing with the device was then refused by the device
  at once ("doesn't accept this pairing"): pairing again replaces it.
- `pair control --with <the device's Tailscale name>` on the VM and the Introducer app on the device (far Mac: the
  VM's name), with no machine beside it: the app said the VM pairs for device control, the code showed on the VM, and
  the pairing was kept and looked with. (The app's last screen then said to try `roamrun look` there; it names `roamrunctl look` too since.)
- On Windows 11 (ARM, a virtual machine bridged onto the device's Wi‑Fi, the build CI made, PowerShell run as
  administrator): `pair control --to … --passphrase` with the passphrase given by `ROAMRUNCTL_PASSPHRASE_COMMAND`
  (a command with double quotes in it), kept under `%LOCALAPPDATA%`; `look`, and again with the same passphrase
  given itself; `sign` for the Linux VM, which listed the device, looked at it with no key, and was refused once
  `sign` ended. Windows' firewall asked nothing in that session; from a console that isn't an administrator's it wasn't run.
- Taps through `mcp` with the device on either side (a key of the calculator, the one aimed at both times).
- `install` of an .app folder (3 MB) and `launch`; a larger one (37 MB) cut short with Ctrl-C a few seconds in,
  installed again (two and a half minutes) and launched.

Earlier, before the reviews: from an unprivileged Linux container, with a key made on a Mac — connect, look, tap,
type, a button, install, launch, and launching again after the device restarted; a wrong code at `pair control
--with` kept nothing.

Not yet run against a device:

- `sign` with more than one device, and `ROAMRUNCTL_SIGNER`.
- A Mac's `roamrun pair introduce` (RoamRun's own), introducing a machine with roamrunctl.
- `mcp`'s swipe, type, paste, install and launch (each was sent by the library directly, or by the command).
- An iPad, and a device held upside down.
- On Windows: `pair control --with`, `mcp`, `install` and `launch`, and the x86_64 build.
- A device no Xcode ever prepared (launching may need what Xcode leaves on it), and one nothing was paired with
  before (`pair control --with`).
- A machine whose Tailscale runs in userspace mode (the container borrowed its host's): it has no address to
  listen on or connect from, and `sign` and `pair control --with` are expected to stop there.
- The device's pairing port after it moved far: a saved device is looked for on the port it was saved with and
  the sixteen from 49152. One not found there after it restarted is paired again. (Restarted twice, and taken
  off the network and back once, the device announced 49152 each time and was looked at as before: when it moves
  wasn't seen.)

## `pair introduce` (since 0.5.0)

Each run below was made when the flag was `--mac`; since it became `--host`, and what it prints says "the host",
Xcode's pairing wasn't run again.

- Built and tested (`cargo test`) on macOS; CI builds and tests it on Linux and Windows too.
- `scripts/local-check.py` passes on macOS: the mechanics, against a fake far Mac and a fake device.
- Run once against a real device, on Linux, with the offer carried (`--offer`): Ubuntu 24.04 (arm64) on the
  device's Wi‑Fi, avahi running beside it, an iPhone 15 Pro on iOS 27 and a far Mac reached only through Tailscale's
  relay servers. The device listed the far Mac under Pair with…, the code was typed, the line it printed went to
  `roamrun devices add` on the far Mac, and the bridge there came up Ready. That far Mac's earlier pairings had
  been removed on the device beforehand; the device was still paired with another Mac. A device no Mac has paired
  with wasn't tried.
- And once the same way with no line carried: the far Mac ran `roamrun pair xcode --with <the Linux machine>`,
  gave its offer over Tailscale, and saved the device itself when told a pairing was tried; the bridge there came
  up Ready, and nothing was left announced or listening on either machine. Run again the same way after the
  far Mac's side of the exchange changed (it tells a device its Tailscale name now): the same.
- On Windows 11 (ARM, a virtual machine bridged onto the device's Wi‑Fi), once, with no line carried: installed with
  the command above, it announced the far Mac, Windows' firewall asked whether to let it in (allowed, for private
  and public networks), the device listed the far Mac, the code was typed, the far Mac saved the device and its
  bridge came up Ready; nothing was left announced afterwards. That machine took a route to its own LAN from
  another Tailscale node ("Use Tailscale subnets", on by default on Windows), so its routing table led to the device
  through Tailscale: it finds its LAN address among its own interfaces for that reason.
- And device control's pairing from that same Windows machine: the code was printed there once the device had picked
  the far Mac, typed, and both said the pairing was kept and switched on; the far Mac then showed device control as
  connected.
- And the x86_64 build there (Windows on ARM runs it), with the offer carried (`--offer`): the line it printed went
  to `roamrun devices add` on the far Mac, whose bridge came up Ready with it.
- With ufw on, on that Linux machine, under a test service type and with a Mac standing in for the device: the
  announcement was seen and answered as ufw comes (it lets mDNS in), a connection got no answer until TCP from the
  device's address was allowed, and then connected. firewalld and others weren't tried.
- Not run on Windows or Linux on an x86_64 machine, nor on Linux without avahi.
- Device control's pairing, once, from the same Linux machine: the far Mac ran `roamrun pair control --with <it>`
  with the RoamRun app open, this printed the code once the device had picked the far Mac, the code was typed,
  and both said the pairing was kept and switched on; the far Mac then showed device control as connected.
- On macOS, once, with no line carried and the firewall off: the far Mac saved the device and its bridge came up
  Ready; nothing was left announced. With the firewall on,
  under a test service type and a Linux machine standing in for the device: macOS asked whether to let `roamrunctl`
  take incoming connections; one got through while the question stood, and after it was allowed. Refusing wasn't tried.
- 0.5.0 is the first release that carries it. Before it, the Linux and Windows install commands were run against
  archives served locally; the tap's formula and `cargo install --git` are run as part of releasing.
- After a review changed how it reads the far Mac's wire, ends its relay, picks its interface and stops, the mechanics
  were checked again on macOS (`cargo test`, `scripts/local-check.py`, a fake far Mac that misbehaves), and against
  the real device once each: Xcode's pairing from the Windows machine with no line carried (the far Mac saved the
  device, its bridge came up Ready, and this ended by itself), and device control's pairing from the Linux machine
  (the far Mac said it was kept and switched on; nothing was left running or listening). On that Windows machine,
  under a test service type: the announcement was taken back on Ctrl-C and on closing the console's window.
  Ctrl-Break, a dropped ssh session against a real device, and a machine with two interfaces on the device's
  network weren't tried.
- A second round of review then changed how the relay ends a broken connection, how a line is read, and what is
  asked of Tailscale again after the wait for an offer: checked the same way on macOS, and run against the real device
  again, the same two ways (Xcode's pairing from the Windows machine: saved, Ready; device control's from the Linux
  machine: kept and switched on; nothing left on either). The far Mac got the device's whole Tailscale name and saved it by it.
