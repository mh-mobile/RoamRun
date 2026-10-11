# Installing an app on an iPhone plugged into another Mac, over Tailscale

Not a RoamRun feature: a way through `usbmuxd`, [usbfluxd](https://github.com/corellium/usbfluxd),
`socat` and [xtool](https://github.com/xtool-org/xtool), written down as it was tried. The iPhone is
plugged by USB into one Mac; another machine on the tailnet — a VM that can't be handed a USB
device, a cloud Mac — builds an app and installs it there. It installs and nothing more: see
[What it doesn't do](#what-it-doesnt-do).

```
iPhone ──USB── the Mac it is plugged into (usbmuxd) ── socat ── Tailscale ── usbfluxd ── xtool (the working Mac)
```

The idea is from Leon Jacobs, [using a cloud mac with a local ios device](https://sensepost.com/blog/2022/using-a-cloud-mac-with-a-local-ios-device/)
(SensePost, 2022), which also says Tailscale would be the simpler network for it.

Tried on 2026-10-07: the iPhone's Mac on macOS 27; as the working Mac, a macOS 27 VM with Xcode 27
(behind NAT, Tailscale through a relay) and a Mac in a cloud; an iPhone 15 Pro on iOS 27 and an
iPhone XS on iOS 18.6.2; xtool 1.21.0; usbfluxd at `608cb24`.

## What is needed

- Both Macs on one tailnet.
- The iPhone plugged into its Mac and trusted there ("Trust This Computer"), Developer Mode on.
- On the working Mac: Xcode and Homebrew (xtool on macOS builds with Xcode's SDK).
- An App Store Connect API key for xtool's signing. A person types it in: it isn't pasted into a
  chat or a log.

Below, `HOST_TS` is the Tailscale address of the iPhone's Mac and `WORK_TS` the working Mac's
(`tailscale ip -4` on each).

## 1. On the iPhone's Mac: offer usbmuxd's socket to the working Mac alone

```sh
brew install socat
socat TCP4-LISTEN:5055,bind=HOST_TS,range=WORK_TS/32,reuseaddr,fork UNIX-CONNECT:/var/run/usbmuxd
```

- It prints nothing and doesn't return while it runs. Control-C stops it.
- `TCP4-LISTEN`, not `TCP-LISTEN`: with the latter `range` is a syntax error.
- Not port 5000 (usbfluxd's default): on macOS the AirPlay receiver has it.
- **Nothing here asks who connects.** Whoever reaches the port uses the iPhone as the Mac it
  trusts does. Keep `bind` and `range`, and stop it when done.

## 2. On the working Mac: build usbfluxd and start it

The macOS archive of a release holds `usbfluxctl` only, so it is built from source.

```sh
brew install libplist autoconf automake libtool pkg-config ideviceinstaller
git clone --depth 1 https://github.com/corellium/usbfluxd ~/usbfluxd
cd ~/usbfluxd && ./autogen.sh && make -j8

nc -vz -G 5 HOST_TS 5055        # does the port answer?
sudo ~/usbfluxd/usbfluxd/usbfluxd -f -v -m -r HOST_TS:5055 > ~/usbfluxd.log 2>&1 &
grep -E "Added remote|client_device_add" ~/usbfluxd.log   # both: the device is seen
idevice_id -l                   # the iPhone's UDID
```

- It needs root: it takes the place of `/var/run/usbmuxd` (the Mac's own moves to
  `/var/run/usbmuxd.orig`). While it runs, everything on that Mac that asks usbmuxd gets this one.
- No pairing record is put on the working Mac: the iPhone's Mac answers with its own.

## 3. On the working Mac: build and install with xtool

```sh
brew install --cask xtool-org/tap/xtool
xtool auth login                # the API key, typed by a person
xtool devices                   # → iPhone [usb]: <UDID>

xtool new Hello && cd Hello
xtool dev run                   # build → sign → install
ideviceinstaller list --user | grep -i hello
```

- `[Verifying] 100%` and exit status 0: the app is on the Home Screen. It is opened by hand.
- A device xtool hasn't met is registered with the developer account, and the profile is made anew.
- With two devices plugged in: `xtool dev run --udid <UDID>`. Plugging another one in shows on the
  working Mac at once; unplugging takes it away there too.
- A small app, second run onwards: about 6 s with Tailscale direct on one LAN, about 10 s through
  Tailscale's relay.

## 4. Afterwards

```sh
# the working Mac
sudo pkill -TERM usbfluxd
ls -l /var/run/usbmuxd*         # one socket again, the Mac's own
xtool auth logout

# the iPhone's Mac: Control-C in socat's window
```

The API key is revoked in App Store Connect when it is no longer needed.

## When it doesn't go

| What is seen | Where to look |
|---|---|
| `nc`: Connection refused | `socat` isn't running on the iPhone's Mac, or `bind` / `range` name other addresses |
| `nc` times out | Tailscale: `tailscale status`, `tailscale ping HOST_TS` |
| `xtool devices` shows nothing | `client_device_add` in `~/usbfluxd.log`? If not: does the iPhone's Mac see it (`idevice_id -l` there, "Trust")? |
| `usbfluxd` doesn't start | One running already (`pgrep usbfluxd`)? A `/var/run/usbmuxd.orig` left behind? |
| The install fails | The iPhone unlocked, Developer Mode on, `xtool auth status` |

## What it doesn't do

- **Launch, debug, or show the screen.** `xtool dev run` ends at the install. Since iOS 17 those go
  by another way (CoreDevice's pairing and tunnel), which usbmuxd's socket doesn't carry: that way is
  what RoamRun bridges.
- **Reach an iPhone that isn't plugged in.** Unplugged, it was gone from the working Mac at once.
  The iPhone was on another network then; whether one on its Mac's own Wi‑Fi would still show
  wasn't tried.

## Not tried

- Whether Xcode on the working Mac lists the device this way. The article above has it listed, in
  2022; for iOS 17 and later it isn't expected to (see above), and it wasn't looked at.
- xtool on Linux as the working machine.
- A large app, or a slow line.
