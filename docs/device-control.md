# Seeing and operating the device

<p align="center">English | <a href="device-control.ja.md">日本語</a></p>

The full reference for device control: operating a device from a command or an AI agent.

RoamRun can show the device's screen and operate it: tap, swipe, type, press its buttons. This is
called device control. It needs **iOS or iPadOS 27 or later**. It does not use the bridge or
Xcode: RoamRun makes a pairing and a connection of its own. It was run on an iPhone; an iPad has
not been tried.

Before you set it up, know this: **while a device is switched on, any program you run on this Mac
can see and operate it**, not only the command or agent you meant it for. The details are under
[Who can use it](#who-can-use-it).

## Setting it up

**Set up once for each device**, with the device on the Mac's Wi-Fi. Open the device's page in
RoamRun and press Device control › Set Up…. On the device, under Settings › Privacy & Security ›
Developer Mode, pick "RoamRun (this Mac's name)" and enter the code the Mac shows. The sheet then
says "Device control is set up", and `roamrun status <name>` shows "Device control: connected".

After that RoamRun connects whenever the device is on a Wi-Fi and reachable over the VPN. The
RoamRun app holds the connection, so it has to be running. A connection that was open stayed open
when the device's Wi-Fi was switched off (seen on iOS 27.0).

## Commands

```sh
roamrun look iPhone /tmp/now.png          # the screen now, as PNG, 1280 pixels at most on its longer side;
                                          # prints the path, its size, then "look 12"
roamrun tap iPhone 295 640                # a point, in the pixels of that image (--look 12: of that look only)
roamrun look iPhone /tmp/now.png          # look again before the next action
roamrun swipe iPhone 295 900 295 450      # drag from one point to another
roamrun look iPhone /tmp/now.png          # and again: each look serves one tap, swipe or pinch
roamrun pinch iPhone 295 640 2            # two fingers about a point: 2 zooms in, 0.5 out
roamrun type iPhone "hello"               # US keys; right only while the device's keyboard is an English one
roamrun paste iPhone "任意の文字列"         # any text, through the device's pasteboard; iOS asks "Allow Paste"
roamrun press iPhone home                 # home, lock, volume-up, volume-down
roamrun elements iPhone                   # what accessibility says is on the screen, without positions
```

## How looks and actions work

- **Look, act, look again.** A `tap`, `swipe` or `pinch` needs a `look` taken within the last minute, and
  each look serves one action. `type` and `paste` may still go by a look an action used (look, tap
  a field, type), and wait until a second after the last input before they are sent.
- `--look <n>` on `tap`, `swipe`, `pinch`, `type` and `paste` (after the text for those two) holds them to
  look n, the number `look` prints: refused once another look (by any caller), a button,
  `elements` or an action without `--look` came since, or after a minute. Without it, a `tap`, `swipe` or `pinch` goes by the last look, and `type` or `paste` needs none.
- The image is the screen as the device holds it. An app in landscape appeared turned on its side
  (seen), and points are still pixels of that image.
- Where the screen stream gives no frame to use, a look is the device's own PNG instead (0.14.0+), which is
  slower: the device refuses the stream (during a phone or VoIP call), its frame can't be read or doesn't fit
  the screen, or the device doesn't say its screen's size. Where the stream doesn't answer (no answer, no key
  frame, timed out: the connection is in doubt), the look fails as before, without the PNG. The PNG is turned as the device's interface is; a `tap`, `swipe` or `pinch` by it is
  turned back to the device held upright, and refused, with nothing sent, once the device was turned since that
  look, where it was turned as that look was taken ("Look again"), or where it is on its side and doesn't say
  which way ("Ask the user to turn it upright"). Where the device doesn't say which way it is when the point is
  sent, the point goes by that look. An input the device refuses the screen stream for (during a call) is sent
  without one.
  `roamrun look` says it used the PNG on stderr ("the device's PNG: …"), and MCP's `look` in its answer. Not yet
  tried on a device.
- `type` sends at most 2000 characters, about 16 a second; a newline is Return, and U+0008 Backspace. Under a
  Japanese keyboard even a space converts instead of being typed (seen); use `paste` there.
- `swipe` takes a duration in milliseconds as a last argument (50–5000, default 300). `elements`
  takes a limit (default 40) and may scroll the screen while it reads.
- `pinch <name> <x> <y> <scale> [ms] [--rotate <degrees>]` puts two
  fingers about the point and moves them until they are `scale` (0.25–4) times as far apart as
  they began, turned clockwise by `--rotate` (−180–180), over ms (50–5000, default 500), then lifts
  them. The wider of the two spreads is 40% of the screen's shorter side; a finger that would leave
  the screen is refused, not moved. Scale 1 without `--rotate` is a two-finger tap. Tried on one
  device, an iPhone Duo, in Google Maps (2026-11-04): opened, scale 1 zoomed out, 2 in,
  `--rotate 45` turned the map clockwise, and after Ctrl-C part-way through a pinch a two-finger
  tap still zoomed out (no finger was left down); folded, scale 1 and 2 did the same; through
  `roamrun mcp`, scale 2 zoomed in.
