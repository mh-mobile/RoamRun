# roamrunctl: reference

Detailed behavior and constraints behind the [roamrunctl README](../Rust/roamrunctl/README.md).
The README includes diagrams for the two key-storage models, remote pairing, and remote
signing; this document supplies the exact prerequisites, network rules, and edge cases.

- The **using machine** runs `look`, `install`, `launch`, or `mcp`.
- The **near machine** is on the device's Wi-Fi and introduces the device to a remote host.
- The **key's machine** holds the private key in the pairing record. In **A**, it is the using
  machine itself; in **B**, another machine keeps the key and signs each new connection.
- The **host** in `pair introduce --host` is the remote machine that makes and keeps the pairing.

One machine can fill multiple roles. The near machine forwards the initial pairing connection;
it does not keep the host's private pairing key. In B, device operations go directly between
the using machine and the device, not through the key's machine.

## Installing

- Release archives: `roamrunctl-linux-x86_64.tar.gz`, `roamrunctl-linux-aarch64.tar.gz`,
  `roamrunctl-windows-x86_64.zip`, and `roamrunctl-windows-aarch64.zip`. They include the binary,
  README, `SKILL.md`, and license notices. `roamrunctl-SHA256SUMS` contains their checksums.
- The Linux release binaries are static. If `roamrunctl` is not found after installing to
  `~/.local/bin`, add that directory to your `PATH` or run `~/.local/bin/roamrunctl` directly.
- The Windows archive extracts to a subdirectory. Run, for example,
  `.\roamrunctl-windows-x86_64\roamrunctl.exe`, or add that directory to `PATH`.
  The binaries are unsigned; SmartScreen may warn. Windows Firewall may ask to allow incoming
  connections when the program first advertises a pairing. Allow the appropriate network profile.
- `cargo install --locked --git ...` requires Rust 1.89 or later and a C compiler. This is a
  source build, not the release's static Linux build. `roamrunctl` is not published on
  crates.io; the Homebrew formula is in `mh-mobile/tap`, not Homebrew core.
- The reported version is RoamRun's version. Match versions between pairing participants.
  Before 0.7.0, `pair introduce` used `--mac` instead of `--host`; old and new releases may
  print incompatible commands.

## Initial pairing and network prerequisites

- The iPhone or iPad needs Tailscale, Developer Mode, Wi-Fi, and an unlock since its last boot.
  A device reachable over cellular alone does not accept these new connections.
- `pair control --to` pairs from a machine on the device's Wi-Fi. Tailscale must reach the
  device directly on that network over IPv4, not through a relay or via IPv6.
- For a remote `pair control --with <near machine>` using `pair introduce`, the near machine
  first needs the device's own `_remotepairing._tcp` advertisement. The device advertises
  it after it has paired with something. If it has never paired, pair it locally first
  (for example, with Xcode on a Mac), then retry remote introduction. The implementation
  also suggests `roamrunctl pair control --to <device>` on the near machine for this first
  pairing; this specific Mac-free sequence has not been tested.
- The separate iOS Introducer app can act as the introducer itself: use
  `roamrunctl pair control --with <device's Tailscale name>` on the using machine, then
  enter the using machine's name in the app. No separate near machine is needed.
- Use Tailscale **node names** (from `tailscale status`) for `--to`, `--with`, `--host`,
  and `--for`, not a device name displayed in iOS Settings. A short node name on the same
  tailnet or its complete Tailscale DNS name is accepted; ambiguous names are rejected.

## Ports and firewalls

| Operation | Connection | TCP port |
|---|---|---|
| `pair control --to` | device → using machine, over local Wi-Fi | dynamic port printed by the command |
| `pair control --with` | near machine → using machine, over Tailscale | 41830, then another dynamic port printed during pairing |
| `pair introduce` | device → near machine, over local Wi-Fi | dynamic port printed by the introducer |
| `pair introduce` | near machine → host, over Tailscale | 41830 when requesting an offer, then the host's pairing port |
| `look`, `install`, `launch`, `mcp` | using machine → device, over Tailscale | the device's pairing port, then a tunnel port the device names for that connection |
| B (`sign --for`) | using machine → key's machine, over Tailscale | 41831 |

