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
  Settings › Network).** A bridge's relay accepts
  a connection only if it comes from this Mac's own address (so any local process
  qualifies, as it could reach the device's Tailscale address anyway) — anything
  else is dropped immediately. It forwards bytes unchanged to the device's Tailscale (or
  manually entered) address and never reads, stores or alters them.
- **Three commands take a connection from another host, each only while it runs:**
  `roamrun pair introduce`, from the device's LAN, and `roamrun pair xcode --with`
  and `roamrun pair control --with`, from one Mac of the tailnet (the next point,
  and the one on device control below). `pair introduce` lets a Mac that was never on the
  device's network pair with it: for five minutes at most it announces that Mac's
  offer to pair on this Mac's LAN interface — on that one interface, or not at all —
  and relays what connects to the port it opens there to that Mac's pairing port,
  over the tailnet. What to know:
  - Nothing can ask for it. RoamRun listens for no such request; a person (or an
    agent they told to) runs the command, naming the Mac by its Tailscale name.
    The Mac it relays to is the one Tailscale has under that name: the line it is
    given carries a port and what to announce, never an address, a host or a
    service type.
  - It takes connections from the device's address on that LAN alone, two at once
    at most. It has that address from Tailscale (pinging the device when Tailscale
    hasn't talked to it lately), and doesn't start when Tailscale reaches the
    device only through a relay or over IPv6: the port it relays to is the
    one the offer names, and opening that to a whole LAN would let any host there
    reach whatever listens on it on that Mac. A host that takes the device's
    address on the LAN is taken for the device; pairing still needs the code.
  - The offer's port is not checked to be Xcode's pairing port — only that it is
    1024 or above and answers. Give `pair introduce` only an offer from a Mac you
    trust; by name, it comes from the Mac you named.
  - **The code doesn't prove which Mac is at the other end.** It is shown by
    whatever listens on the named Mac's port and typed on the device; this Mac
    sees neither. What you are trusting is the Mac you named: introduce one only
    if you would plug the device into it. For a Mac of your own, type only a code
    you read off its screen yourself.
  - The device shows the entry under that Mac's Tailscale name, which is this
    Mac's doing: the name the offer carried is that Mac's own to choose and isn't
    announced. Once paired, though, the device lists it under the name that Mac
    gives in the pairing itself — its computer name, which can be anything,
    another Mac's name included. `pair introduce` says which name that will be.
  - While it runs, that Mac's Tailscale name, model and the offer's identifier are
    announced on the LAN.
  - It ends when a connection that carried data both ways has closed, at its five
    minutes, when stopped, or when the interface loses its address (it doesn't
    announce elsewhere instead). It then closes its listener, waits for its
    `dns-sd` to be gone and says so — or that it couldn't confirm it. Other hosts
    may show the announcement from their caches a little longer; nothing answers it.
  - A Mac introduced can use the device as a developer until it is removed on the
    device. RoamRun has no switch for Xcode's pairing, there or here. Tailscale's
    access rules are the other way to cut it off.
  - A pairing made on a rented or cloud Mac lives on that machine's disk, and in its
    images and snapshots. Macs made from one image hold one identity: the device
    treats them as one Mac.
- **`roamrun pair xcode --with <Mac>` listens for one Mac, over Tailscale.** It
  spares carrying the two lines below by hand: the Mac that offers to pair waits
  for the Mac that will introduce it, gives it the offer, and is handed the device
  to save. What to know:
  - It listens on this Mac's Tailscale address, port 41830, and on Tailscale's
    interface alone: an address by itself doesn't keep out a host on the LAN that
    routes to it. It listens only while the command runs — ten minutes at most
    for a connection to begin, seven more for the result of one that got the offer.
  - It answers one machine. The name given is looked up once, in this Mac's own
    Tailscale; from then on a connection is taken only from that machine's address,
    and only if Tailscale says, at that moment, that the address is still that
    machine's (by Tailscale's lasting id for it — never by a name, and never when
    Tailscale can't say). The Mac that connects holds the Mac it named to the same.
    One connection at a time; one turned away doesn't count.
  - That is the machine, not the program or the person: anything running on the
    Mac named can connect. It is the trust `pair introduce` already places in a
    Mac that is named.
  - What arrives is read as one of six short lines, 4 KB at most, and dropped
    otherwise; the offer and the device inside them are checked exactly as the
    carried lines are. Why something ended travels as a code word; the sentence
    shown is this Mac's own.
  - The device is saved only when the other Mac says a pairing was tried. That
    isn't proof one was made: `roamrun up` shows it.
  - The Mac that introduces listens for nothing more than before. If the
    connection to the other Mac ends while it stands in, it stops standing in.
    A Mac that goes away without closing it (asleep, off the tailnet) isn't
    noticed: the stand-in then runs to its five minutes.
  - Which offer is this Mac's own is read from what is announced on its network:
    one whose port something on this Mac listens on. A host on that network can
    announce another, and so make the command stop ("more than once") or pass on
    an offer that isn't Xcode's. Nothing is paired by that — the code is still
    Xcode's to show — but run it on a network you'd run Xcode's own pairing on.
  - A connection still open when the five minutes end is cut, and reported as
    nothing paired, whatever it carried.
  - Not tried with a Mac shared in from another tailnet.
- **The lines carried between Macs are not secrets, and are not trusted.**
  `roamrun pair xcode` prints a port and seven announced values; `roamrun devices
  export` (and `pair introduce`, at its end) prints a saved device's name, its
  Tailscale name, its port and five announced values — no key, no UDID, no
  address. Each is read only as exactly that, value by value, and refused
  otherwise. `roamrun devices add` finds the device by that Tailscale name on its
  own tailnet (`--peer` names another) and saves it without a UDID, which the
  bridge then learns from that Mac's own pairing. A line whose announced identifier
  is another paired device's would have the bridge learn that device's UDID — the
  case described below, reachable here by pasting a line: add only a line from a
  Mac of yours.
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
- **`roamrun pair control --with <Mac>` has the app here pair for device control with a
  device that Mac introduces.** No key is carried and none is written unsealed:
  the app makes the pairing and keeps it as it keeps one it set up itself. What to know:
  - The app listens for the pairing on this Mac's Tailscale address and interface
    alone, takes connections from the one Mac named alone, and announces nothing. It
    listens only for an attempt its command began: ten minutes for the other Mac to
    come, nine more for the device; twelve at most whatever the command does, and
    not past fifteen seconds without the command asking how it stands (a command
    killed leaves no listener). The command itself listens as `pair xcode --with`
    does, on port 41830 — for longer than that when a code was typed wrong: it then
    waits ten minutes more for the other Mac's command to be run again, five tries
    at most, each a pairing of its own with a listener and a code of its own. Only
    for the device's own answer (a wrong code, a refusal, no code in time); a
    connection that broke ends it. One pairing is made at a time on a Mac, however begun: an
    introduction takes the turn Set Up takes, before anything listens, and keeps it
    until what paired is kept. The app's listener is closed the moment the device
    has paired.
  - The other Mac is held to being the one named exactly as for `pair xcode --with`:
    the machine, by Tailscale's lasting id — not the program or the person on it.
  - **The code is shown on the Mac that introduces, and comes from this one.** It
    reaches that Mac over the same connection, as six digits or not at all. So it
    says "this is the pairing the Mac you named began", and nothing about who sits
    at that Mac. The command here prints it nowhere and the app shows it on no
    screen — which keeps it out of an agent's output here, and no more than that:
    a program running as you on this Mac can ask the app what the command asks.
    Run `pair introduce` yourself: its output has the code.
  - It doesn't begin for a device this Mac holds a pairing for (one the device is
    known to refuse, having removed it, doesn't count) — as far as it can
    tell before the device pairs: by its address, what it announces, or its
    Tailscale name. The UDID is told only by the pairing. A device that turns out
    then to be one this Mac held a pairing for has, by pairing again, dropped that
    one: the new pairing is kept in its place, as Set Up does, rather than leave
    the device with none this Mac holds.
  - What pairs is kept only if it opens a connection to the device where this Mac's
    own tailnet has it now (not where a device saved here long since was: its port
    changes when it restarts, and what is saved is brought up to date). Kept, it is switched on, as one set up here is; when
    the Keychain doesn't keep the switch it stays off and says so, and the pairing stays.
  - A stop that comes while what paired is being kept doesn't undo it: the device
    would be left knowing a pairing nothing holds. Stopped before, nothing is kept
    here — the device may list the pairing all the same: remove it there. Keeping
    isn't cut short when it takes long (a Keychain that waits to be answered), and
    no other pairing begins on this Mac meanwhile; one that never ends is ended by
    quitting RoamRun and opening it again.
  - The device, its pairing and the switch are three things in three places, written
    one after the other. An app that dies between them can leave a device saved
    without a pairing (as any device added and not set up), or a pairing switched
    off. Nothing is cleaned up at the next start, so nothing kept is removed by it.
  - Not tried with a Mac shared in from another tailnet.
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
  uses an unauthenticated distributed notification); it can't start one. It can run
  the CLI, as you can: `roamrun pair introduce` included, which the device's own
  pairing screen and code then stand between and a pairing.
- The system log gets RoamRun's messages with device identifiers and addresses
  marked private; the in-app activity log shows them in full.
- **Nothing about you is sent anywhere** — no telemetry, no analytics, no update
  check; there is no code in RoamRun that talks to a server of ours or anyone
  else's. It does open connections of its own — to your device (and, for `pair
  introduce`, one to the pairing port of the Mac you named, to see that it is
  waiting, before anything is announced): a TCP probe to see
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