- `elements` prints one caption a line, followed by ` — id: <identifier>` when the app set an
  accessibility identifier (`com.apple.settings.airplaneMode`). The identifier was seen in what an
  iPhone Duo sent in Settings, where each of the five elements read had one. What the device sent
  held no positions. On 2026-11-06, `roamrunctl mcp`'s `elements` on that iPhone Duo gave the
  identifier on each of 12 lines in Settings, and on a screen of widgets the caption alone for a
  search widget's elements. On 2026-11-20, `roamrun elements` and `roamrun mcp`'s `elements` on that
  iPhone Duo gave the identifier in Apple Maps (`Card grabber`, `UserLocationButton`).

## For an agent (MCP)

**For an agent** the same are MCP tools: `claude mcp add roamrun -- roamrun mcp`, or the like for
another agent. The tools are `devices`, `look`, `tap`, `swipe`, `pinch`, `type`, `paste`, `press` and
`elements`, with the three for apps below. They differ from the commands in four ways: `device` is the name saved in RoamRun, as
`devices` lists it, not a Tailscale name or an id; `look` returns the picture to the agent,
with the look's id, instead of writing a file; `type` takes 500 characters a call; and `tap`,
`swipe`, `pinch`, `type` and `paste` must give that id (`"look": 12`), as `--look` does. An app from before
0.8.0 isn't sent any of these five (it doesn't hold an action to a look); one from 0.8.0 to 0.12
takes all but `pinch`, which comes back saying the app is older.

### Installing and launching apps

`install`, `install_status` and `launch` (0.11.0+) put an app on the device and start it, with no
Xcode: `install` takes the path of an .ipa or an .app folder on this Mac, built and signed for the
device, ends the app's running processes, and answers at once with an id; `install_status` with
that id says when the app is in, and until then other calls on the device answer that it is
installing; `launch` takes the bundle identifier. The file is copied into RoamRun's own folder for
the app, and removed when the install ends (or, if the app quit meanwhile, when it starts again;
one left by a command that was ended goes an hour later while the app runs).
An .ipa is read whole into the app's memory while it is sent to the device (an .app folder is sent
file by file).

## For an agent elsewhere on your tailnet

