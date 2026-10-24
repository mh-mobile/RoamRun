# roamrunctl: reference

<p align="center">English | <a href="roamrunctl-reference.ja.md">日本語</a></p>

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
  `roamrunctl-windows-x86_64.zip`, `roamrunctl-windows-aarch64.zip`,
  `roamrunctl-macos-aarch64.tar.gz`, and `roamrunctl-macos-x86_64.tar.gz`. They include the binary,
  README, `SKILL.md`, and license notices. `roamrunctl-SHA256SUMS` contains their checksums.
- The Linux release binaries are static. If `roamrunctl` is not found after installing to
  `~/.local/bin`, add that directory to your `PATH` or run `~/.local/bin/roamrunctl` directly.
- The Windows archive extracts to a subdirectory. Run, for example,
  `.\roamrunctl-windows-x86_64\roamrunctl.exe`, or add that directory to `PATH`.
  The binaries are not code-signed. In one run on Windows 11, Windows Firewall asked whether to
  let it in the first time it advertised, and was allowed for private and public networks; in a
  PowerShell run as administrator it asked nothing.
- The macOS binaries are not signed with a Developer ID or notarized. Downloaded with `curl`,
  they carry no `com.apple.quarantine` attribute. Carrying it, on an Apple silicon Mac with
  macOS 27, they were killed as soon as they started, until `xattr -d com.apple.quarantine`
  removed it (the README's Install has the run).
- `cargo install --locked --git ...` requires Rust 1.89 or later and a C compiler. This is a
  source build, not the release's static Linux build. `roamrunctl` is not published on
  crates.io; the Homebrew formula is in `mh-mobile/tap`, not Homebrew core.
- The reported version is RoamRun's version. Match versions between pairing participants.
  Before 0.7.0, `pair introduce` used `--mac` instead of `--host`, and an older release names
  `--mac` in the commands it tells you to run.

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
- For `pair introduce`, the device must also be allowed into the near machine on its printed
  local TCP port. If an Xcode offer is supplied with `--offer`, asking the host on 41830 is
  not needed; the host's pairing port must still be reachable.
- In B, allow incoming TCP 41831 **from the named using machine** to the key's machine.
  Signing does not proxy screenshots or input; device traffic travels directly between
  the using machine and the device.
- macOS, with its firewall on, asked whether to let `roamrunctl` take incoming connections (seen
  once, with a Linux machine standing in for the device).
- roamrunctl chooses its address on the Wi-Fi by looking at its interfaces' addresses; the routing
  table only chooses between several of them on that network. On one Windows machine, "Use Tailscale subnets" had routed its own LAN
  through Tailscale, and pairing went through all the same.
- `sign` and `pair control --with` listen on this machine's Tailscale address. With Tailscale in
  userspace-networking mode alone, neither was tried.

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
  the size and time limit, then waits without progress output; the MCP tool answers once the
  install has begun (see [Installing apps](#installing-apps)). In tests on the device's Wi-Fi,
  3 MB took about 25 seconds and 37 MB about two and a half minutes.
- `tailscale status`: ten seconds to answer, wherever roamrunctl asks it. `sign` and
  `pair control --with` ask for each connection, and turn the connection away when it doesn't
  answer; `pair control --with` asks again for the device the near machine names, and ends
  there when it doesn't answer.

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
- A configured source gives one passphrase, used for every encrypted device opened or saved
  under that environment: the command source is run the same way whichever device it is for. So
  devices opened under one environment share a passphrase; one `mcp` server uses one for every
  device it opens. To keep a key off the machine an agent runs on, use B.

| Command | Passphrase handling |
|---|---|
| `pair control --passphrase`, `key import --passphrase` | prompts twice when creating a new encrypted record, or reads a configured source |
| `look`, `install`, `launch` | prompts when opening an encrypted record, or reads a configured source |
| `mcp` | cannot prompt; needs a configured source the first time it opens an encrypted record, and keeps what that opened while the file is the same |
| `mcp --http` | prompts at a terminal, or reads a configured source, as it starts, for each encrypted device it offers; keeps what that opened while the file is the same |
| `sign` | reads or prompts when starting for each encrypted record it serves |
| `devices`, `devices remove` | no passphrase needed |

- For an MCP client, configure the passphrase source in the MCP server's environment, beside the
  command the README shows.
- An example for `ROAMRUNCTL_PASSPHRASE_COMMAND` on macOS, **if a matching Keychain item
  already exists**, is `security find-generic-password -a "$USER" -s roamrunctl -w`.
- Re-pairing a device under the same host identity replaces the earlier pairing on the device.
  An old record then fails to connect; remove it with `roamrunctl devices remove <name>`.
  Also remove the machine's pairing entry in the device's Developer Mode list when withdrawing it.
- Connections try the saved port first, then the rest of 49152–49167. A device restarted twice,
  and taken off the network and back, announced 49152 each time; if a device cannot be
  reached on any of them, pair again.
- A Mac with RoamRun can create a key for import:
  `roamrun key create <device> device.key` on that Mac, then
  `roamrunctl key import device.key` on the using machine. Import verifies the device
  over Tailscale, stores the record, and removes the import file on success.
- `key import` also takes an unencrypted record roamrunctl saved on another machine (a
  `devices/<name>.json` file), under its own name unless `--as` gives another; a record whose
  key another machine keeps (B) is refused, and so is one kept under a passphrase (a `.age`
  file). A file in this machine's own devices folder isn't
  removed (imported `--as` another name, it is then saved under both). A byte order mark
  before the JSON is passed over. With `--passphrase`, the passphrase is asked for before the
  device is tried. With `-` in place of the file it reads standard
  input, and removes nothing: `printf '%s' "$KEY" | roamrunctl key import - --as ci` takes a
  CI's secret without writing it to a file. Line breaks outside the JSON's strings don't
  matter, so a secret whose lines were run together, or turned into spaces, is read the same.
  With `--passphrase` the passphrase then has to come from one of the sources above, as
  standard input isn't a terminal.

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

- `roamrunctl mcp` communicates through standard input/output, or over HTTP with `--http`
  (next section). `look` returns a JPEG image
  to the agent, while the standalone `roamrunctl look` command saves a PNG; the longer
  image side is at most 1280 pixels.
- An MCP `look` answers with an id, which `tap`, `swipe`, `type` and `paste` give
  (`"look": 12`). It stands for 60 seconds, and only while it is the device's latest:
  another look since — by any client, one that failed too — or `press`, `elements`,
  `install`, or `launch` ends it, and so does a call that fails in a way that may have
  reached the device, or another device saved under the name. It authorizes **one** `tap` or
  `swipe`: after a tap, swipe, `type`, or `paste` by it, a tap or swipe needs another `look`,
  while `type` and `paste` still go by it (look → tap a field → type needs one look). Ids
  start from a random number at each start, so one kept from an earlier run isn't taken for
  a later look.
- Rotation is rejected when reported orientation or image-shape checks detect a mismatch;
  it is **not guaranteed** to be detected if the device reports no orientation.
  Tap/swipe coordinates are pixels in the image returned by the last `look`.
- `type`, `paste`, and `press` act on the currently focused interface. `press` isn't held to a
  look. `paste` makes the device ask “Allow Paste” each time. `type` and `paste`, as a `look`
  does, wait until a second after the last input: keys sent at once after a tap on a field
  were seen lost, or put before the cursor.
- Each tool carries MCP's `readOnlyHint` and `destructiveHint`. `devices`, `look` and
  `install_status` are marked read-only. `elements` is neither: the screen may scroll. The rest are marked destructive: what
  is pressed or typed acts as it would by hand (a tap can delete or send, a typed newline is
  Return), `press lock` can't be undone from here, `launch` ends a running app first, and
  `install` replaces one. What a client does with the hints is the client's; none was checked.
- A queued call cancelled before it starts is not executed; a call already running may
  complete. MCP keeps connections open and reopens a device when its saved association
  changes or its connection fails.
- `look` and inputs do not establish a persistent video stream or a visible screen-sharing
  session. Music continued playing during the screen/input tests, but microphone and some
  other interaction scenarios have not been verified.

## MCP over HTTP

`roamrunctl mcp --http <port> --allow <who> [--allow <who>…] [--token-file <file>] [--allow-install [--max-upload <MiB>]] <device>…`,
until Ctrl-C:

- It listens on this machine's Tailscale IPv4 address only. It doesn't start without
  Tailscale, without `--allow`, without a device, or as root (on Linux and macOS, by its
  effective user; not checked on Windows); a device only offered by a machine that
  signs, and not used here yet, isn't taken, nor one whose saved file can't be read (a
  passphrase not given), nor one device under two names.
- Who may call: `--allow tag:<name>` matches a tagged caller by its tags, and `--allow <login>`
  an untagged caller by its user's login, as `tailscale whois` gives them for the caller's
  address, asked at each request (5 s at most; where it doesn't say who the caller is, the
  request is answered 503, to be tried again). A login never matches
  a tagged machine. A machine shared in from another tailnet is refused, and so is this
  machine itself unless the token came.
- `--token-file`: each request also brings `Authorization: Bearer <token>`. The file has to be
  its owner's alone (not checked on Windows), the token 32 characters or more on one line.
- The transport is MCP's Streamable HTTP as of 2025-11-25: one JSON-RPC message a
  `POST /mcp`, answered in JSON; a notification or a response gets 202; `GET` and `DELETE`
  get 405. A session is given only to take a call back in (below), and `initialize` isn't
  needed before a call. `MCP-Protocol-Version`, when sent, is one of 2024-11-05, 2025-03-26,
  2025-06-18, 2025-11-25, else 400.
- Answered before anything else: `/.well-known/*` and `/register` with 404 (no OAuth here),
  any `Origin` with 403, a `Host` other than this machine's address or its Tailscale names
  (with the port, which may be left out where it is 80) with 400; then a missing or wrong token with 401 (`WWW-Authenticate:
  Bearer`), a caller `tailscale whois` didn't say who it is with 503, a caller not allowed with 403.
- One request a connection (`Connection: close`). The head has to be in within 10 s of
  connecting, the body within 30 s more, however it trickles in. A body is read as chunked
  when it says so (also when a length comes with it), else by its length; 1 MB at most.
  32 connections at once, 17 from one address; more are answered 503.
- Tool calls on one device take turns, as over stdio; each device has its own turn, so a call
  on one doesn't wait for another's. One whose caller has closed its connection (or only its
  own side of it), or whose connection broke, when its turn comes isn't made. An `initialize`
  is answered with an `Mcp-Session-Id`, which a client sends with what follows (the MCP SDKs
  do): a `notifications/cancelled` sent with it takes back the call of that id in that
  session, before its turn, also where it came in before the call (it is kept a minute for
  it, 256 at most at once). Without a session it does nothing — the request id is the
  client's choosing, and another client's call could carry the same — and closing the
  connection takes the call back. One that waited 20 s for its turn is answered "not begun"
  and isn't made. Other messages are answered at once. (MCP 2025-11-25 asks that a closed
  connection not be taken as a call taken back; a call for a caller who is gone isn't made
  here all the same.)
- Several agents can use one server at once: a tap, swipe, type or paste names the look it is
  of, and is refused after another look of that device, whoever took it.
- Only the devices named are listed by `devices` or used, and only while each is saved here
  as it was when this began: removed, or saved anew under its name, it isn't used until this
  is run again. `install` and `install_status` are offered only with `--allow-install`, and
  `install` then takes an upload, never a path (next section).
- One line a request on standard error: the time (UTC), the caller's address and who
  Tailscale says it is, the method and tool, the outcome, how long it took — with control
  characters shown as `?`. Never the token, a body, text typed or pasted, captions or
  images, or what was uploaded.

### Uploads (`--allow-install`)

- `PUT /upload` takes an `.ipa` as the body, with `Content-Length` or chunked
  (`curl -T app.ipa`), and answers `{"upload": "<id>", "size": <bytes>, "sha256": "<hex>"}`.
  `install` then names it: `{"device": …, "upload": "<id>", "sha256": "<hex>"}`. Without
  `--allow-install`, `/upload` is 404 and neither `install` nor `install_status` is listed.
- Once the caller is let in (as for `/mcp`): a method other than `PUT` is 405, no length and
  not chunked 411, a length over the most 413 (before `100 Continue` is sent), and one while
  another is coming in 409. `--max-upload <MiB>` sets the most: 1024 by default, 1 to 4096.
  The body may take 30 seconds plus 2 seconds a MiB of its length (of the most, when chunked),
  and nothing may come for 60 seconds at most: then it is refused with 408 and the slot is free.
- One upload is kept: when another begins to come in, from whichever caller, the one kept is
  dropped. It is kept in a folder made
  for this run in the system's temporary folder: mode 0700, the file 0600 (on Windows, the
  user's own temporary folder, not restricted further). One cut short is dropped at once, one
  not used for 30 minutes is dropped (looked for every minute), and the folder is removed at
  Ctrl-C, SIGTERM or SIGHUP (on Windows, Ctrl-C, Ctrl-Break or the console closing). One ended
  otherwise (killed) leaves its folder.
- Only the caller that sent an upload — by its node's lasting id, as `tailscale whois` gives
  it — can install it, and only by the sha256 it was answered (in either case). Another caller's
  id, or another sha256, is refused before the call waits its turn, and the upload stays.
- An upload serves one install. What it holds is checked first (below); a device that can't
  be opened then leaves it for another try; once the device is open, the install takes it,
  and its file is removed when the install ends.

### `install --relay` and `launch --relay`

`roamrunctl install <device> <app.ipa> --relay <address>:<port> [--token-file <file>] [--timeout <s>] [--launch]`
and `roamrunctl launch <device> <bundle id> --relay <address>:<port> [--token-file <file>]`, on
the calling machine, use such a server instead of a device of their own. The relay is the
machine that holds the device's key and runs `mcp --http`, anywhere on the tailnet: it reaches
the device over Tailscale, as any using machine does, and needs no place beside it.

- `<device>` is the device's name on the relay, as its `mcp --http` names it. `--relay` takes
  the address and port, or the address the server printed (`http://<address>:<port>/mcp`);
  `ROAMRUNCTL_RELAY` gives it too (set to nothing, it gives none). With either, `install` and
  `launch` don't use a device saved on the calling machine. A name is looked up, and each IPv4
  address it gives is tried in turn (the server listens on IPv4 alone). The connection is made
  directly over TCP, or through the proxy `ROAMRUNCTL_PROXY` names (next section): `http_proxy`
  and the like aren't used.
- The token: `--token-file` (the owner's alone, 32 characters or more on one line, as the
  server's), else `ROAMRUNCTL_TOKEN`; with neither, none is sent.
- `install` takes an `.ipa`, not an `.app` folder, and checks it as `install` does (next
  section). Then, from one process (so one Tailscale node, which the relay requires): `PUT
  /upload` with `Expect: 100-continue` (a refusal, such as a missing token, comes before the
  `.ipa` is sent); the sha256 the relay answered is compared with the file's, and a different
  one stops it before anything is installed; `install` names the upload; `install_status` is
  asked every 5 seconds, of the install `install` answered (by its id), until it says the app
  is in, or why not. It prints what `install_status` said. A relay whose `install` gives no id
  (before 0.9.0) is refused once the install is begun. A server that doesn't answer the
  `Expect` within 10 seconds is sent the body all the same (a 100 Continue that comes after is
  passed over); one that refuses while the body
  goes is read for its answer. `--launch` then launches the app by the bundle identifier in the
  `.ipa`, once what `install_status` said is printed.
- A request the relay answers 503 is sent again, 5 times at most, 3 seconds apart. Any other
  refusal stops the command with the status and what the relay said (401: the token; 403: its
  `--allow`; 404 on `/upload`: no `--allow-install`). Each request is one connection.
  `launch --relay` waits 120 seconds at most for everything (503s tried again included);
  `install --relay` waits until its deadline (`--timeout`, below), each read or write 120
  seconds at most. Either says "no answer within 120 s" when it gives up so.
- `--timeout <s>` is the most the whole command waits for the app to be in, the upload and
  each request among it: nothing is sent once it has passed, no answer is waited for past it
  (a relay that answers a byte at a time, stops halfway, or sends 1xx on and on, included),
  and an upload going on then stops. By default it is what the relay gives the install (five
  minutes plus 15 seconds a megabyte), 2 seconds a MB for the upload, and a minute more. When
  it passes the command fails; an install already begun goes on at the relay, and
  `install_status` there says how it ends.

## Through an HTTP proxy (`ROAMRUNCTL_PROXY`)

On a machine that reaches the tailnet only through an HTTP proxy, `ROAMRUNCTL_PROXY=http://<host>:<port>`
makes roamrunctl connect through that proxy's `CONNECT`: to the device (the check that it
answers, the pairing port and the tunnel port, so `look`, `install`, `launch`, `mcp` and the
rest), and to a relay (`--relay`).

- Only `http://<host>:<port>` is taken: no user and password, no path, not `https://`, not SOCKS.
  Any other value stops roamrunctl before it does anything; set to nothing, it names none.
  `HTTPS_PROXY`, `http_proxy`, `ALL_PROXY` and the like are never read.
- Not through it: pairing (`pair control`, `pair introduce`), and the connection to a machine
  that signs for a device (B).
- Tailscale running in userspace gives such a proxy into the tailnet:
  `tailscaled --tun=userspace-networking --outbound-http-proxy-listen=127.0.0.1:1056`, then
  `ROAMRUNCTL_PROXY=http://127.0.0.1:1056`.
- A build of this change ran so on Xcode Cloud on 2026-10-24, against an iPhone 15 Pro:
  `install --relay … --launch`, and, with no relay, `key import -`, `install --launch` and `look`
  ([docs/xcode-cloud.md](xcode-cloud.md)). From a Mac, through a test proxy that logged each
  `CONNECT`: `look`, `install --launch` and `install --relay … --launch`.

## Installing apps

- `install` accepts an `.ipa` or a signed `.app` directory built for the target device.
  `roamrunctl` does not compile or sign apps.
- An `.ipa` is checked before anything of it is sent, by `roamrunctl install` (before the
  device is opened) and by MCP alike: `Payload` holds one `<name>.app` and nothing else but
  hidden files such as `.DS_Store` (a `.bundle` is refused; a name ending in `.app` counts as
  an app, hidden or not), and it unpacks to 4 GiB at most, by what the archive says. The
  app's bundle identifier is found as the install finds it: the files whose names have three
  parts and end in `Info.plist` are read in the archive's order, and the first that gives a
  bundle identifier must be `Payload/<name>.app/Info.plist`. One before it without an
  identifier, such as Firebase's `GoogleService-Info.plist` in the app, is passed over. Each
  one read must be a plist of 1 MiB at most. An `.app` directory isn't checked.
- An `.ipa` is read whole into memory to be sent: an upload as large as `--max-upload` allows
  takes that much memory on this machine while it is installed.
- An `.app` directory is staged on the device under its own name, and `.ipa` packages use
  a fixed staging name. **Do not run concurrent installs to one device** from separate
  commands: they are not coordinated. Within one `mcp` server, a device's second install is
  refused while its first runs.
- Before it installs, it ends the app's running processes, found by the bundle identifier (an
  `.ipa`'s, or an `.app` folder's Info.plist). iOS ends them itself, but on iOS 27.0 it didn't end
  one in front while the device was on a wireless charger (cable charging wasn't tried): the
  install waited until the app wasn't in front (122 s once, and 315 s timeouts). Where they can't
  be found or ended, the install goes on as before. They are killed (SIGKILL), extensions too,
  before the upload begins: the app can't save its state, is gone for the whole upload, and stays
  ended if the install then fails, which 0.8.1 didn't do.
- A subsequent `.app` installation cleans up interrupted staging where possible.
  The command prints its transfer size and timeout, then reports the result.
- `install --launch` then launches the app, in the same connection to the device, by the
  bundle identifier in the `.ipa`, or in the `.app` folder's `Info.plist` (without one there,
  nothing is installed). That it was installed is printed before the launch is tried.
- The MCP `install` answers once the install has begun, with the bundle identifier (or the
  `.app` path), the size, the install's id (`(install 3f2a9c0e1b7d4a65)`, random) and the time
  limit; `install_status` says how the device's latest install goes: still going and for how
  long, installed, or why it failed. Given `"install": "<id>"`, it answers of that install
  alone: another caller's install of the same app isn't taken for one's own. One followed by
  others on the device is still answered as it ended, each device's latest 16 ended ones kept; an older
  one, or one from before the server was started again, is an error that says how it ended
  isn't known. Until it ends, every other call on that
  device is answered that it is installing, and the device's latest look is ended. Over stdio,
  an install still going when standard input closes runs out before the server ends; over
  HTTP, Ctrl-C ends it where it is.

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
  `--offer "$(ssh <far-Mac> roamrun pair xcode)"`. It is for when port 41830
  on the host is closed. There is no equivalent `--offer` for device control.
- `--as` requests the device name saved by the host. The host can reject that name;
  for an Xcode pairing, the printed device record can then be added manually using
  `roamrun devices add <line> --as <different-name>`. A `roamrunctl` host gives its own
  `--as` precedence.
- `--on` selects a local IPv4 address when the near machine has multiple addresses
  on the device's network. Otherwise the implementation chooses an appropriate local
  address and prints alternatives.
- For Xcode the pairing code is shown in Device Hub on the host, not generated by the
  introducer. For device control, the code is printed in the relevant terminals.
- An Apple Vision Pro with Remote Devices open (on the device: Settings > General > Remote
  Devices) waits to be picked by a Mac. That pairing is made between Macs with RoamRun, and was
  run that way; a Mac's `roamrun pair introduce` refuses a `--host` that is not a Mac for such a
  device. `roamrunctl` has not been run with a Vision Pro.
- For Xcode, a device-record line suitable for `roamrun devices add` is written to
  **stdout** if available; status and diagnostic messages go to **stderr**.

| Exit code | Meaning |
|---|---|
| 0 | The host reported saving the pairing. With `--offer`: an Xcode pairing was attempted and the device record printed; the host was not told, so the record still has to be added there with `roamrun devices add` |
| 1, with a device-record line | Xcode pairing was attempted but the host did not confirm saving it; add the record manually on the host |
| 1, without a device-record line | No pairing completed, the device advertisement was unavailable, or device control was not saved; inspect stderr |
| 2 | Command-line usage error, such as an unsupported `--mac` flag (a `--deadline` over 300 without `--offer` exits 1) |

Ctrl-C, a closed terminal or a dropped SSH session attempts to withdraw the local Bonjour
advertisement before exiting (observed on macOS; on Windows for Ctrl-C and closing the console).

## If something fails

- **`roamrunctl` is not found:** on Linux, run `~/.local/bin/roamrunctl` or fix `PATH`.
  On Windows, run the executable inside its extracted directory or add that directory
  to `PATH`.
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
- **A previously working pairing stops connecting:** pairing this machine with the device again
  replaces its earlier pairing there, and the device then refuses the old record. Remove the
  old record with `roamrunctl devices remove <name>` and pair again.

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
creation, and advertisement cleanup; then, for device control, the exchange with a fake host,
its offer advertised, the relay, the code shown, and exit 0. Ports 41830 and 53050
on this Mac must be free.

Related Mac-side implementations include `IntroductionLines.swift`, `Introductions.swift`,
`PairByName.swift`, and `ControlIntroductions.swift` in `Sources/RoamRun/Pairing/`.

## What has not been tested

The implementation was tried a few times with an **iPhone 15 Pro on iOS 27.0**,
Ubuntu 24.04 (arm64), Windows 11 on ARM, and macOS. The following were not validated
against a real device at the time these notes were written:

- iPad, a device held upside down, and `roamrunctl` with an Apple Vision Pro (RoamRun on Macs
  was run with one).
- A fully Mac-free initial setup, a device never prepared by Xcode, or a device never
  paired with anything.
- x86_64 machines, Linux without Avahi, and firewall tools other than ufw.
- Signing multiple devices at once, and the `ROAMRUNCTL_SIGNER` override.
- A Mac's `roamrun pair introduce` introducing a machine running `roamrunctl`.
- Through MCP: swipe and a paste that goes through (these had been tested outside MCP).
  Installing and launching through MCP on Linux or Windows.
- On Windows: `pair control --with`, MCP, install, and launch.
- `mcp --http` from another machine (by a tag or a login), from a cloud, or on Linux or
  Windows. On macOS it was checked from the machine itself, with the token:
  `scripts/mcp-http-check.py`; and on an iPhone, look, tap, type, press and `elements`, a tap
  refused after another caller's look, types and pastes refused by an older look, and queued
  calls taken back by closing their connection and by `notifications/cancelled` in a session.
  Look, tap, type, `elements`, and calls taken back in a session (the cancel coming before the
  call, or after it) were run again in a later form; the rest were runs of earlier forms of it.
  Uploads were run on macOS from the machine itself with the token, against a device saved
  with an address nothing is at: an upload answered with its size and the sha256 `shasum`
  gives, one over `--max-upload` refused with the one kept staying, `install` of it refused as
  that device can't be opened with the upload staying, and the folder made 0700 and removed at
  Ctrl-C (exit 130); and without the token, `/upload` refused as this machine itself. Then on
  the iPhone 15 Pro, an 8.5 MB `.ipa` (one app, its check passed): over stdio from its path,
  `install` answered in 1 s, a look meanwhile was answered that it was installing, and
  `install_status` said it was installed after 15 s; over HTTP, the upload took 0.6 s with
  the sha256 `shasum` gives, `install` answered at once, a look and a second install by the
  same upload were refused meanwhile, it was installed after 10 s, the upload's file was gone
  after, and the folder was removed at Ctrl-C. `launch` of it over stdio answered with its pid
  in 1.3 s.
- `install --relay` and `launch --relay` from another machine, from a cloud, or on Linux or
  Windows; `install --launch` without a relay; `--timeout` running out. They were run on macOS
  from the machine itself,
  against its own `mcp --http` with the token, on the iPhone 15 Pro (iOS 27.0, its app not in
  front): without the token the upload was refused (401) before the `.ipa` was sent; with it,
  `install --relay --launch` of a 1 MB `.ipa` took 6.7 s (the install 5 s) and launched it,
  and `launch --relay` (the relay from `ROAMRUNCTL_RELAY`) answered in 0.6 s — that in a form
  before `install` answered an id. With the id, `install --relay --launch` took 8.9 s: `install`
  answered `(install <id>)`, `install_status` asked by it said the app was in after 5 s, and it
  launched; `install_status` with another id was then an error, and without one answered of
  that install.
- Tailscale userspace networking with no address available to bind.
- Xcode pairing through `pair introduce` since the `--mac` → `--host` change.

See [SECURITY.md](https://github.com/mh-mobile/RoamRun/blob/main/SECURITY.md) for the full security model and limitations.
