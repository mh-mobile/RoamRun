<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="RoamRun icon">
</p>

<h1 align="center">RoamRun</h1>

<p align="center"><strong>Run your iOS apps wherever your device is.</strong></p>

<p align="center">English | <a href="README.ja.md">日本語</a></p>

A macOS menu bar app that makes Xcode's wireless debugging work over Tailscale or another mesh VPN.

Even when the iPhone is on a different Wi-Fi network from the Mac, Xcode (`devicectl`/`remoted`) keeps seeing it as a local device.

## Why

Since iOS 17, wireless debugging runs on the CoreDevice stack, and devices are discovered with Bonjour/mDNS (`_remotepairing._tcp`). mDNS is link-local multicast, so it doesn't travel over a layer-3 unicast VPN like Tailscale. On top of that, the Mac's `remotepairingd` scopes its connection to the interface it discovered the device on, so simply advertising the iPhone's tailnet IP doesn't work either.

## How it works

In short: **Xcode is told the iPhone is on the same Wi-Fi, and the traffic actually goes over Tailscale.**

```mermaid
flowchart LR
  subgraph mac["Mac at home"]
    xcode["Xcode / devicectl"] --> rpd["remotepairingd<br/>(Apple)"]
    fake["Stand-in Bonjour record<br/>(pointing at this Mac)"]
    relay["RoamRun relay<br/>(listening on en0)"]
  end
  subgraph away["Away"]
    iphone["iPhone<br/>(on some Wi-Fi)"]
  end
  rpd -. "① looks for the iPhone" .-> fake
  rpd -- "② connects to en0" --> relay
  relay == "③ over Tailscale" ==> iphone
```

1. `remotepairingd`, which runs behind Xcode, looks for iPhones on the local network with Bonjour (`_remotepairing._tcp`). RoamRun re-publishes the iPhone's Bonjour record, captured beforehand, with this Mac itself as the destination.
2. Believing the iPhone is on the same Wi-Fi, `remotepairingd` connects to the Mac itself (en0). RoamRun's relay takes the connection (and refuses any that don't come from this Mac).
3. The relay forwards the traffic to the iPhone over Tailscale. Pairing verification and encryption happen end to end between the Mac and the iPhone exactly as Apple implements them; RoamRun neither reads nor modifies the traffic.

The connection sequence:

```mermaid
sequenceDiagram
  participant X as Xcode
  participant R as remotepairingd (Mac)
  participant B as RoamRun
  participant P as iPhone
  B->>B: Publish the iPhone's Bonjour record<br/>with this Mac as the destination
  R->>B: Control channel (en0:49152)
  B->>P: Relay over Tailscale
  Note over R,P: Pair verification (Apple's, end-to-end encrypted)
  X->>R: Run / install / debug
  R->>P: Request a tunnel (over the control channel)
  P-->>R: "Listening on port N"
  Note over B: Spot N in the log and open<br/>relays for N…N+16 ahead of time
  R->>B: Tunnel connection (en0:N)
  B->>P: Relay over Tailscale
  Note over X,P: Installs, launches and debugging run inside this tunnel
```

- **The tunnel port changes every time** (it goes up by one). `remotepairingd` connects about 5 ms after announcing it, so each time RoamRun sees a port in the log (`log stream`) it opens relays for the next 16 ports in advance.
- **The very first tunnel after a bridge starts** can't be caught in time. RoamRun runs `devicectl` in the background at startup to use up that first tunnel, so your first Run already succeeds.

## Requirements