- For `pair control --to`, the device connects to the one TCP port the command prints, from
  its own address on the Wi-Fi. The command prints two addresses: this machine's, and the
  device's, which it says "has to be let in". A firewall on the using machine has to allow that.
  Local Bonjour/mDNS discovery also has to work on the Wi-Fi (UDP 5353).
- What was run with a firewall: Ubuntu with ufw enabled, during a
  `pair introduce` under a test service, with a Mac standing in for the device. mDNS came
  through as ufw is installed. The TCP connection got no answer until
  `sudo ufw allow proto tcp from <the device's address>` was run, and then connected. A rule
  limited to the printed port was not tried. firewalld and others were not tried.
- For `pair control --with`, permit the named near machine to reach the using machine on
  TCP 41830 **and** the new port shown during the attempt, in both Tailscale's access policy
  and the using machine's firewall. The dynamic port changes between attempts. Port 41830
  being blocked looks like no host waiting; a blocked pairing port is reported separately.
  Broadly opening every TCP port is unnecessary if you can update the rule for the printed port.
- For `pair introduce`, the device must also be allowed into the near machine on its printed
  local TCP port. If an Xcode offer is supplied with `--offer`, asking the host on 41830 is
  not needed; the host's pairing port must still be reachable.
- In B, allow incoming TCP 41831 **from the named using machine** to the key's machine.
  Signing does not proxy screenshots or input; device traffic travels directly between
  the using machine and the device.
- macOS and Windows may prompt for incoming connections.
- roamrunctl chooses its address on the Wi-Fi by looking at its interfaces' addresses, not at
  the routing table. On one Windows machine, "Use Tailscale subnets" had routed its own LAN
  through Tailscale, and pairing went through all the same.
- A userspace-networking-only Tailscale setup may have no local Tailscale address to bind.
  `sign` and `pair control --with` are not expected to work in that configuration.

## Time limits

- `pair control --to`: seven minutes in all. Once the code shows, three minutes to enter it.
  A wrong or late code ends the command; run it again.
- `pair control --with`: up to ten minutes for the near machine to arrive. A `roamrunctl`
  near machine gives the pairing five minutes (this machine waits up to seven), and the code
  has three minutes once it shows. Only a device that connected and did not pair is waited
  for again, up to five attempts in all; each needs a new introduction. If the near machine
  runs out of time, this command ends.
- `pair introduce`: by default, five minutes of advertising (`--deadline`); 300 seconds
  maximum when it asks the host for an offer. Before that, it can wait up to ten minutes
  for the host on TCP 41830. Either machine can start its command first.
- `install`: five minutes plus 15 seconds per megabyte as its time limit. The command prints
  the size and time limit, then waits without progress output. In tests on the device's Wi-Fi,
  3 MB took about 25 seconds and 37 MB about two and a half minutes.

## Pairing records and passphrases

- Files are stored in `~/.config/roamrunctl/devices` on Linux/macOS, or under
  `$XDG_CONFIG_HOME/roamrunctl/devices` when `XDG_CONFIG_HOME` is an absolute path.
  On Windows the folder is `%LOCALAPPDATA%\roamrunctl\devices` (falling back to `%APPDATA%`).
  Each saved device is `<name>.json`, or `<name>.age` when encrypted.
- On Linux/macOS the directory is created with mode 0700 and the file with 0600; a file
  with any group or other permission is refused. Windows relies on permissions of the profile directory
  and does not perform the same Unix permission check.
- A plain JSON pairing record is a credential: a program that can read it **and** reach the
  device can use it. `--passphrase` on `pair control` and `key import` encrypts the file
  using age's passphrase format. The passphrase is not accepted as a command-line argument.