**For an agent elsewhere on your tailnet** (0.11.0+), `roamrun mcp --http <port> --allow <who>`
serves the same tools over HTTP, until Ctrl-C. `<who>` is `tag:<name>` or a login, and `--allow`
may be given again; `--token-file <file>` also asks every request for `Authorization: Bearer <the
file's token>` (a file only you can read, 32 characters or more), and a call from this Mac itself
is let in only with it. It listens on this
Mac's Tailscale IPv4 address only, at `http://<that address>:<port>/mcp` (give a cloud the
address: it usually has no MagicDNS), and lets in what `tailscale whois` says is a machine with
that tag or that user's untagged machine. Requests, refusals, turns and the log go as
with `roamrunctl mcp --http` ([its rules](roamrunctl-reference.md#mcp-over-http)), with these
differences: it offers the devices saved in RoamRun, each operated only while its switch in the
app is on, rather than devices named on its command line; a call whose caller goes, or takes it
back, after its turn here is given up at the app, as with `roamrun mcp`: not begun if it still
waits there behind another client of the device, stopped where it can if it is under way; and
uploads are kept in RoamRun's own folder rather than one made for the run. The RoamRun app has to
be running, as for `roamrun mcp`. What is shown and sent passes through whatever lies between: a
cloud's proxy sees the images, the text typed or pasted, what is uploaded, and the token. It was
called from this Mac itself with the token, and from an untagged Linux machine of the tailnet let in
by the login (`scripts/mcp-http-check.py`, then an upload, `install` and `launch`; under `--allow
tag:ci` that machine was refused, 403); and on 2026-10-27 from a cloud's Linux machine on the tailnet
(Grok Bot's computer) through mcp-remote, a look and taps on an iPhone Duo. Not yet through a
cloud's proxy, nor with an upload of hundreds of MB.

With `--allow-install [--max-upload <MiB>]` it offers `install` and `install_status`, as
roamrunctl does: the caller sends an .ipa with `PUT /upload` (1024 MiB at most by default), gets
its id and sha256, and installs it by them, never by a path. One upload is kept, for the machine
that sent it to install. An install the app doesn't begin (the device not set up, switched off,
installing or not reached, the caller gone before its turn at the app) leaves it for another try.
It goes when the app answers that an install of it began, when `ota` stores it, when any caller starts another upload,
after 30 minutes unused, or at Ctrl-C; one left by a server that was killed goes about a day later, while
the RoamRun app runs or when it, or another such server, starts. Without `--allow-install` or
`--allow-ota` there is neither.

With `--allow-ota` instead, it is an OTA server: its one tool, `ota`, puts an upload on the
[OTA page](../README.md#installing-without-the-bridge-over-the-air) as `roamrun ota` puts a file, so that a CI
job can publish its build, and it operates no device: [ota.md](ota.md#from-a-ci-job).
The two flags go on two servers, on two ports.

## What the device does meanwhile

**What the device does meanwhile.** Each look and each action runs a screen-sharing session on the
device, which RoamRun keeps for about five seconds after the last one. The device showed it as
screen sharing (seen). What happened to sound and the microphone during such sessions was noted app by
app in one sitting — some apps went on sounding, some played unheard, one stopped, and dictation
took nothing: [sound-while-looking.md](sound-while-looking.md).

## Who can use it

**Who can use it.** Device control is not given to one agent or one command. **While a device is
switched on, any program you run on this Mac can see and operate it**, and install and launch apps
on it, through the app: a build
script, a package's install step, another agent. A `look` shows whatever is on the screen,
notifications and messages included, and locking the device does not stop it: the lock screen is
seen and operated too (seen), though unlocking still takes the passcode or Face ID. **While
the MCP server over HTTP (`mcp --http`, above) runs, so can any program on the machines its `--allow` lets in** (each
untagged machine of a login allowed, each machine with a tag allowed), on every device switched
on, `launch` included; with `--allow-install` it can also replace the device's apps with any app
signed for it. An OTA server (`--allow-ota`) operates no device: what it lets them do is put an Ad
Hoc or Enterprise build on the OTA page, for anyone on the tailnet to install. `--token-file` is the one check beyond the machine.

- The switch beside Device control on the device's page turns it off for every program, and back
  on. It is on after Set Up, Pair Again, `roamrun key import <file>` and `roamrun pair control --with <Tailscale name>`.
  Turn it off when nothing of yours is using the device.
- A `look` written to a file is readable by you alone and stays until you delete it.
- At every connection the Mac and the device verify each other. Something else answering at the
  device's address is refused and gets no input.
- The pairing holds a private key. How it is kept, and who can use it: [SECURITY.md](../SECURITY.md).
- To withdraw device control, remove RoamRun's entry on the device under Developer Mode.

## Device control on a far Mac

Setting up needs the Mac and the device on one Wi-Fi. A Mac elsewhere, such as one in a data
centre, never is. When both Macs are on one tailnet, a Mac on the device's Wi-Fi introduces the
far Mac, and the far Mac makes its own pairing and keeps it, sealed. The Mac beside the device
relays the device's connection without reading it and saves nothing of it, but it shows the code
to type: introduce with a Mac you trust.

```sh
roamrun pair control --with macbook-pro              # on the far Mac, with the RoamRun app open
roamrun pair introduce --host cloud-mac --to iPhone   # on the Mac beside the device, run by you; iPhone is saved in RoamRun there
roamrun look iPhone                                  # on the far Mac, once it says the device is paired
```

The names are the Macs' Tailscale names. On the device, pick "cloud-mac" and type the code that
`pair introduce` prints. Run `pair introduce` yourself, in your own terminal: an agent that ran it
would have the code in its output.

- The far Mac waits up to 10 minutes for the other Mac, then up to 9 minutes for the pairing.
- A wrong code ends `pair introduce`, not the far Mac's command. Run `pair introduce` again and
  the far Mac makes a new code: five tries in all.
- The far Mac needs the RoamRun app open in a logged-in session. It needs neither Xcode nor the
  device saved beforehand.
- It does not begin for a device that Mac already holds a working pairing for: remove that one
  first, on the device's page there.
- `roamrun pair control --last` on the far Mac says what came of the last attempt, for when its
  end did not reach the other Mac.

Without Tailscale between the two Macs, make the pairing on a Mac beside the device and carry it:

```sh
roamrun key create iPhone ~/iphone-for-cloud.json --as cloud-mac   # beside the device: pick "cloud-mac" on it, enter the code
roamrun key import ~/iphone-for-cloud.json                         # on the far Mac, with the RoamRun app running: saves the device and its pairing, removes the file
```

The file is a key. Whoever has it and reaches the device can see and operate it, so move it as you
would a password and keep no copy. `key import` keeps the pairing only if it connects, so the
device has to be reachable then. If the device restarted since the file was made, its port has
changed: for a device not yet saved on the far Mac, `key import` looks for the port; for one that
is saved, use Find RemotePairing Port on its page first. Each pairing made this way is listed on the device under its own
name and can be removed there alone.

Setting such a Mac up from nothing — Tailscale, RoamRun, the pairing — is in
[another-mac.md](another-mac.md), with a script that does it.