- macOS 13+
- iOS 17.4 or later on the iPhone (the generation whose CoreDevice tunnel is TCP; the QUIC/UDP tunnel of 17.0–17.3 isn't supported)
- Also verified with iPad and Apple Vision Pro, which work the same way ("iPhone" below includes them). Vision Pro has no USB and is developed for over Wi-Fi anyway, which makes it a natural fit for working away from the Mac
- Xcode (`devicectl` must be available)
- Tailscale (or any mesh VPN with a manually entered IP), connected on both the Mac and the iPhone
- The iPhone paired with this Mac once (over USB, or with Xcode 27 + iOS 27 on the same Wi-Fi via Device Hub › "+" › "Pair Nearby Device…"), with Developer Mode on
- While bridged, the iPhone must be **connected to some Wi-Fi network** (cellular alone won't do: remotepairingd only listens while the iPhone is on Wi-Fi)

## Install

### Build from source (recommended)

```sh
git clone https://github.com/mh-mobile/RoamRun && cd RoamRun
make run     # build and launch (ad-hoc signed)
```

No Xcode project needed: SwiftPM and a Makefile assemble the `.app`. An app you build yourself isn't treated as a download, so Gatekeeper won't warn. For everyday use, move `RoamRun.app` to `/Applications`.

### Prebuilt dmg (GitHub Releases)

The dmg on Releases is **ad-hoc signed only (not notarized)**. macOS blocks it on first launch; allow it in either way:

- After trying to open it once, **System Settings → Privacy & Security → "Open Anyway"**
- Or `xattr -dr com.apple.quarantine /Applications/RoamRun.app`

Build the dmg with `make dmg` (pass `SIGN_ID` / `NOTARY_PROFILE` to sign with a Developer ID and notarize; see the Makefile).

## Usage

1. With the iPhone on USB or the same Wi-Fi: menu bar icon → Open RoamRun → Add Device
2. Pick the iPhone from the list and match it to the same device on Tailscale (or enter an IP manually)
3. Start Bridge
   - While the iPhone is on the Mac's Wi-Fi, the bridge stands aside as "On this Wi‑Fi" (Xcode reaches the iPhone directly); once the iPhone moves to another network, the bridge starts by itself
4. The device stays visible in Xcode's Devices window, ready to build, install and debug

When the Mac's IP changes, the bridge restarts automatically.

## CLI

The app binary doubles as a CLI (handy over SSH or in scripts).

```sh
make install-cli              # link /usr/local/bin/roamrun (BINDIR=~/bin also works)
                              # dmg users: the app's Settings → Command line tool → Install…

roamrun devices               # saved devices (name, UDID) and their status
roamrun up <name>             # start a bridge and show progress until Ready; Ctrl-C stops and cleans up
roamrun up <name> -d          # start in the background (survives closing the terminal; log in ~/Library/Logs/RoamRun/)
roamrun status <name>         # exits 0 when Ready (for waiting in scripts)
roamrun down <name>           # stop a bridge, whether the app or another terminal's `up` runs it
roamrun doctor                # check Mac → Tailscale → iPhone step by step and say how to fix
```

`<name>` is **the name you gave the device in RoamRun**, not the iPhone's own name (case-insensitive; see `roamrun devices`, rename with ✏️ in the app's detail view; names must be unique). Add each device once in the app (Add Device). The app and the CLI never bridge the same iPhone at once: whichever starts second refuses.

## Using it from an AI agent

Claude Code, Codex, Cursor and other agents can take over building, installing on the device and debugging. Install the skill that teaches them how:

```sh
roamrun init                                  # detect installed agents and add the skill
# or
npx skills add mh-mobile/RoamRun             # via the skills CLI
```

The skill describes the steps (`roamrun up -d` → `status --wait --json` for the UDID → `xcodebuild` / `devicectl`) and what only a human can do, such as unlocking the iPhone. The CLI supports `--json` and exit codes (0 ready / 1 not ready or failed / 2 usage error).

## Working from just your iPhone, away from home

Leave the Mac at home and run the whole build-and-try loop from the iPhone in your hand.

**Prerequisite: the iPhone must be on a Wi-Fi network with internet access.** Cellular alone doesn't work (the iPhone's RemotePairing only listens while on Wi-Fi). Joining a Wi-Fi network marked "No Internet Connection" and sending traffic over cellular doesn't work either — we tested it. Use café or hotel Wi-Fi, a pocket Wi-Fi router, or tethering from another device.

