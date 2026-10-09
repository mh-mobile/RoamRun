# roamrunctl

A prototype of RoamRun's `pair introduce` for a machine that isn't a Mac (Windows, Linux, macOS):
on the device's Wi‑Fi it announces a far Mac's offer to pair with Xcode and carries the device's one
connection to that Mac over Tailscale. Behaviour follows `Sources/RoamRun/Introductions.swift` and
`PairByName.swift`. Nothing here is shipped yet, and it hasn't met a real device: see the last section.

```
roamrunctl pair introduce --mac <far Mac's Tailscale name> --to <device's Tailscale name> [--offer <line>] [--as <name>] [--deadline <secs>]
```

Needs Tailscale installed and logged in (`tailscale` in PATH, the App Store app on macOS, or the installer's copy on Windows).
Without `--offer`, the far Mac would run `roamrun pair xcode --with <this machine>` and the offer come over port 41830
(`--deadline` is then 300 s at most: the far Mac waits no longer) — but `roamrun` answers only a Mac, or the device
itself, after `--with`, so for now the offer is carried: `--offer "$(ssh <far Mac> roamrun pair xcode)"`.
On a tried pairing, the device's line for `roamrun devices add` is printed on stdout; everything else goes to stderr.
Exit 0: the far Mac said it saved the device (or none was asked). Exit 1 with a line: hand it to `roamrun devices add` there.

## Build and check

```
cargo build --locked && cargo test
python3 scripts/local-check.py target/debug/roamrunctl $(ipconfig getifaddr en0)   # macOS: mechanics on this Mac alone
```

The check uses a test service type (`_rrtest._tcp`), a fake far Mac on 127.0.0.1:53050 and a fake device record, so no
device sees anything. It confirms the record resolves through mDNSResponder, a stranger is refused, the carried connection
ends the run, the device line is made, and the goodbye reaches a browser within a few seconds.

## Where it stands

- Built and tested (`cargo test`) on macOS; CI builds and tests it on Linux and Windows too.
- `scripts/local-check.py` passes on macOS: the mechanics, against a fake far Mac and a fake device.
- Not yet run against a real device, on any system. Not yet run at all on Linux or Windows beyond the tests:
  how its announcement sits beside avahi or Windows' own mDNS, and what a firewall there asks, isn't known.
- Xcode's pairing only: device control's (`pair control`) isn't here.
- Not packaged: no release archive, no skill, and its crates' licenses aren't gathered anywhere yet.
