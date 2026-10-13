# roamrunctl: reference

The details behind [roamrunctl's README](../Rust/roamrunctl/README.md): what to open in a firewall, how long
each step waits, and what each side checks. What was run on a device is in
[roamrunctl-tried.md](roamrunctl-tried.md).

Three machines are spoken of, and one machine can be two of them: the **near machine** is on the device's
Wi‑Fi; the **using machine** runs `look`, `install`, `launch` and `mcp`; the **key's machine** keeps the
pairing's key (the using machine itself in A, another in B).

## Installing

- The archives of a release are `roamrunctl-linux-x86_64.tar.gz`, `roamrunctl-linux-aarch64.tar.gz`,
  `roamrunctl-windows-x86_64.zip` and `roamrunctl-windows-aarch64.zip`. Each holds the binary, the README,
  `SKILL.md`, the repository's license and the licenses of the crates it is built from.
- The Linux builds are static, for any distribution. If `roamrunctl` isn't found after installing,
  `~/.local/bin` isn't on your PATH yet: log in again, or run `~/.local/bin/roamrunctl`.
- On Windows the firewall asks, the first time roamrunctl announces, whether to let it in: allow it on the
  kind of network the Wi‑Fi is set as. If the device doesn't list the machine afterwards, leave Developer Mode
  on the device and open it again.
- `cargo install --git` builds outside this repository's folder, so it takes whichever Rust is installed (1.89
  or later) and a C compiler; on Windows the cryptography may ask for NASM (x86_64) or clang (ARM64). The
  result isn't the static build the archives hold. It isn't on crates.io or in Homebrew's own lists.
- Its version is RoamRun's. Before 0.7.0 `pair introduce` named its machine with `--mac`; it is `--host` now,
  in `roamrun` and `roamrunctl` alike, and an older one of either shows the other name in what it tells you
  to run.

## What has to be let in

| Step | Who connects to whom | Port |
|---|---|---|
| `pair control --to` | the device → this machine, on the Wi‑Fi | the one the command prints |
| `pair control --with` | the near machine → the using machine, over Tailscale | 41830, then another each time, which the command prints |
| every use (`look`, `mcp`, …) | the using machine → the device, over Tailscale | the device's own |
| B, every connection | the using machine → the key's machine, over Tailscale | 41831 |
| `pair introduce` | the device → this machine, on the Wi‑Fi; this machine → the host, over Tailscale | printed; 41830 and the host's pairing port |

- For `pair control --to` only this machine's own firewall matters: the connection is on the Wi‑Fi and is
  taken from the device's address alone. With ufw (which lets mDNS in as it comes):
  `sudo ufw allow proto tcp from <the device's address>`.
- For `pair control --with`, let the near machine in on any TCP port, by Tailscale's rules and the using
  machine's firewall. If port 41830 is shut the near machine reads it as nobody waiting; if the second port
  is shut, both commands say so.
- `pair control --to` and `pair introduce` need Tailscale to reach the device directly on a network this
  machine is on, over IPv4. Relayed, or over IPv6, they stop before announcing anything.
- In B the key's machine reaches the device over the tailnet too: a pairing is tried that way before it is
  kept.

## How long each step waits

- `pair control --to`: seven minutes for the device to be picked and the code typed.
- `pair control --with`: ten minutes for the near machine, seven for the pairing. After a wrong code it waits
  again, five tries in all.
- `pair introduce`: five minutes (`--deadline`, 300 seconds at most when the host is asked for its offer).
  Before that it tries the host's port 41830 for up to ten minutes, so either command can be started first.
- `install`: five minutes, plus fifteen seconds for each megabyte — about four times what it took on the device's own
  Wi‑Fi (3 MB in 25 seconds, 37 MB in two and a half minutes).

## The key file and passphrases

- The folder is `~/.config/roamrunctl/devices` (under `$XDG_CONFIG_HOME` where that is set to an absolute
  path); on Windows `%LOCALAPPDATA%\roamrunctl\devices`. A device is `<name>.json`, or `<name>.age` under a
  passphrase.
- On Linux and macOS the file is made for its owner alone (0600, in a folder of 0700), and one that others can
  read is refused. On Windows nothing is checked: it is the user's by what the profile folder gives it.
- `--passphrase` (on `pair control` and `key import`) keeps the key in age's passphrase format. The passphrase
  is never taken from the command line. The first of these that is set is used, and if it fails the command
  stops: `ROAMRUNCTL_PASSPHRASE_FILE`, `ROAMRUNCTL_PASSPHRASE_COMMAND` (run by `sh -c`; on Windows by
  `cmd /S /C`), `ROAMRUNCTL_PASSPHRASE`. With none set it is typed, which needs a terminal.

| Command | The passphrase |
|---|---|
| `pair control --passphrase`, `key import --passphrase` | typed twice, or taken from what is set |
| `look`, `install`, `launch` | each time: every command is a new process |
| `mcp` | from what is set only, each time it opens a device |
| `sign` | once for each device named that is kept under one, when it starts |
| `devices`, `devices remove` | not asked |

- To not type it when `sign` starts, on a Mac with it stored in the keychain:
  `ROAMRUNCTL_PASSPHRASE_COMMAND='security find-generic-password -a "$USER" -s roamrunctl -w'`.