**About the network path:** Tailscale normally connects the Mac and the iPhone directly (`tailscale status` shows `direct <address>` on the iPhone's line). On public Wi-Fi that blocks UDP and similar networks, traffic goes through Tailscale's relay servers (DERP; shown as `relay "tok"` etc.). That works, but it's slower. On Wi-Fi with a sign-in page, sign in first. Verified over cellular tethering (about 80 ms latency, direct): installing, launching, and debugging from Xcode with breakpoints.

There are three ways to drive the Mac from the iPhone. In each case you switch between the app under test and the control app on the same iPhone (moving an app to the background doesn't drop the connection).

| Method | On the iPhone | Best for |
|---|---|---|
| **Let an AI agent do it (recommended)** | Features for driving an agent on your home Mac from your phone (Claude Code's [Remote Control](https://code.claude.com/docs/en/remote-control.md), [Codex](https://learn.chatgpt.com/docs/remote-connections) via the ChatGPT app, and so on) | Ask "build it and run it on my iPhone", check the result in your hand, give feedback, repeat |
| Terminal over SSH | An SSH client (Blink Shell, Termius, …) + Tailscale. Keep the session in tmux and any agent works the same way | Using `roamrun` / `xcodebuild` / `devicectl` / `lldb` directly |
| Remote control of the Mac's screen | Screen Sharing / a VNC client + Tailscale | Xcode's Run and breakpoints in the GUI |

Example: with Claude Code, start `claude --remote-control` (or `claude remote-control`) on the Mac at home and connect from "Code" in the Claude app on the iPhone. You can drive it only while the Mac-side process is running. With RoamRun's skill installed in the agent (`roamrun init`), requests like "please unlock the iPhone" come up naturally as part of the flow.

Note that these remote features route conversations through, and store them on, each service's servers (check your company's policy on a work Mac).

While the iPhone is in your hand its screen stays on, so it rarely drops off because of sleep. If you leave it waiting, set Auto-Lock to a longer time.

## Source layout

Main files in `Sources/RoamRun/`:

| File | Role |
|---|---|
| `BonjourCapture.swift` | Parses the `dns-sd -Z` zone dump (PTR/SRV/TXT/A) |
| `DNSServiceProxy.swift` | Stand-in advertisement through a `dns-sd -P` child process, plus orphan cleanup |
| `Relays.swift` | TCP byte relay on NWListener/NWConnection (accepts connections from this Mac only) |
| `TunnelPortWatcher.swift` | Detects tunnel ports from `log stream` and attributes them to their device |
| `InterfaceMonitor.swift` | Notices en0 IP changes (getifaddrs + NWPathMonitor) |
| `ReachabilityProbe.swift` | TCP reachability and the RemotePairing handshake check |
| `ProxyBridge.swift` | Orchestrates the above (one instance per device) |
| `TailscaleClient.swift` | Parses `tailscale status --json` and `tailscale ping` |
| `AppCoordinator.swift` | Profiles, bridge control, presence checks |
| `StatusFile.swift` | Bridge status shared by the app and the CLI (who owns which device) |
| `CLI.swift` | The `roamrun` command (same binary as the app) |

## What it creates on your Mac, and uninstalling

RoamRun writes only to these places (it never touches system settings or other apps):

| Location | Contents |
|---|---|
| `~/Library/Application Support/RoamRun/` | Saved devices (`profiles.json`) and bridge status |
| `~/Library/Logs/RoamRun/` | Logs of `roamrun up -d` |
| `com.roamrun.app` (defaults) | Settings and which bridges were running |
| `/usr/local/bin/roamrun` | Only if you installed the CLI (never overwrites an existing file or another tool's link) |
| `~/.claude/skills/roamrun/` etc. | Only if you ran `roamrun init` (never touches other skills or links) |

The helper processes started while bridging (`dns-sd` / `log stream`) exit within a second even if RoamRun is force-quit, and the LAN advertisement goes away with them.

To remove everything:

```sh
roamrun init --uninstall                  # if you installed the skill
rm /usr/local/bin/roamrun                 # if you installed the CLI
rm -rf ~/Library/Application\ Support/RoamRun ~/Library/Logs/RoamRun
defaults delete com.roamrun.app
# finally delete RoamRun.app (turn off "Open at Login" first if you enabled it)
```

## Limitations and known issues

- **It depends on Apple's private protocols.** It assumes how CoreDevice / RemotePairing behave since iOS 17 (Bonjour `_remotepairing._tcp` → control channel → tunnel), and future iOS / macOS / Xcode versions may break it. When in trouble, run `roamrun doctor` first.
- The iPhone must be **connected to some Wi-Fi network** (tethering is fine, cellular alone is not: remotepairingd only listens while on Wi-Fi)
- After sleep or a network change, Tailscale on iOS sometimes shows "MagicSock function ReceiveIPv4 is not running" and stops passing traffic while still looking connected. Turn the VPN off and on, and keep the Tailscale app up to date
- When the iPhone sleeps, Tailscale (a VPN extension) pauses too and the iPhone becomes unreachable. While debugging, keep the iPhone unlocked with its screen on (set a longer Auto-Lock)
- remotepairingd rebuilds the control channel about every 42 seconds (its ARP check on the Mac's own IP fails). The tunnel recovers in about 0.4 seconds and the debug session carries on
- Through Tailscale's relay servers (DERP) it works, but more slowly (`roamrun doctor` shows the path)
- Away from home, **running with the debugger (⌘R) takes a while**. Attaching lldb takes hundreds of round trips, so latency and packet loss add up directly. The number of round trips grows with the number of frameworks loaded, and install time is roughly proportional to the app's size (measured with a ~600 KB app over tethering at about 25–60 ms latency: about 1 minute with the debugger, about 4 seconds without; transfer rate 0.4–0.9 MB/s). When you don't need breakpoints, turn off "Debug executable" under Edit Scheme › Run › Info; when you do, turning off "Queue Debugging" (Options) and "Main Thread Checker" / "Thread Performance Checker" (Diagnostics) speeds it up
- After the iPhone restarts, re-staging the DDI may need one USB connection
- If the TXT record's authTag/identifier changes, add the iPhone again on the same Wi-Fi
- While bridging, RoamRun keeps advertising the iPhone's Bonjour identifiers (identifier / authTag) on **every local network this Mac is on** (Wi-Fi, Ethernet — every interface with mDNS). Unlike the iPhone's own advertisement these values are fixed, so someone on the same network could track the device's presence (not an issue in the usual setup with the Mac at home). The relay immediately drops any connection that doesn't come from this Mac. The iPhone's side is encrypted by Tailscale, so whichever Wi-Fi it's on doesn't matter
- When you're not developing, turning off the iPhone's Developer Mode or removing pairings you don't need is safer (Apple's recommendation)
- Other members of your tailnet can reach the iPhone's RemotePairing port too (they can connect, but pair verification rejects them). On a shared tailnet, use Tailscale Grants / ACLs so only your Mac can reach the iPhone
- If another Mac is on the same network, this iPhone may briefly show up in that Mac's Xcode as well (the relay refuses its connections, so it can't do anything with it)

## Credits

This implementation builds on the following public write-up:

- Kevin Paterson, ["How to remotely iterate & deploy your sideloaded iOS-apps over tailnet"](https://dev.to/kvnpt/how-to-remotely-iterate-deploy-your-sideloaded-ios-apps-over-tailnet-jak) (DEV Community) — demonstrates an equivalent setup with `dns-sd -P` + `socat`

## Related projects

Projects tackling the same problem (reaching an iPhone on another network from Xcode):

- [Viaaaron/iphone-tailnet-bridge](https://github.com/Viaaaron/iphone-tailnet-bridge) — Bonjour plus a socat relay, as shell scripts
- [ahmadtawakol/iphone-tailnet-bridge](https://github.com/ahmadtawakol/iphone-tailnet-bridge) — a fork of the above that adds a native macOS app and Go tools
- [CodeEagle/remote-ios-deploy-skill](https://github.com/CodeEagle/remote-ios-deploy-skill) — the same approach (Bonjour proxy + TCP/UDP relay) as an agent skill (SKILL.md)
- [lyo-eos/ios-ota](https://github.com/lyo-eos/ios-ota) — installs signed apps over Tailscale (and keeps going when switching from Wi-Fi to 5G). Focused on installing rather than Xcode's Run or the debugger

## License

[MIT](LICENSE)
