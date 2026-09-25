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
  the device's own advert, these values don't rotate, so someone on the same
  network could notice the device is paired with this Mac. Bridges stand aside
  (publish nothing) while the device is on the Mac's own network.
- **It listens for TCP on the Mac's primary interface (en0).** The relay accepts
  a connection only if it comes from this Mac's own address — anything else is
  dropped immediately. It forwards bytes unchanged to the device's Tailscale (or
  manually entered) address and never reads, stores or alters them.
- **Authentication and encryption are Apple's.** Pairing verification and the
  encrypted CoreDevice tunnel run end to end between the Mac and the device.
  RoamRun holds no keys and can't bypass pairing: a device that isn't paired
  with this Mac can't be reached through it.
- **The device's RemotePairing port is reachable from your tailnet.** Other
  tailnet members can connect to it, but pair verification rejects them. On a
  shared tailnet, restrict access to the device with Tailscale Grants / ACLs.

## What it touches on the Mac

- No kernel or network-configuration changes, no daemons. Admin rights only
  if you install the CLI and `/usr/local/bin` isn't writable (a password prompt).
- Files: `~/Library/Application Support/RoamRun/` (device profiles, mode 0600,
  and bridge status), `~/Library/Logs/RoamRun/`, and the `com.roamrun.app`
  defaults. The CLI link and agent skills are installed only on request and
  never overwrite files they didn't create.
- Helper processes (`dns-sd`, `log stream`) are tied to RoamRun and exit within
  a second if it quits or is killed, taking the advertisement with them.

See the README's *Limitations and known issues* for the full list, and *What
it creates on your Mac, and uninstalling* for how to remove everything.