- A Mac with RoamRun can make a pairing and hand it over: `roamrun key create <device> device.key` there (the
  device on that Mac's Wi‑Fi, a code typed), `roamrunctl key import device.key` here. Import tries the key
  over the tailnet, saves it and removes `device.key`.

## B: what is checked

A connection to the device has one thing signed with the pairing's key. The using machine asks the key's
machine for that signature and does everything else itself.

- `sign` answers the one machine named with `--for`, held to its tailnet address and to Tailscale's id for it.
  It signs for the devices named, and only what has the shape of a connection's check — not what making a new
  pairing signs. It answers one request at a time.
- `sign` reads each device's file when it starts and holds to it. After pairing a device again under its name,
  end `sign` and run it again; both sides say so. Removing the device on the key's machine ends new
  connections for it.
- The using machine asks the machines of its own user that Tailscale lists as online. A tagged machine is
  nobody's: where either machine is tagged, or the two are different users', set
  `ROAMRUNCTL_SIGNER=<the key's machine>` on the using machine (for `mcp`, in the agent's MCP config). `sign`
  says so when it starts. A name there that isn't on the tailnet is reported; devices saved on the using machine
  itself are used all the same.
- The first time the using machine uses a device, it saves which machine signs for it and which device that
  is (no key), and holds to that from then on. If it can't save that, it doesn't use the device. Until then it
  believes any of its user's machines that offers the name — of two, the one whose Tailscale name sorts first.
  On a tailnet where one of those may be someone else's to run, set `ROAMRUNCTL_SIGNER` from the start.
  `roamrunctl devices remove <name>` on the using machine forgets it.
- The using machine knows a device by the name its key's machine saved it under. Two key's machines that sign
  for one device have to have saved it under different names.
- Not tried: whether a connection, once made, can add a pairing of its own on the device. If it can, B keeps
  no key from the using machine.

## The MCP tools

- `look` returns the picture to the agent; the `look` command writes a PNG file. Both are the device's own
  screenshot, 1280 pixels at most on the longer side.
- A look serves one `tap` or `swipe`, within a minute. Any other call to the device in between (`type`,
  `paste`, `press`, `elements`, `install`, `launch`) spends it.
- A tap or swipe is refused where the device says it was turned since the look, where the picture's shape
  disagrees with the way the device said it was, and where the device is on its side and doesn't say which
  way. A turn isn't noticed where the device says nothing about its way either time and the picture is upright.
- `type`, `paste` and `press` go to whatever is on the screen. `paste` makes the device ask "Allow Paste".
- A call the agent takes back before its turn isn't made, nor one whose turn comes after the agent went; one
  that is already running finishes.
- While `mcp` runs, a device removed, or another saved under its name, isn't the one it had open: it is opened
  anew, or reported as gone.
- No screen-sharing session shows and sound went on playing with looks, taps, keys and buttons (Apple Music,
  iOS 27.0). Swipes, paste and the microphone weren't looked into.

## Installing an app

- An .app folder is put on the device under its own name before it is taken in, and an .ipa under one fixed
  name. So only one install to a device should run at a time; nothing enforces that between two commands.
- What an install that was cut short left on the device is cleared before an .app folder is sent again, where
  it can be.
- The `install` command prints the size (in whole megabytes) and its time limit, then nothing until the app
  is in. The MCP tool says nothing until it ends.

## `pair introduce`

```
roamrunctl pair introduce --host <host> --to <device> [--offer <line>] [--as <name>] [--deadline <secs>] [--on <address>]
```

- Both names are Tailscale's: the first label, or the whole name for a machine of another tailnet. A name that
  is more than one peer is refused. Tailscale has to be installed and logged in (`tailscale` in PATH, the App
  Store app on macOS, or the installer's copy on Windows).
- `--offer` carries Xcode's offer by hand instead of asking the host for it:
  `--offer "$(ssh <far Mac> roamrun pair xcode)"`. For an older RoamRun there, or where port 41830 is shut.
  There is no such line for device control.
- `--as` gives the name the host saves the device under. A Mac with RoamRun has the last word on it: one it
  doesn't take, it doesn't save, and the line printed here then goes to
  `roamrun devices add <line> --as <another name>` there. A host with roamrunctl uses its own `--as` first.
- `--on` picks the interface on a machine with more than one on the device's network. Without it, the one the
  system sends to the device from is used, and it names the others.
- A device that waits to be picked by a Mac (an Apple Vision Pro with Remote Devices open) is paired by a Mac
  only: a Mac's `roamrun pair introduce` refuses a `--host` that isn't one for it.
- For Xcode's pairing the device's line for `roamrun devices add` is printed on standard output; everything
  else, the pairing code among it, goes to standard error.

| Exit | When |
|---|---|
| 0 | Xcode's pairing: the host said it saved the device (with `--offer`: a pairing was tried; the line goes to `roamrun devices add` there). Device control: the host kept the pairing |
| 1, with a line | Xcode's pairing was tried and the host didn't say it saved the device: hand the line to `roamrun devices add` there |
| 1, without | nothing was tried, or the device's own announcement wasn't seen here; device control: the host kept nothing, and it says why |
| 2 | the command was written wrong (`--mac` among it) |

Ctrl-C, a closed terminal and a dropped ssh session all take the announcement back before it ends (seen on
macOS, and on Windows for Ctrl-C and a closed console).

## Building and checking

```
cargo build --locked && cargo test   # in Rust/roamrunctl, inside a checkout: the version comes from ../../Info.plist
python3 scripts/local-check.py target/debug/roamrunctl $(ipconfig getifaddr en0)   # macOS: the mechanics on this Mac alone
```

The check offers no real device a pairing: the offer goes out under a test service type (`_rrtest._tcp`), to a
fake host on 127.0.0.1. A fake device's record is on the LAN while it runs. It confirms that the record
resolves, a stranger is refused, the carried connection ends the run, the device's line is made, and the
goodbye reaches a browser within a few seconds; then the same for device control, against a fake host on port
41830 of this Mac, which has to be free.

Behaviour follows the Mac's side: `Sources/RoamRun/Introductions.swift` and `PairByName.swift` for
`pair introduce`, and `ControlIntroductions.swift` for `pair control --with`.
