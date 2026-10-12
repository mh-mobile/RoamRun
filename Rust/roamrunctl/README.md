# roamrunctl

For a machine that has no RoamRun — Windows, Linux, or a Mac. Since 0.7.0 it can hold a pairing with an iPhone or iPad
itself and use the device over Tailscale with no Xcode: screenshots, installing and launching apps, and the same as
MCP tools for an agent — see [Using a device from a machine without Xcode](#using-a-device-from-a-machine-without-xcode).
And, as before, RoamRun's `pair introduce`: on the device's Wi‑Fi
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
(built that way, outside this folder, it takes whichever Rust is installed — 1.89 or later — and a C compiler; on Windows its
cryptography may ask for more to build with (NASM on x86_64, clang on ARM64), and it isn't the static build the archives hold).

Those two commands only fetch an archive of the newest [release](https://github.com/mh-mobile/RoamRun/releases)
and unpack it: `roamrunctl-linux-x86_64.tar.gz`, `roamrunctl-linux-aarch64.tar.gz`, `roamrunctl-windows-x86_64.zip` or
`roamrunctl-windows-aarch64.zip`,
each with the binary, this file and the licenses of the crates it is built from (the Linux command above takes
the binary alone out of it). `roamrunctl-SHA256SUMS` there lists their checksums. The Linux builds
are static, for any distribution. The Windows ones aren't signed: SmartScreen may ask before one runs the first time, and Windows' firewall
asks, the first time it announces, whether to let it in — allow it, on the kind of network the Wi‑Fi is set as (the
device connects to it, and it answers the device's questions over mDNS). The device asked while that question
stood: if Settings doesn't list the far Mac afterwards, leave Developer Mode and open it again.
It isn't on Homebrew's or crates.io's own lists. Its version is RoamRun's: use the same on the far Mac. Since 0.7.0
`pair introduce` names that machine with `--host`, not `--mac`, here and in `roamrun`: an earlier one of either shows the other name in what it tells you to run.

For an agent that is to use it: the skill in [`skills/roamrunctl`](../../skills/roamrunctl/SKILL.md) —
`npx skills add mh-mobile/RoamRun` offers it, and each archive carries it as `SKILL.md`.

A firewall on the machine has to let the device in: it connects over TCP to the port `roamrunctl` says it announces
on, from the address it says the device has. With ufw on Ubuntu (which lets mDNS in as it comes) that is
`sudo ufw allow proto tcp from <the device's address>`; on Windows, the question it asks is enough.

## Using a device from a machine without Xcode

Since 0.7.0. A machine with a pairing of its own reaches the device over Tailscale by itself, with no Xcode on it.
Three machines are spoken of below, and one machine can be two of them:

- **the near machine**: on the device's Wi‑Fi. Pairing needs one, once.
- **the using machine**: where `look`, `install`, `launch` and `mcp` run — an agent's, perhaps in a cloud.
- **the key's machine**: where the pairing's key is kept. In A it is the using machine; in B it is another, of
  yours — the one that signs (`ROAMRUNCTL_SIGNER` names it).

A where the key may lie on the machine the agent runs on; B where it shouldn't. Neither limits what an agent
there does with the device.

| | What is run, and where |
|---|---|
| **A**, using machine on the device's Wi‑Fi | using machine: `pair control --to <device>` |
| **A**, using machine elsewhere | using machine: `pair control --with <near machine>` · near machine: `pair introduce --host <using machine> --to <device>` |
| **B** | key's machine, on the device's Wi‑Fi: `pair control --to <device>`, then `sign <name> --for <using machine>` left running · using machine: nothing — unless either machine is tagged, or the two are different users' (a cloud machine often is tagged): then `ROAMRUNCTL_SIGNER=<key's machine>` there, for `mcp` in the agent's MCP config |

Each `pair` command shows the pairing code, which is the owner's consent: run it yourself, in a terminal of your own.

Before starting:

- The device on Wi‑Fi (on cellular alone it refuses), unlocked once since it started, and connected in Tailscale.
- Tailscale's rules let the using machine reach the device, and — in B — the key's machine on TCP port 41831.
  In B the key's machine reaches the device over the tailnet too: a pairing is tried that way before it is kept.
- A machine that waits is let in, by Tailscale's rules and its own firewall: with `pair control --to`, the
  device, on the port the command says; with `pair control --with`, the near machine — on port 41830, and on a
  port that is another each time (the command says which once it has it), so let that machine in on any TCP
  port. A wait that isn't let in reads as nobody waiting.
- For `pair control --with`: a device that has been paired with something before (see below).
- In B, the using machine can write to its own devices folder (`~/.config/roamrunctl/devices`; on Windows
  `%LOCALAPPDATA%\roamrunctl\devices`): what it holds a device to is saved
  there, and without that it doesn't use the device.

### A. The using machine holds the key

On the device's own Wi‑Fi, it pairs there and then:

```sh
roamrunctl pair control --to <the device's Tailscale name> --as phone
# on the device: Settings › Privacy & Security › Developer Mode › this machine's name, and the code
```

The device connects to this machine for that: a firewall here has to let it in. The command says the port it
announced and the device's address on the Wi‑Fi (with ufw: `sudo ufw allow proto tcp from <that address>`).

Elsewhere — a machine in a cloud — the near machine introduces it, once:

```sh
# on the using machine
roamrunctl pair control --with <the near machine> --as phone
# on the near machine (`roamrun pair introduce` on a Mac does the same)
roamrunctl pair introduce --host <the using machine> --to <the device's Tailscale name>
# on the device: Settings › Privacy & Security › Developer Mode › the using machine's name, and the code
```

The code shows on both machines. What the near machine prints calls the using machine "the host". The near
machine gives the pairing five minutes.

With the Introducer app on the device (built from `iOS/` with Xcode) there is no near machine: the using machine
names the device itself, `roamrunctl pair control --with <the device's Tailscale name>`, and in the app the using
machine's Tailscale name goes where it asks for the far Mac's. A Mac's `roamrun pair introduce` needs the device
saved in RoamRun there.

`--with` is for a device that has been paired with something before: one that never was announces nothing the
near machine could pass on, and `pair introduce` says so. Pair it once first, with a Mac's Xcode or with
`pair control --to` on the near machine — which then holds a key too: `roamrunctl devices remove` it there if it
isn't to. (Whether the latter alone is enough wasn't tried.)

From then on, on the using machine:

```sh
roamrunctl look phone shot.png        # the device's own screenshot, 1280 at most on its longer side
roamrunctl install phone App.ipa      # an app built and signed for the device already
roamrunctl launch phone com.example.App
roamrunctl mcp                        # the same, and tap / swipe / type / paste / press / elements, as MCP tools
```

For an agent, its MCP config names the command `roamrunctl` with the argument `mcp`.

A Mac with RoamRun can make the pairing and hand it over instead: `roamrun key create <device> device.key`
there, `roamrunctl key import device.key` here.

The saved pairing is a key: whoever can read it and reach the device can see and operate it. It is
`~/.config/roamrunctl/devices/<name>.json` (under `$XDG_CONFIG_HOME` where that is set;
`%LOCALAPPDATA%\roamrunctl\devices` on Windows). On Linux and macOS it is made for its owner alone, and one that
others can read is refused; on Windows nothing is checked — it is the user's by what the profile folder gives it.
So **any program running as that user, an agent among them, can use the device**: that is what this way is.

`--passphrase` (on `pair control` and `key import`) keeps it in age's passphrase format instead. It keeps the
file from being a key on its own, in a backup or a copied home folder. It doesn't keep the device from a program
that runs as the same user and can read the passphrase where you put it. The passphrase is never taken from the
command line. It comes from `ROAMRUNCTL_PASSPHRASE_FILE`, else `ROAMRUNCTL_PASSPHRASE_COMMAND` (run by `sh -c`,
or `cmd /C`), else `ROAMRUNCTL_PASSPHRASE`, else it is typed:

| Command | The passphrase |
|---|---|
| `pair control --passphrase`, `key import --passphrase` | typed twice — or, where one of the three is set, taken from it |
| `look`, `install`, `launch` | each time: every command is a new process |
| `mcp` | from one of the three only: its input is the agent's, and nothing can be typed there |
| `sign` | once for each device named that is kept under one, when it starts |
| `devices`, `devices remove` | not asked |

### B. Another machine keeps the key, and signs

For when the key shouldn't lie on the machine an agent runs on.

```sh
# on the key's machine, on the device's Wi‑Fi: pair there
roamrunctl pair control --to <the device's Tailscale name> --as phone --passphrase
# and leave this running: it names the devices, and the one machine it signs for
roamrunctl sign phone --for <the using machine>

# on the using machine: nothing to set up (tagged, or another user's: ROAMRUNCTL_SIGNER=<the key's machine>)
roamrunctl devices          # phone   its key is kept by <the key's machine>, which signs for this machine (not used here yet)
roamrunctl look phone       # the first time: "phone is used for the first time here: <the key's machine> signs for it, and that is held to from now on"
roamrunctl mcp              # look, install, launch: as in A
```

A connection to the device has one thing signed with the pairing's key. The using machine asks the key's machine
for that signature (TCP port 41831, on the tailnet), and does everything else itself — it reaches the device
directly, as in A. The key's machine has to let it in on that port (Tailscale's rules, and its own firewall).

**What this gives:** the key isn't on the using machine to be copied from; ending `sign` (Ctrl-C), or removing the
device on the key's machine, ends new connections; and `sign` says each connection it signs. `sign` holds each
device to the file it read when it started: after pairing one again under its name, end `sign` and run it again
(both sides say so once the using machine has used the device; before that it only goes from what is listed there). (Not tried: whether a
connection, once made, can add a pairing of its own on the device. If it can, this keeps no key from that machine.)
**What it doesn't:** while `sign` answers, the using machine connects as often as it asks, any program on it can
ask, and a connection does everything. One already open — a running `roamrunctl mcp` — goes on after `sign` ends,
until it is closed. B is about where the key lies and when it can be used, not about what an agent may do.

How each finds the other, and what is trusted:

- `sign` answers the one machine named, held to its tailnet address and Tailscale's id for it. It signs for the
  devices named, and only what has the shape of a connection's check — not what making a new pairing signs. It
  answers one request at a time: that machine can make it wait, and no other.
- The using machine asks its user's other machines on the tailnet which signs for it. A tagged machine (CI) is
  nobody's and asks none, and another user's asks that user's, not yours: there, set
  `ROAMRUNCTL_SIGNER=<the key's machine>`. `sign` says so when it starts. A name there that isn't on the tailnet
  is said; devices saved on that machine itself are used all the same.
- The first time the using machine uses a device, it saves which machine signs for it and which device that is
  (no key), and holds to that from then on; where that can't be saved, the device isn't used. Until then it believes any of its user's machines that offers the
  name (of two, the one whose Tailscale name sorts first): on a tailnet where one of those may be someone else's
  to run, set `ROAMRUNCTL_SIGNER` from the start.
  `roamrunctl devices remove <name>` there forgets it.
- The using machine knows a device by the name its key's machine saved it under. Two key's machines that sign
  for one device (home and office) have to have saved it under different names.

To not type the passphrase when `sign` starts, hand it by a command that reads your keychain — on a Mac, once it
is stored there: `ROAMRUNCTL_PASSPHRASE_COMMAND='security find-generic-password -a "$USER" -s roamrunctl -w'`.

### What an agent's looks and inputs show on the device

A look is the device's own screenshot, and inputs are sent without a screen stream: the device lists no
screen-sharing session, and what plays goes on sounding (listened to with Apple Music on iOS 27.0, with looks,
taps, keys and buttons). Not looked into: swipes and paste that way, and the microphone. `paste` makes the device
ask "Allow Paste". Only `tap` and `swipe` are held to a look just taken; `type`, `paste` and `press` go to
whatever is on the screen. A call the agent takes back before its turn isn't made, nor one whose turn comes after
the agent went; one that runs already runs out. While `roamrunctl mcp` runs, a device removed, or another saved
under its name, isn't the one it had open: it is opened anew, or said to be gone.

`install` puts an app on the device under its own name before it is taken in, as every `roamrunctl install` of that
name does, and an .ipa under one name whatever it is: one install to a device at a time. What an install that was
cut short left there is cleared before an .app folder is sent again, where it can be (an install cut short and run again took the app in, once). An install says how much it sends and then nothing until the app is in:
a megabyte took three to four seconds on the device's own Wi‑Fi (3 MB in 25 s, 37 MB in two and a half minutes), and it
is given five minutes and fifteen seconds a megabyte, some four times that.

## Introducing a far Mac (`pair introduce`)

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

## Where it stands

### Holding and using a device (0.7.0)

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
- Taps through `mcp` with the device on either side (a key of the calculator, the one aimed at both times).
- `install` of an .app folder (3 MB) and `launch`; a larger one (37 MB) cut short with Ctrl-C a few seconds in,
  installed again (two and a half minutes) and launched.

Earlier, before the reviews: from an unprivileged Linux container, with a key made on a Mac — connect, look, tap,
type, a button, install, launch, and launching again after the device restarted; a wrong code at `pair control
--with` kept nothing.

Not yet run against a device:

- `sign` with more than one device, and `ROAMRUNCTL_SIGNER`.
- The Introducer app, and a Mac's `roamrun pair introduce`, introducing a machine with roamrunctl.
- `mcp`'s swipe, type, paste, install and launch (each was sent by the library directly, or by the command).
- An iPad, and a device held upside down.
- Anything on Windows: both targets build and pass their tests there, and that is all.
- A device no Xcode ever prepared (launching may need what Xcode leaves on it), and one nothing was paired with
  before (`pair control --with`).
- A machine whose Tailscale runs in userspace mode (the container borrowed its host's): it has no address to
  listen on or connect from, and `sign` and `pair control --with` are expected to stop there.
- The device's pairing port after it moved far: a saved device is looked for on the port it was saved with and
  the sixteen from 49152. One not found there after it restarted is paired again.

### `pair introduce` (since 0.5.0)

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
