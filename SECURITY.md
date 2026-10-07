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
  The bridge holds no keys and can't bypass pairing: a device that isn't paired
  with this Mac can't be reached through it.
- **Device control holds a key of its own**, once you set it up for a device.
  To show and operate a device, RoamRun pairs with it
  itself (you confirm with a code on the device) and keeps that pairing, which
  holds a private key: whoever has it and can reach the device over the network
  can see its screen and operate it, with no further consent on the device. It is
  saved sealed (AES-GCM) under `~/Library/Application Support/RoamRun/`, with a
  key kept in your login Keychain that macOS gives to RoamRun only — a copy of
  the file alone opens nothing, and another program asking for the key makes
  macOS ask you. It is not protection against something that runs as RoamRun or
  that you allow in that prompt. A released RoamRun reads its key without one, so
  with it a prompt about that item — or about the other one RoamRun keeps there,
  the list of devices switched on — is a sign that something else replaced it:
  don't allow it; a build you made yourself, signed otherwise, does get asked. The device lists the pairing in Settings ›
  Privacy & Security › Developer Mode, where it can be removed; during each look
  or action, and for about five seconds after, the device shows screen sharing.
  **Locking the device doesn't stop device control**: its lock screen is seen and
  operated like any other — what it shows (notifications as the device is set to show
  them) and what it lets be done without unlocking. Unlocking takes the device's
  passcode or Face ID, as ever: whoever knows the passcode can enter it from here,
  and a swipe to unlock sent while the device's user looks at it is answered by Face ID.
  What stops device control is its switch on the device's page. While **Set Up…** or
  `roamrun key create` waits (and only then), the Mac announces itself on the
  local network (`_remotepairing-pairable-host._tcp`, as "RoamRun (the Mac's name)", or for
  `key create` the name given to `--as`, else "RoamRun (the file's name)") and listens on a port, on every interface, for the device
  to pair; the six-digit code is what keeps another device from pairing instead —
  one that did would be given nothing, and its pairing is kept only if it names
  itself as the device you set up. The connection itself goes from the Mac to the
  device's VPN address and is encrypted by the tunnel it opens; screen images and
  input travel in it. **Each side proves itself to the other at every
  connection**: the Mac with the pairing's key, the device with the key it gave
  when the pairing was made, which RoamRun keeps with the pairing. Something else
  answering at the device's address is refused before this Mac says who it is or
  sends anything of yours, and that is said as what it is — not as the device
  having dropped the pairing (a refusal is believed only from the device).
- **Any program you run can use device control while it is switched on.** Any
  process of your user can ask the running app to look at or operate a paired
  device (the `roamrun` commands do): the key stays with RoamRun, but RoamRun
  uses it for whoever asks. It is not a permission given to one agent — a build
  script or a package's install step is let in as well. Each device has a switch
  on its page: off, every request is refused; a text being typed or a walk of
  the elements stops where it is, and what was waiting its turn isn't begun (a
  tap or a press already on its way arrives). What is on is kept in the login Keychain, where another program can't
  add to it without macOS asking you, and it names the pairing itself, as it is
  saved for its device — not the device's entry in the list of saved devices,
  which any program can rewrite — so a device you switched off stays off. A
  pairing that a saved device no longer connects with (its file moved away or
  replaced, its device deleted) loses its switch once RoamRun, running, has seen
  that (it looks every half minute, and whenever the list of devices is saved):
  brought back after that, it is off. While the list of devices couldn't be read
  whole, nothing is dropped; a device missing from it then loses its switch when
  the list is next saved; it is on after Set Up, after Pair
  Again (also for a device you had switched off) and after `key import`. Turn it off when nothing of yours is using the device.
- **Someone on the network can keep a pairing from being made, not make one.**
  While Set Up or `key create` waits, a device on that network can connect,
  ask for a code and then say nothing, which holds the wait (three minutes at
  most each time). It gets nothing by it: without the code shown on this Mac
  there is no pairing. Pair on a network you trust.