- The first configured source wins (and a failing source stops the command):
  `ROAMRUNCTL_PASSPHRASE_FILE` → `ROAMRUNCTL_PASSPHRASE_COMMAND` → `ROAMRUNCTL_PASSPHRASE`.
  The command source runs with `sh -c` (Windows: `cmd /S /C`). A passphrase in
  `ROAMRUNCTL_PASSPHRASE` is in the environment of every process started from that shell.
  Without a source, interactive commands prompt.

| Command | Passphrase handling |
|---|---|
| `pair control --passphrase`, `key import --passphrase` | prompts twice when creating a new encrypted record, or reads a configured source |
| `look`, `install`, `launch` | prompts when opening an encrypted record, or reads a configured source |
| `mcp` | cannot prompt; needs a configured source each time it opens an encrypted record |
| `sign` | reads or prompts when starting for each encrypted record it serves |
| `devices`, `devices remove` | no passphrase needed |

- For an MCP client, configure the passphrase source in the MCP server's environment, beside the
  command the README shows.
- An example for `ROAMRUNCTL_PASSPHRASE_COMMAND` on macOS, **if a matching Keychain item
  already exists**, is `security find-generic-password -a "$USER" -s roamrunctl -w`.
- Re-pairing a device under the same host identity replaces the earlier pairing on the device.
  An old record then fails to connect; remove it with `roamrunctl devices remove <name>`.
  Also remove the machine's pairing entry in the device's Developer Mode list when withdrawing it.
- Connections try the saved port and the sixteen ports from 49152. A device restarted twice,
  and taken off the network and back, announced 49152 each time; if a device cannot be
  reached on any of them, pair again.
- A Mac with RoamRun can create a key for import:
  `roamrun key create <device> device.key` on that Mac, then
  `roamrunctl key import device.key` on the using machine. Import verifies the device
  over Tailscale, stores the record, and removes the import file on success.

## B: remote signing and trust

In B the key's machine keeps the private key; the using machine requests only the signature
needed to establish each new device connection.

- `roamrunctl sign <device> --for <machine>` serves only the named Tailscale peer,
  checking its tailnet IP address and Tailscale node identity. It signs requests shaped
  like an existing pairing's connection verification, not requests to create new pairings.
  Requests are handled one at a time.
- `sign` loads the named device records when it starts. A record removed or replaced while
  it runs is no longer signed for; to serve the new record, restart `sign`.
- By default, the using machine discovers signers among **online, untagged Tailscale nodes
  belonging to the same Tailscale user**, provided the using machine is also untagged.
  If either machine is tagged, the machines belong to different users, or another node
  could claim the same device name, set `ROAMRUNCTL_SIGNER=<key machine's Tailscale name>`
  **before the first device use**. Automatic discovery is convenient on a trusted tailnet,
  but should not be used as a trust decision when machines may be run by others.
  For example, on Linux/macOS:

  ```sh
  export ROAMRUNCTL_SIGNER=home-pc
  roamrunctl devices
  roamrunctl look phone
  ```

  In PowerShell: `$env:ROAMRUNCTL_SIGNER = 'home-pc'`.
  In an agent, set this in the MCP server's environment.
- On first use of a remotely signed device, roamrunctl saves the signing machine and device
  identity **without the private key**, and binds subsequent uses to that association.
  Without an explicit signer, any of the user's machines that offers the name is believed;
  if two offer it, the one whose Tailscale name sorts first is chosen. Do not rely on
  auto-discovery across machines you do not trust. If the association cannot be saved,
  the device is not used.
- `roamrunctl devices remove <name>` on the **using machine** forgets its association; it
  does **not** remove the private key on the signing machine. The names must be distinct
  if two signing machines offer different pairings for the same physical device.
- The private key is not sent to the using machine by the signing protocol. **This does
  not restrict actions:** any program on the allowed using machine can open device connections
  while `sign` answers, and a connected session can see the screen, send input, or install
  an app. Stopping `sign` prevents **new** signed connections but does not terminate
  existing ones (including an already-open MCP connection). The `sign` process
  logs each successful connection signature; it is not an approval prompt for
  each tap, screenshot, or installation.
