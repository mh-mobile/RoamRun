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

Windows (PowerShell) — into a folder `roamrunctl-windows-x86_64` where you are (on an ARM PC, `aarch64` in place of
`x86_64`, both times):

```
irm https://github.com/mh-mobile/RoamRun/releases/latest/download/roamrunctl-windows-x86_64.zip -OutFile roamrunctl.zip; Expand-Archive roamrunctl.zip .
```

macOS, or Linux with Homebrew — built from source: `brew install mh-mobile/tap/roamrunctl`.
Anywhere with Rust: `cargo install --locked --git https://github.com/mh-mobile/RoamRun roamrunctl`.

Those two commands only fetch an archive of the newest [release](https://github.com/mh-mobile/RoamRun/releases)
and unpack it: `roamrunctl-linux-x86_64.tar.gz`, `roamrunctl-linux-aarch64.tar.gz`, `roamrunctl-windows-x86_64.zip` or
`roamrunctl-windows-aarch64.zip`,
each with the binary, this file and the licenses of the crates it is built from (the Linux command above takes
the binary alone out of it). `roamrunctl-SHA256SUMS` there lists their checksums. The Linux builds
are static, for any distribution. The Windows one isn't signed: SmartScreen may ask before it runs the first time.
It isn't on Homebrew's or crates.io's own lists. Its version is RoamRun's: use the same on the far Mac.

## Use

```
roamrunctl pair introduce --mac <far Mac's Tailscale name> --to <device's Tailscale name> [--offer <line>] [--as <name>] [--deadline <secs>]
```

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
your own — an agent that ran it would have the code in its output. Exit 0: that Mac's app kept the pairing.
Exit 0: the far Mac said it saved the device (or none was asked). Exit 1 with a line: hand it to `roamrun devices add` there.

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
- Not run on Windows beyond the tests: how its announcement sits beside Windows' own mDNS, and what a firewall
  there asks, isn't known. Not run on Linux with a firewall on, or without avahi.
- Device control's pairing, once, from the same Linux machine: the far Mac ran `roamrun pair control --with <it>`
  with the RoamRun app open, this printed the code once the device had picked the far Mac, the code was typed,
  and both said the pairing was kept and switched on; the far Mac then showed device control as connected.
- Not packaged: no release archive, no skill, and its crates' licenses aren't gathered anywhere yet.