- **A pairing made for another Mac is a key in a file.** `roamrun key create`
  pairs once more, under an identity of its own, and writes that pairing to a
  file (yours only, not sealed: the Mac it is for has another key). Nothing of it
  is kept on the Mac that made it, and this Mac's own pairing is never written
  out. Whoever has the file and reaches the device can see and operate it;
  `key import` on the other Mac seals it there and removes the file. The
  device lists each such pairing as an entry of its own, which is how to withdraw
  one: remove it there.
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
  refused, and a bridge that sees one twice stops and says so — which also means
  such a record can stop a bridge, as one that isn't recognised already could).
  Profiles whose UDID was already known when they were added, which is
  the usual case, aren't affected. Check the UDID in `roamrun devices` if it
  matters.
- **Builds kept for over-the-air installs are readable by your whole tailnet.**
  `roamrun ota` stores an .ipa under `~/Library/Application Support/RoamRun/ota/`
  and, while RoamRun runs, publishes a page for it through `tailscale serve` on a
  port of its own (41443 by default), never on your tailnet's `:443`. Serve is tailnet-only — it is not on the
  internet — but every member of the tailnet can open that page and install those
  builds. On a shared tailnet, restrict it with Tailscale Grants / ACLs, or don't
  use the feature. It is not meant to reach the internet: Tailscale Funnel currently
  publishes only 443, 8443 and 10000, RoamRun's port is deliberately none of
  those, RoamRun never turns Funnel on, and it warns if it finds Funnel on for
  that port. That list is Tailscale's policy, not a promise. The port is registered when there is something to serve and
  given back when RoamRun quits — but not if it is force-quit or crashes, so
  `tailscale serve --https=<the port> --set-path=/ off` is how you make sure it's
  gone — `--set-path` names the one mount, so nothing else you serve is touched.
  RoamRun drives `tailscale serve` through its command line, which has no way to
  say "change this only if it still looks the way I just read it". So between
  RoamRun checking that the entry on that port is its own and `tailscale` acting
  on it, something else changing that port would be missed — a fraction of a
  second, and only if you are editing the same port by hand at that moment.
  RoamRun records the exact address it registered and only ever replaces an entry
  matching it — its own, from a run that didn't get to release it — so it won't
  take over something else you serve on that port either. Deleting `ota/` takes the page down
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
  asks `tailscale serve` to carry one port of its own, which tailscaled remembers. Admin rights only
  if you install the CLI and `/usr/local/bin` isn't writable (a password prompt).
- Files: `~/Library/Application Support/RoamRun/` (device profiles, mode 0600,
  bridge status, and `ota/` — the .ipa files you stored, 5 per app), `~/Library/Logs/RoamRun/`, and the
  `io.github.mh-mobile.roamrun` defaults (`com.roamrun.app` before 0.1.12).
  With device control: its socket and the looks on their way to whoever asked (`control/`, yours
  only), this Mac's identity for pairing (`device-control-host`), sealed pairings
  (`device-pairing-<UDID>.sealed`, 0600), and two
  items in the login Keychain, which removing the app leaves:
  `security delete-generic-password -s io.github.mh-mobile.roamrun.device-control -a pairings`
  (the key) and the same with `-a allowed` (the list of devices switched on).
  The CLI link and agent skills are installed only on request and
  never overwrite other files (they do replace an existing RoamRun link or
  RoamRun skill).
- Any process of your user can ask the app to stop a bridge (`roamrun down`
  uses an unauthenticated distributed notification); it can't start one.
- The system log gets RoamRun's messages with device identifiers and addresses
  marked private; the in-app activity log shows them in full.
- **Nothing about you is sent anywhere** — no telemetry, no analytics, no update
  check; there is no code in RoamRun that talks to a server of ours or anyone
  else's. It does open connections of its own — to your device: a TCP probe to see
  whether it answers, the RemotePairing handshake to confirm the answer really
  comes from it, and a scan for its RemotePairing port when that has changed; with
  device control set up, also its own tunnel to the device, kept open. It
  also connects to its own loopback port to check the install page still answers. The bridge itself forwards
  bytes without reading them.
- Helper processes (`dns-sd`, `log stream`) are tied to RoamRun and typically
  exit within about a second if it quits or is killed, taking the advertisement
  with them.

See the README's *Limitations and known issues* for the full list, and *What
it creates on your Mac, and uninstalling* for how to remove everything.
