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
- **`roamrun run` builds the project in the current folder.** Its build scripts
  and package plugins run as you, and like Xcode it may create provisioning
  profiles in your team. Use it (or let an agent use it) on projects you trust.
- **Integrity of releases.** Releases are ad-hoc signed and not notarized; the
  Homebrew cask checks the dmg's SHA-256, and building from source avoids the
  question entirely.

## What it touches on the Mac

- No kernel or network-configuration changes, no daemons. Admin rights only
  if you install the CLI and `/usr/local/bin` isn't writable (a password prompt).
- Files: `~/Library/Application Support/RoamRun/` (device profiles, mode 0600,
  and bridge status), `~/Library/Logs/RoamRun/`, and the `com.roamrun.app`
  defaults. The CLI link and agent skills are installed only on request and
  never overwrite other files (they do replace an existing RoamRun link or
  RoamRun skill).
- Any process of your user can ask the app to stop a bridge (`roamrun down`
  uses an unauthenticated distributed notification); it can't start one.
- The system log gets RoamRun's messages with device identifiers and addresses
  marked private; the in-app activity log shows them in full.
- Helper processes (`dns-sd`, `log stream`) are tied to RoamRun and typically
  exit within about a second if it quits or is killed, taking the advertisement
  with them.

See the README's *Limitations and known issues* for the full list, and *What
it creates on your Mac, and uninstalling* for how to remove everything.