- It has **not been tested** whether a connected using machine can cause the device to
  establish an additional pairing. Therefore B must not be treated as a guarantee that
  no persistent device access can be established by software on the using machine.

## MCP tools

- `roamrunctl mcp` communicates through standard input/output. `look` returns a JPEG image
  to the agent, while the standalone `roamrunctl look` command saves a PNG; the longer
  image side is at most 1280 pixels.
- An MCP `look` authorizes **one** `tap` or `swipe` within 60 seconds. Another operation
  (`type`, `paste`, `press`, `elements`, `install`, or `launch`) invalidates that look.
  A subsequent tap or swipe needs another `look`.
- Rotation is rejected when reported orientation or image-shape checks detect a mismatch;
  it is **not guaranteed** to be detected if the device reports no orientation.
  Tap/swipe coordinates are pixels in the image returned by the last `look`.
- `type`, `paste`, and `press` act on the currently focused interface. `paste` may trigger
  the device's “Allow Paste” prompt.
- A queued call cancelled before it starts is not executed; a call already running may
  complete. MCP keeps connections open and reopens a device when its saved association
  changes or its connection fails.
- `look` and inputs do not establish a persistent video stream or a visible screen-sharing
  session. Music continued playing during the screen/input tests, but microphone and some
  other interaction scenarios have not been verified.

## Installing apps

- `install` accepts an `.ipa` or a signed `.app` directory built for the target device.
  `roamrunctl` does not compile or sign apps.
- An `.app` directory is staged on the device under its own name, and `.ipa` packages use
  a fixed staging name. **Do not run concurrent installs to one device**: they are not
  coordinated across commands.
- A subsequent `.app` installation cleans up interrupted staging where possible.
  The command prints its transfer size and timeout, then reports the result; the MCP tool
  likewise returns a result only after the operation completes.

## `pair introduce` options and results

```text
roamrunctl pair introduce --host <host> --to <device> [--offer <line>] [--as <name>] [--deadline <secs>] [--on <address>]
```

- The host runs one of `roamrunctl pair control --with <near machine>`,
  `roamrun pair control --with <near machine>` (RoamRun app running), or
  `roamrun pair xcode --with <near machine>` (Xcode Device Hub waiting).
  Either side can start its command first. The near machine can also be a Mac with RoamRun,
  running `roamrun pair introduce --host <host> --to <the device as RoamRun has it saved>`;
  a Mac introducing a host that runs `roamrunctl` was not tested at the time of these notes.
- `--offer` supplies an Xcode offer manually rather than requesting it over TCP 41830:
  `--offer "$(ssh <far-Mac> roamrun pair xcode)"`. This can help with an older RoamRun
  or a blocked 41830 port. There is no equivalent `--offer` for device control.
- `--as` requests the device name saved by the host. The host can reject that name;
  for an Xcode pairing, the printed device record can then be added manually using
  `roamrun devices add <line> --as <different-name>`. A `roamrunctl` host gives its own
  `--as` precedence.
- `--on` selects a local IPv4 address when the near machine has multiple addresses
  on the device's network. Otherwise the implementation chooses an appropriate local
  address and prints alternatives.
- For Xcode the pairing code is shown in Device Hub on the host, not generated by the
  introducer. For device control, the code is printed in the relevant terminals.
- Apple Vision Pro pairing through the Mac's Remote Devices interface follows a separate
  Mac-only path and is not a validated `roamrunctl` use case.
- For Xcode, a device-record line suitable for `roamrun devices add` is written to
  **stdout** if available; status and diagnostic messages go to **stderr**.

| Exit code | Meaning |
|---|---|
| 0 | The host reported saving the pairing, or an Xcode pairing using manual `--offer` was attempted and a device record was produced |
| 1, with a device-record line | Xcode pairing was attempted but the host did not confirm saving it; add the record manually on the host |
| 1, without a device-record line | No pairing completed, the device advertisement was unavailable, or device control was not saved; inspect stderr |
| 2 | Command-line usage error, such as an unsupported `--mac` flag (a `--deadline` over 300 without `--offer` exits 1) |

