# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: open the repository's
**Security** tab and choose **Report a vulnerability**. Don't open a public issue
for them. Include the RoamRun version (`roamrun --version`), macOS / Xcode / iOS
versions, and `roamrun doctor --json` output if it's relevant.

Only the latest release is supported.

## What RoamRun does on your network

RoamRun needs to do a few unusual things; this is what they are and how they're
bounded.

- **It advertises your device on the local network.** While a bridge runs,
  `dns-sd` publishes the device's `_remotepairing._tcp` record (instance name,
  identifier, authTag) pointing at this Mac, on every interface with mDNS. Unlike
  the device's own advert, these values don't rotate, and the record's host name
  (`rr-<id>.roamrun.local`) is fixed too, so someone on the same network could
  notice the device is paired with this Mac — on every network the Mac joins,
  e.g. a café's if you bridge from a laptop. Bridges stand aside (publish
  nothing) while the device is on the Mac's own network.
- **It listens for TCP on the Mac's LAN interface (en0 unless chosen otherwise in
  Settings › Network).** The relay accepts
  a connection only if it comes from this Mac's own address (so any local process
  qualifies, as it could reach the device's Tailscale address anyway) — anything
  else is dropped immediately. It forwards bytes unchanged to the device's Tailscale (or
  manually entered) address and never reads, stores or alters them.
- **Authentication and encryption are Apple's.** Pairing verification and the
  encrypted CoreDevice tunnel run end to end between the Mac and the device.
  RoamRun holds no keys and can't bypass pairing: a device that isn't paired
  with this Mac can't be reached through it.
- **The device's RemotePairing and tunnel ports are reachable from your
  tailnet.** Other tailnet members can connect, but pair verification and the
  pair-derived tunnel keys reject them. On a shared tailnet, restrict access to
  the device with Tailscale Grants / ACLs.
- **Others can interrupt a bridge, not take it over.** Someone on the same
  network can replay the advertised record to make a bridge believe the device
  is home and stand aside; a local process can flood the relay (connections are
  capped) or ask the app to stop a bridge. None of this gives access to the device.
- **A device saved before its UDID was known can learn the wrong one.** RoamRun
  takes a profile's UDID from what `remotepairingd` reports for the advert the
  device was added from. Someone on the same network as the Mac can publish a
  record under that instance name carrying another device's identifier, and the
  profile then saves that device's UDID — so `run`, `install` and `screenshot`
  would address the wrong one. It only works between devices already paired with
  this Mac, and only until the UDID is saved (after that a different one is
  refused). Profiles whose UDID was already known when they were added, which is
  the usual case, aren't affected. Check the UDID in `roamrun devices` if it
  matters.
- **Builds kept for over-the-air installs are readable by your whole tailnet.**
  `roamrun ota` stores an .ipa under `~/Library/Application Support/RoamRun/ota/`
  and, while RoamRun runs, publishes a page for it through `tailscale serve` on
  one path (`/roamrun` by default). Serve is tailnet-only — it is not on the
  internet — but every member of the tailnet can open that page and install those
  builds. On a shared tailnet, restrict it with Tailscale Grants / ACLs, or don't
  use the feature. RoamRun won't publish at all while Tailscale Funnel is on for
  that port, and takes the page down if Funnel is turned on afterwards: Funnel
  would put those builds on the open internet. The path is registered when there is something to serve and
  given back when RoamRun quits — but not if it is force-quit or crashes, so
  `tailscale serve --set-path /roamrun off` is how you make sure it's gone.
  RoamRun records the exact address it registered and only ever replaces an entry
  matching it — its own, from a run that didn't get to release it — so it won't
  take over something else you serve there. Deleting `ota/` takes the page down
  at the next check; deleting one build's folder inside it removes just that one.
- **`roamrun run` builds the project in the current folder.** Its build scripts
  and package plugins run as you, and like Xcode it may create provisioning
  profiles in your team. Use it (or let an agent use it) on projects you trust.
- **Integrity of releases.** From 0.1.12, releases are signed with a Developer
  ID and notarized by Apple (earlier ones were ad-hoc signed); the Homebrew
  cask also checks the dmg's SHA-256, and building from source avoids the
  question entirely.

## What it touches on the Mac

- No kernel or network-configuration changes, no daemons — except that `roamrun ota`
  asks `tailscale serve` to carry one path, which tailscaled then remembers. Admin rights only
  if you install the CLI and `/usr/local/bin` isn't writable (a password prompt).
- Files: `~/Library/Application Support/RoamRun/` (device profiles, mode 0600,
  and bridge status), `~/Library/Logs/RoamRun/`, and the
  `io.github.mh-mobile.roamrun` defaults (`com.roamrun.app` before 0.1.12).
  The CLI link and agent skills are installed only on request and
  never overwrite other files (they do replace an existing RoamRun link or
  RoamRun skill).
- Any process of your user can ask the app to stop a bridge (`roamrun down`
  uses an unauthenticated distributed notification); it can't start one.
- The system log gets RoamRun's messages with device identifiers and addresses
  marked private; the in-app activity log shows them in full.
- **Nothing about you is sent anywhere** — no telemetry, no analytics, no update
  check; there is no code in RoamRun that talks to a server of ours or anyone
  else's. It does open connections of its own — to your device, and
  to its own loopback port to check the install page is up: a TCP probe to see whether it answers, the
  RemotePairing handshake to confirm the answer really comes from it, and a scan
  for its RemotePairing port when that has changed. The bridge itself forwards
  bytes without reading them.
- Helper processes (`dns-sd`, `log stream`) are tied to RoamRun and typically
  exit within about a second if it quits or is killed, taking the advertisement
  with them.

See the README's *Limitations and known issues* for the full list, and *What
it creates on your Mac, and uninstalling* for how to remove everything.
