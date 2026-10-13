# Installing over the air: details

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

- The page can take half a minute to appear after the app starts: RoamRun looks every 30 seconds.
- `roamrun doctor` prints the address again while a build is stored.
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
- a bundle identifier with characters other than letters, digits, `.`, `-` and `_`.

An Ad Hoc build installs only on the devices its provisioning profile names. RoamRun says which
of your devices those are. It knows the UDID of every device it has bridged, so bridge a device
once (`roamrun up <name> -d`) to let it learn the UDID. A build that names none of your devices is
still stored, with a warning: the profile may name a device this Mac has never seen. An Enterprise
build needs none of this.

**HTTPS in your tailnet**: MagicDNS and HTTPS certificates turned on.

**RoamRun running**, since the app serves the page.

## The port, and Funnel

RoamRun serves on a port of its own, 41443 by default, and gives it back when it quits. To change
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
