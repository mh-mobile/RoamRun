# Installing over the air: details

<p align="center">English | <a href="ota.ja.md">日本語</a></p>

`roamrun ota` publishes a build on a page in your tailnet, and a device installs it by itself. The
[README](../README.md#installing-without-the-bridge-over-the-air) says when to use it and how.
This document has the rest.

## What happens

```sh
roamrun ota build/MyApp.ipa            # checks it against every device RoamRun knows
roamrun ota iPhone build/MyApp.ipa     # or name one, to check just that device
```

RoamRun stores the build, and while the app runs it publishes a page through `tailscale serve`.
The command prints the page's address and which of your devices the build covers. When it runs in
a terminal it also draws the address as a QR code. Open the address on the device and tap Install.

- The page can take half a minute to appear after a first build is stored: RoamRun looks when it
  starts, and then every 30 seconds.
- `roamrun doctor` prints the address again while a build is stored and Tailscale gives this Mac
  a name.
- The page lists the last 5 builds of each app, newest first, so you can go back a version.
- Rebuilds usually keep the same version number, so builds stack up under it and the time tells
  them apart. Publishing the very same .ipa again does not add a row: it moves back to the top.
- `--replace` drops the builds already listed under the same version and build number. It is
  ignored when the new build names none of your devices, so that it cannot remove a build that
  does install.

## What it needs

**An .ipa signed for Release Testing (Ad Hoc) or Enterprise.** Both take a paid Apple Developer
account. Xcode makes one with Product › Archive › Distribute App › Release Testing, and
`xcodebuild -exportArchive` with `"method": "release-testing"` does the same from a script.
`roamrun run` cannot make one: it signs for Development.

`roamrun ota` refuses, before storing anything:

- a Development build, an App Store or TestFlight build, and an unsigned one;
- a build whose provisioning profile has expired (one that expires after it was stored is marked
  EXPIRED on the page);
- a bundle identifier with characters other than ASCII letters, digits, `.`, `-` and `_`, or one
  that starts with `.`.

An Ad Hoc build installs only on the devices its provisioning profile names. RoamRun says which
of your devices those are. It knows the UDID of every device it has bridged, so bridge a device
once (`roamrun up <name> -d`) to let it learn the UDID. A build that names none of your devices is
still stored, with a warning: the profile may name a device this Mac has never seen. An Enterprise
build needs none of this.

**HTTPS in your tailnet**: MagicDNS and HTTPS certificates turned on.

**RoamRun running**, since the app serves the page.

## From a CI job

A job can put its build on the page with no one at the Mac. On the Mac, beside the RoamRun app,
start an **OTA server**: `roamrun mcp --http` with `--allow-ota`. It has one tool, `ota`, and
operates no device: on it, a job that holds its token can publish to the page, and do nothing else. It
gets a token of its own, not a relay's, stored as a secret (here `OTA_TOKEN`) that the job reads
into `$TOKEN`:

```sh
(umask 077 && mkdir -p ~/.config/roamrun && openssl rand -hex 32 > ~/.config/roamrun/ota-token)
gh secret set OTA_TOKEN --repo <owner>/<repo> < ~/.config/roamrun/ota-token
roamrun mcp --http 9091 --allow tag:ci --token-file ~/.config/roamrun/ota-token --allow-ota
```

`--allow-ota` and `--allow-install` aren't given to one server; a server for installs can run
beside it on another port. Give that one a token of its own: without one, a job its `--allow` lets
in can install apps and operate the devices there. `$MAC` below is the Mac's Tailscale address, which the server prints
as it starts.

The job publishes with roamrunctl (0.12.0 or later; its archives are on the
[releases](https://github.com/mh-mobile/RoamRun/releases) page):

```sh
ROAMRUNCTL_TOKEN="$TOKEN" roamrunctl ota MyApp.ipa --server "$MAC:9091"
```

It asks the server what it is before it sends anything (a relay, or a server without `ota`, is
refused as such), uploads the .ipa, checks the sha256 the server answers, and calls `ota`. The
server checks the build as `roamrun ota` does; the command prints what it said (what was stored,
which of your devices it installs on, the page's address) and fails on a refused build.
`--replace` does what it does for `roamrun ota`. Details:
[the roamrunctl reference](roamrunctl-reference.md#ota---server).

- **Stored is not yet on the page.** A step that succeeds means the build was stored. The page
  shows it within about 30 seconds while the RoamRun app runs; the answer says when the page isn't
  up, and why.
- **What has to stay up at the Mac:** the RoamRun app, and the server (`roamrun mcp --http` runs
  until Ctrl-C; running it as a service wasn't tried). The tailnet's access rules have to let the
  job's tag reach the server's port.
- **One publishing job at a time.** The server keeps one upload: another job's upload, starting
  before this one's `ota`, replaces it. `roamrunctl ota` waits while another upload comes in and
  sends its own again once; jobs that overlap more than that can fail, and a long wait may need
  a larger `--timeout`.

Run on 2026-11-02 from this Mac itself, with the token: an Ad Hoc build of a test app was uploaded
and stored, and the answer named the two saved devices its profile lists. `tools/list` had `ota`
alone and `look` was refused at once; `--allow-ota` with `--allow-install` was refused. Earlier the
same day, a second `ota` with a used upload was refused. Then from another machine of the tailnet
(a macOS VM, let in by the login), with this Mac running an OTA server on 9091 and a server for
installs on 9090 side by side: `roamrunctl ota` stored a 25 MB Ad Hoc build (its upload took
22 s), again through a local CONNECT proxy (`ROAMRUNCTL_PROXY`, with `--replace`), and the page
fetched from that machine listed the build; pointed at 9090, it was refused as having no `ota`
before anything was sent. On 2026-11-03 (UTC), from GitHub Actions (`ubuntu-24.04`, joined with a
signed auth key as `tag:ci`) through roamrun-action's `ota-server` and the roamrunctl 0.12.0 it
downloads: a 1 MB Ad Hoc build, first taken off the page, was stored, and the page fetched from the
runner listed it. The same day, the Bitrise Step's `ota_server` with the Bitrise CLI on this Mac
(the Step's own Tailscale in userspace) did the same. Not yet on bitrise.io, nor from Windows.

## The port, and Funnel

RoamRun serves on a port of its own, 41443 by default, and gives it back when it quits. It does
not use your tailnet's port 443, where anything else you serve lives. To change
it:

```bash
defaults write io.github.mh-mobile.roamrun otaPort -int 41444
```

Ports 443, 8443 and 10000 are refused and fall back to 41443, as are ports below 1024 and above
65535. Those three are the ports Tailscale Funnel can publish to the internet, as Tailscale has it
now; a port outside them cannot be put on the internet that way. RoamRun never turns Funnel on,
and `roamrun doctor` reports it as a failure if it finds Funnel on for that port.

If RoamRun is force-quit or crashes, the `tailscale serve` entry stays. Opening RoamRun again
gives it back: RoamRun recognises a leftover of its own on the port configured now and on the
ports of its last 5 registrations. By hand: `tailscale serve --https=41443 --set-path=/ off`.

## Who can install

**Anyone on your tailnet can open the page and install those builds.** On a tailnet you share,
restrict it with Tailscale's access rules.

To take the page down, delete `~/Library/Application Support/RoamRun/ota/`: RoamRun stops serving
and gives the port back at its next look, within 30 seconds. Deleting one build's folder removes
that build. The folder is excluded from Time Machine.

## On the device

RoamRun cannot check these, because they happen on the device:

- An Ad Hoc build needs Developer Mode on to launch, on iOS 16 and later. The switch appears under
  Settings › Privacy & Security once the app is installed, and the device restarts once.
- An Enterprise build needs its developer trusted under Settings › General › VPN & Device
  Management.
