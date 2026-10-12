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
roamrunctl pair introduce --host <far Mac's Tailscale name> --to <device's Tailscale name> [--offer <line>] [--as <name>] [--deadline <secs>] [--on <address>]
```

Both names are Tailscale's, as `tailscale status` lists them — the first label, or the whole name for a machine of
another tailnet — never what a device calls itself: two may both be "iPhone". A name that is more than one peer is
refused. A machine with more than one interface on the device's network (wired and Wi‑Fi both, say) goes on with
the one its system sends to the device from, and says the others: on one network either does, and where they are
two networks numbered alike and the device doesn't list the far Mac, `--on <one of the others>` is the way to the other.

Needs Tailscale installed and logged in (`tailscale` in PATH, the App Store app on macOS, or the installer's copy on Windows).
Without `--offer`, the far Mac runs `roamrun pair xcode --with <this machine>` and the offer comes over port 41830
(`--deadline` is then 300 s at most, as long as RoamRun's own `pair introduce` waits); it then saves the device itself. That takes a
`roamrun` that answers a Windows or Linux machine after `--with` (0.5.0); with an older one, or where that port
is shut, the offer is carried: `--offer "$(ssh <far Mac> roamrun pair xcode)"`.
On a tried pairing, the device's line for `roamrun devices add` is printed on stdout; everything else goes to stderr.
The far Mac saves the device under its Tailscale name; `--as` gives another. That Mac has the last word on a
name: one it has another device saved under, or doesn't take (a character no Unicode version assigns isn't told
apart here), it doesn't save — the line this prints then goes to `roamrun devices add <line> --as <another name>` there.

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

## Using a device from a machine without Xcode

A machine with a pairing of its own reaches the device over Tailscale by itself — no Mac, no Xcode. There are
two ways, and they differ in where the pairing's key is. (Tried against a device on Linux and macOS. The
Windows build has the same commands — it builds, and its tests pass there — and wasn't run against one.)

### A. The machine that uses the device holds the key

Where that machine is on the device's own Wi‑Fi, it pairs there and then (it shows the pairing code: run it
yourself):

```sh
roamrunctl pair control --to <the device's Tailscale name> --as phone
# on the device: Settings › Privacy & Security › Developer Mode › this machine's name, and the code
```

Where it isn't — a machine in a cloud — one that is on the device's Wi‑Fi introduces it, once:

```sh
# on the machine that will use the device (it shows the pairing code: run it yourself)
roamrunctl pair control --with <the machine beside the device> --as phone
# on a machine on the device's Wi‑Fi (roamrun on a Mac, or the Introducer app, do the same)
roamrunctl pair introduce --host <the machine that will use it> --to <the device's Tailscale name>
# on the device: Settings › Privacy & Security › Developer Mode › that machine's name, and the code

# from then on, on the machine that uses the device
roamrunctl look phone shot.png        # the device's own screenshot, 1280 at most on its longer side
roamrunctl install phone App.ipa      # an app built and signed for the device already
roamrunctl launch phone com.example.App
roamrunctl mcp                        # the same, and tap / swipe / type / press, as MCP tools
```

A Mac with RoamRun can make the pairing and hand it over instead: `roamrun key create <device> device.key`
there, `roamrunctl key import device.key` here.

The saved pairing is a key: whoever can read it and reach the device can see and operate it. It is a file
only its owner can read (`~/.config/roamrunctl/devices/<name>.json`, `%APPDATA%\roamrunctl` on Windows; one
that others can read is refused). So **any program running as that user, an agent among them, can use the
device**: that is what this way is.

`--passphrase` (on `pair control` and `key import`) keeps it in age's passphrase format instead. The passphrase
then comes from `ROAMRUNCTL_PASSPHRASE_FILE`, else `ROAMRUNCTL_PASSPHRASE_COMMAND` (run by `sh -c`, or
`cmd /C`), else `ROAMRUNCTL_PASSPHRASE`, else it is typed at a terminal — at every command, since each is a new
process (`roamrunctl mcp` asks once and keeps the device open); never from the command line. It keeps the file
from being a key on its own, in a backup or a copied home folder. It doesn't keep the device from a program
that runs as the same user and can read the passphrase where you put it.

### B. Another machine keeps the key, and signs

For when the key shouldn't be on the machine an agent runs on.

```sh
# on your machine, on the device's Wi‑Fi: pair there (it shows the code)
roamrunctl pair control --to <the device's Tailscale name> --as phone --passphrase
# and leave this running: it names the devices, and the one machine it signs for
roamrunctl sign phone --for <the machine that uses the device>
# on the machine that uses the device: nothing to set up
roamrunctl devices          # phone   its key is kept by <your machine>, which signs for this machine
roamrunctl mcp              # look, install, launch: as in A
```

A connection to the device has one thing signed with the pairing's key. `roamrunctl sign` signs that — for the
devices named, for the one machine named (held to its tailnet address and Tailscale's id for it), and for
nothing that isn't shaped as that check — and says each connection it signs. The machine that uses the device
saves nothing: at each command it asks its user's other machines on the tailnet which of them signs for it, is
told the devices without their keys, and does everything else itself. So the key can't be copied off the
machine that uses the device, and Ctrl-C in `sign` ends its making new connections (one already open goes on
until it closes). What it doesn't do: keep that machine, or an agent on it, from using those devices while
`sign` answers.

`--passphrase` earns its keep here: it is typed once, when `sign` starts, and kept nowhere. To not type it,
hand it by a command that reads your keychain — on a Mac:
`ROAMRUNCTL_PASSPHRASE_COMMAND='security find-generic-password -a "$USER" -s roamrunctl -w'`.

Only machines of the same Tailscale user are asked, and what one answers is taken only for a device that is on
this tailnet. A tagged machine (CI) is nobody's and asks none: name the signer there,
`ROAMRUNCTL_SIGNER=<its Tailscale name>`.

## Where it stands

- A pairing of its own: `roamrunctl pair control --with` ran on a Linux VM on the tailnet, introduced by this
  crate's `pair introduce --host` on a Mac beside the device; the iPhone listed the VM, paired, and the VM
  looked at its screen. The key on another machine: `roamrunctl sign` on a Mac, `devices add` and a look on
  the Linux VM, which held no key; once `sign` was stopped the VM's next connection was refused. (Since then
  a passphrase is asked for only with `--passphrase`, `sign` names its devices, and the other machine finds it
  by asking instead of being given a line: see the pull request for what was run again.)
- Holding a device: built on macOS and on Linux (musl, static); tried from an unprivileged Linux container
  against an iPhone 15 Pro on iOS 27.0 — connect, look, tap, type, a button, install, launch; taps through
  `roamrunctl mcp` with the device upright and on either side. The container reached the tailnet through its
  host's Tailscale: a machine with Tailscale of its own in userspace mode wasn't tried. A device that no Xcode
  ever prepared wasn't tried either (launching may need it).

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
