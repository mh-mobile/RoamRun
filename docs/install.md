# Install and requirements

<p align="center">English | <a href="install.ja.md">日本語</a></p>

The full requirements, installing and updating, building from source, what RoamRun creates on your Mac, and how to uninstall it.

## Requirements

- **A Mac with Apple silicon on macOS 13 or later**, and an administrator account. RoamRun reads
  `remotepairingd`'s log with `log stream`, and stops with a message when macOS answers that an
  administrator is required.
- **A device on iOS 17.4 or later.** RoamRun relays TCP only; it has no support for the QUIC
  tunnel of iOS 17.0–17.3. iPad, Apple Vision Pro and Apple TV were also used; "device" below
  means any of the four. Apple Watch has not been tried, as there was none at hand. Tailscale has
  no app for watchOS, so a watch can't be bridged on its own; whether one is reached through its
  iPhone's bridge is not known.
- **Xcode with `devicectl`** (Xcode 15 or later) that supports the device's iOS version; see
  [Apple's table](https://developer.apple.com/support/xcode/). `roamrun logs` and
  `roamrun run --logs` use `devicectl`'s `--console`, which came with Xcode 16.
- **Tailscale**, or another mesh VPN where you enter the device's address by hand, connected on
  both the Mac and the device.
- **The device paired with this Mac once**, with Developer Mode on: over USB, or with Xcode 27
  and iOS 27 on the same Wi-Fi (Device Hub › + › Pair Nearby Device).
- **The device on a Wi-Fi network** when the bridge starts. On cellular alone the device did not
  answer when tried. Once the bridge is Ready the device can move to cellular and keep its session,
  if Keep debugging on cellular is on (it is off by default); see
  [Working away from the Mac](away.md).

Seeing and operating the device needs iOS 27 or later. Pairing a far Mac for Xcode needs iOS 27
and Xcode 27.

## Installing and updating

With Homebrew:

```sh
brew install --cask mh-mobile/tap/roamrun
```

This installs `RoamRun.app` in `/Applications` and links the `roamrun` command. To update:
`brew upgrade --cask roamrun`.

Without Homebrew, download the dmg from
[Releases](https://github.com/mh-mobile/RoamRun/releases), drag RoamRun to Applications and open
it. The first screen offers to install the `roamrun` command; later it is under Open RoamRun ›
Settings › Command line tool › Install…. To update, quit RoamRun and replace the app. Saved
devices stay, and bridges that were running start again.

RoamRun downloads and installs no update itself, but it can tell you that a newer release is out:
Check for Updates… in the menu bar, `roamrun version --check`, or Open RoamRun › Settings › General ›
Check for updates automatically (off by default; then at most once a day). Each asks GitHub for the
newest release, and the menu then offers its release page. What is sent is in
[SECURITY.md](../SECURITY.md#what-it-touches-on-the-mac).

The app is signed with a Developer ID and notarized by Apple.

## Building from source

To build from source you need Xcode 26 or later and Rust from [rustup](https://rustup.rs) (`make`
builds device control's library with the Rust version the repository names):

```sh
git clone https://github.com/mh-mobile/RoamRun && cd RoamRun
make run            # builds RoamRun.app here and opens it; quit an installed RoamRun first
make install-cli    # links /usr/local/bin/roamrun to this build (BINDIR=$HOME/bin for another place)
```

A build without a signing certificate is signed ad hoc, and macOS treats each rebuild as another
app. If you set up device control (seeing and operating the device) with such a build, the
Keychain asks about RoamRun's key after every rebuild: answer "Always Allow". On a Mac reached
over SSH only there is no screen to answer on, and the new build cannot read the saved pairings:
delete the two Keychain items (see
[What it creates on your Mac](#what-it-creates-on-your-mac-and-uninstalling)) and set up or import
the pairing again. `make app` signs with an Apple Development certificate when the keychain holds
one.

## What it creates on your Mac, and uninstalling

RoamRun keeps its own files in these places:

| Location | Contents |
|---|---|
| `~/Library/Application Support/RoamRun/` | Saved devices, bridge status, device control's pairings (sealed), builds kept for over-the-air installs, and apps on their way to an install (`control/`: copies, and `.ipa` files uploaded to its MCP server over HTTP) |
| `~/Library/Logs/RoamRun/` | Logs of `roamrun up -d` |
| `io.github.mh-mobile.roamrun` (defaults) | Settings, and which bridges were running |
| `/usr/local/bin/roamrun` | Only if you installed the CLI from the app or with `make install-cli`. Homebrew links `/opt/homebrew/bin/roamrun` instead |
| `~/.claude/skills/roamrun/` and the like | Only if you ran `roamrun init` |
| Login Keychain: "RoamRun device control", "RoamRun device control (devices switched on)" | Only if you set up device control |

Beyond those: temporary files (while it unpacks a build, and for `devicectl`'s answers), files
that commands write where you run them or where you say (a screenshot, a look, a key), a login
item if you turned on "Open at login", and one `tailscale serve` entry while it serves builds for
`roamrun ota`.

To uninstall, in this order:

1. Stop the bridges `roamrun up` started, with `-d` or in a terminal (`roamrun down <name>`). They
   run without the app.
2. If you installed the skill, run `roamrun init --uninstall` now, while the command still exists.
3. Turn off "Open at login" if you turned it on, and quit RoamRun. Quitting gives its
   `tailscale serve` entry back.
4. With Homebrew, `brew uninstall --zap --cask roamrun` removes the app, the CLI link, settings,
   logs and saved devices. The two Keychain items stay: remove them with the `security` lines
   below. Without Homebrew, run the lines below that apply to you.

If you changed the over-the-air port, look it up before you delete anything, and use it in the
`tailscale serve` line: `defaults read io.github.mh-mobile.roamrun otaPort` shows it.

```sh
rm /usr/local/bin/roamrun                 # if you installed the CLI from the app or with make
rm -rf ~/Library/Application\ Support/RoamRun ~/Library/Logs/RoamRun
security delete-generic-password -s io.github.mh-mobile.roamrun.device-control -a pairings   # if you set up device control
security delete-generic-password -s io.github.mh-mobile.roamrun.device-control -a allowed
tailscale serve --https=41443 --set-path=/ off   # only if RoamRun was force-quit or crashed while serving builds
defaults delete io.github.mh-mobile.roamrun      # after the line above: it holds the port, if you changed it
defaults delete com.roamrun.app 2>/dev/null      # left by versions before 0.1.12
# finally delete /Applications/RoamRun.app
```