Ctrl-C, a closed terminal or a dropped SSH session attempts to withdraw the local Bonjour
advertisement before exiting (observed on macOS; on Windows for Ctrl-C and closing the console).

## If something fails

- **`roamrunctl` is not found:** on Linux, run `~/.local/bin/roamrunctl` or fix `PATH`.
  On Windows, run the executable inside its extracted directory or add that directory
  to `PATH`. An MCP client may need an absolute executable path even when your shell works.
- **Tailscale name is not found:** run `tailscale status` on the machine issuing the command.
  Use the peer's Tailscale DNS name, not the iPhone's local display name; check that all
  intended participants appear online in the expected tailnet.
- **`pair control --to` does not appear on the device:** confirm Developer Mode and Wi-Fi,
  local IPv4/direct Tailscale reachability, mDNS discovery, and incoming firewall access.
  The command prints the port and the device's address that has to be let in.
- **`pair control --with` fails before the code appears:** the remote introducer must reach
  the using machine on TCP 41830 and its dynamic pairing port. If `pair introduce` reports
  that the device's own advertisement was not seen, it may never have been paired before:
  complete a local pairing first.
- **The code was rejected:** a pairing that did not complete is not kept. Retry with a
  fresh introduction and the newly displayed code. The remote waiting command may
  remain active for another attempt, as its output indicates.
- **`roamrunctl devices` shows nothing in B:** start `roamrunctl sign phone --for <using machine>`
  on the key's machine, allow inbound TCP 41831, and set `ROAMRUNCTL_SIGNER` on the
  using machine if either is tagged or belongs to a different Tailscale user.
- **MCP cannot open an encrypted device:** `mcp` has no terminal prompt. Supply
  `ROAMRUNCTL_PASSPHRASE_FILE` or `ROAMRUNCTL_PASSPHRASE_COMMAND` in its MCP-server
  environment. The skill alone does not start the MCP server.
- **A previously working pairing stops connecting:** a device pairing may have been
  replaced, or its port may have changed. Try connecting again; if it still fails,
  remove the stale record and pair again. Do not delete the device entry solely
  because one screen request timed out.

## Building and checking

From `Rust/roamrunctl` in a repository checkout:

```sh
cargo build --locked
cargo test
# On macOS; supply this Mac's LAN address:
python3 scripts/local-check.py target/debug/roamrunctl "$(ipconfig getifaddr en0)"
```

The local check pairs no real device. The offer goes out under a test-only Bonjour service
(`_rrtest._tcp`); the fake device is announced under the real `_remotepairing._tcp` on the LAN
while it runs. It checks discovery, refusal of unexpected peers, TCP relay, device-record
creation, and advertisement cleanup, then the same for device control. Ports 41830 and 53050
on this Mac must be free.

Related Mac-side implementations include `Sources/RoamRun/Introductions.swift`,
`PairByName.swift`, and `ControlIntroductions.swift`.

## What has not been tested

The implementation was tried a few times with an **iPhone 15 Pro on iOS 27.0**,
Ubuntu 24.04 (arm64), Windows 11 on ARM, and macOS. The following were not validated
against a real device at the time these notes were written:

- iPad, Apple Vision Pro, and a device held upside down.
- A fully Mac-free initial setup, a device never prepared by Xcode, or a device never
  paired with anything.
- x86_64 machines, Linux without Avahi, and firewall configurations beyond ufw,
  Windows Firewall, and macOS Firewall.
- Signing multiple devices at once, and the `ROAMRUNCTL_SIGNER` override.
- A Mac's `roamrun pair introduce` introducing a machine running `roamrunctl`.
- Through MCP: swipe, type, paste, install, and launch (these had been tested outside MCP).
- On Windows: `pair control --with`, MCP, install, and launch.
- Tailscale userspace networking with no address available to bind.
- Xcode pairing through `pair introduce` since the `--mac` → `--host` change.

See [SECURITY.md](https://github.com/mh-mobile/RoamRun/blob/main/SECURITY.md) for the full security model and limitations.
