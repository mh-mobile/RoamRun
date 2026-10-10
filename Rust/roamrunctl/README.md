# roamrunctl

RoamRun's `pair introduce` for a machine that has no RoamRun — Windows, Linux, or a Mac: on the device's Wi‑Fi
it announces a far Mac's offer to pair — with Xcode, or with the RoamRun app there for device control — and carries
the device's one connection to that Mac over Tailscale. Behaviour follows `Sources/RoamRun/Introductions.swift` and
`PairByName.swift`. What it has been tried with is in the last section.

## Install

Linux — the binary into `~/.local/bin`:

```
mkdir -p ~/.local/bin && curl -fsSL https://github.com/mh-mobile/RoamRun/releases/latest/download/roamrunctl-linux-$(uname -m).tar.gz | tar -xz -C ~/.local/bin --strip-components 1 roamrunctl-linux-$(uname -m)/roamrunctl
```

If `roamrunctl` isn't found afterwards, `~/.local/bin` isn't on your PATH yet: log in again (most distributions add
it once it exists), or run `~/.local/bin/roamrunctl`.

Windows (PowerShell) — into a folder `roamrunctl-windows-x86_64` where you are (on an ARM PC, `aarch64` in place of
`x86_64`, both times):

```
irm https://github.com/mh-mobile/RoamRun/releases/latest/download/roamrunctl-windows-x86_64.zip -OutFile roamrunctl.zip; Expand-Archive -Force roamrunctl.zip .
```

It isn't put on your PATH: run it as `.\roamrunctl-windows-x86_64\roamrunctl.exe`, or move the folder where you keep such things.

macOS, or Linux with Homebrew — built from source: `brew install mh-mobile/tap/roamrunctl`.
Anywhere with Rust: `cargo install --locked --git https://github.com/mh-mobile/RoamRun --tag v<version> roamrunctl`
(built that way, outside this folder, it takes whichever Rust is installed, and on Windows isn't the static build the archives hold).

Those two commands only fetch an archive of the newest [release](https://github.com/mh-mobile/RoamRun/releases)
and unpack it: `roamrunctl-linux-x86_64.tar.gz`, `roamrunctl-linux-aarch64.tar.gz`, `roamrunctl-windows-x86_64.zip` or
`roamrunctl-windows-aarch64.zip`,
each with the binary, this file and the licenses of the crates it is built from (the Linux command above takes
the binary alone out of it). `roamrunctl-SHA256SUMS` there lists their checksums. The Linux builds
are static, for any distribution. The Windows ones aren't signed: SmartScreen may ask before one runs the first time, and Windows' firewall
asks, the first time it announces, whether to let it in — allow it, on the kind of network the Wi‑Fi is set as (the
device connects to it, and it answers the device's questions over mDNS). The device asked while that question
stood: if Settings doesn't list the far Mac afterwards, leave Developer Mode and open it again.
It isn't on Homebrew's or crates.io's own lists. Its version is RoamRun's: use the same on the far Mac.

For an agent that is to use it: the skill in [`skills/roamrunctl`](../../skills/roamrunctl/SKILL.md) —
`npx skills add mh-mobile/RoamRun` offers it, and each archive carries it as `SKILL.md`.

A firewall on the machine has to let the device in: it connects over TCP to the port `roamrunctl` says it announces
on, from the address it says the device has. With ufw on Ubuntu (which lets mDNS in as it comes) that is
`sudo ufw allow proto tcp from <the device's address>`; on Windows, the question it asks is enough.

## Use

```
roamrunctl pair introduce --mac <far Mac's Tailscale name> --to <device's Tailscale name> [--offer <line>] [--as <name>] [--deadline <secs>] [--on <address>]
```

Both names are Tailscale's, as `tailscale status` lists them — the first label, or the whole name for a machine of
another tailnet — never what a device calls itself: two may both be "iPhone". A name that is more than one peer is
refused. A machine with more than one interface on the device's network (wired and Wi‑Fi both, say) goes on with
the one its system sends to the device from, and says the others: on one network either does, and where they are
two networks numbered alike and the device doesn't list the far Mac, `--on <one of the others>` is the way to the other.

Needs Tailscale installed and logged in (`tailscale` in PATH, the App Store app on macOS, or the installer's copy on Windows).
Without `--offer`, the far Mac runs `roamrun pair xcode --with <this machine>` and the offer comes over port 41830
(`--deadline` is then 300 s at most: the far Mac waits no longer); it then saves the device itself. That takes a
`roamrun` that answers a Windows or Linux machine after `--with` (0.5.0); with an older one, or where that port
is shut, the offer is carried: `--offer "$(ssh <far Mac> roamrun pair xcode)"`.
On a tried pairing, the device's line for `roamrun devices add` is printed on stdout; everything else goes to stderr.
The far Mac saves the device under its Tailscale name; `--as` gives another.

For device control the far Mac runs `roamrun pair control --with <this machine>` instead, with the RoamRun app
open there; the same command here answers it (there is no line to carry for this, so no `--offer`). The code to
type on the device is made on the far Mac and printed here, on standard error: run this yourself, in a terminal of
your own — an agent that ran it would have the code in its output.

How it ends. Xcode's pairing: exit 0 once the far Mac said it saved the device (with `--offer` no Mac is asked:
exit 0 with the line, which is then `roamrun devices add`'s there); exit 1 with a line when it didn't say so — hand
it to `roamrun devices add` there; exit 1 without one when nothing was tried, or when one was and the device's own
announcement wasn't seen here. Device control: exit 0 when that Mac's app kept the pairing, exit 1 with why not.
Ctrl-C, a closed terminal and a dropped ssh session all take the announcement back before it ends (seen on macOS,
and on Windows for Ctrl-C and a closed console; Ctrl-Break is listened for the same way, untried).

## Build and check

```
cargo build --locked && cargo test   # in this folder, inside a checkout: the version comes from ../../Info.plist
python3 scripts/local-check.py target/debug/roamrunctl $(ipconfig getifaddr en0)   # macOS: mechanics on this Mac alone
```

The check uses a test service type (`_rrtest._tcp`), a fake far Mac on 127.0.0.1:53050 and a fake device record, so no
device sees anything. It confirms the record resolves through mDNSResponder, a stranger is refused, the carried connection
ends the run, the device line is made, and the goodbye reaches a browser within a few seconds.

## Where it stands

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
- No release carries it yet (0.5.0 is the first): the Linux and Windows install commands were run against archives
  served locally, not against a release; the tap's formula and `cargo install --git` weren't run.
- After a review changed how it reads the far Mac's wire, ends its relay, picks its interface and stops, the mechanics
  were checked again on macOS (`cargo test`, `scripts/local-check.py`, a fake far Mac that misbehaves), and against
  the real device once each: Xcode's pairing from the Windows machine with no line carried (the far Mac saved the
  device, its bridge came up Ready, and this ended by itself), and device control's pairing from the Linux machine
  (the far Mac said it was kept and switched on; nothing was left running or listening). On that Windows machine,
  under a test service type: the announcement was taken back on Ctrl-C and on closing the console's window.
  Ctrl-Break, a dropped ssh session against a real device, and a machine with two interfaces on the device's
  network weren't tried.
