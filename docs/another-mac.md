# Setting up another Mac to operate your device

A Mac that isn't at your desk — a cloud Mac an agent runs on, a CI runner, a second machine —
can see and operate your iPhone through RoamRun once three things are on it: Tailscale, RoamRun,
and a pairing made on a Mac that can pair. Xcode isn't needed there. `scripts/set-up-mac.sh`
does the part on that Mac in one go; what it does, and what only you can do, is below.

What that Mac needs: Apple silicon, macOS 13 or later, [Homebrew](https://brew.sh), an
administrator's password (Tailscale's service is started with it), and somebody logged in at
its screen — the RoamRun app holds the connection, and an app needs a session to run in.

## 1. On your own Mac: make a pairing for it

With the device on your Mac's Wi‑Fi, unlocked:

```sh
roamrun key create iPhone ~/for-the-other-mac.json --as other-mac
```

Pick "other-mac" on the device, under Settings › Privacy & Security › Developer Mode,
and enter the code shown. The file is a key to the device: carry it as one, and leave no copy
behind. It is this one pairing you remove on the device to take the other Mac's access away.

Once the other Mac is on your tailnet (steps 2 and 3, without the file), there is a way that
carries nothing: there, with the RoamRun app open, `roamrun pair control --with <this-mac>`,
and here `roamrun pair introduce --mac <that-mac> --to iPhone`, run by you — the code to enter
on the device prints here. The README's "From a Mac that can't pair itself" (under Seeing and
operating the device) has it; it needs iOS 27.

## 2. In Tailscale's admin console: an auth key for it

[Settings › Keys › Generate auth key](https://login.tailscale.com/admin/settings/keys). For a Mac
you'll use for a while and then let go:

| Setting | Choose | Why |
|---|---|---|
| Reusable | off | the key adds one machine, once |
| Expiration | 1 day | long enough to run the script |
| Ephemeral | on | the machine leaves your tailnet by itself once it is offline |

An ephemeral machine that restarts has left the tailnet: it needs a new key (`roamrun status`
then says this Mac isn't signed in to Tailscale). Leave Ephemeral off for a Mac that is to stay,
and remove it yourself when it shouldn't.

That Mac joins as yours and reaches whatever you reach. To let it reach the device alone, give
the key a tag and write a grant for that tag in your tailnet's policy.

## 3. On the other Mac

With the pairing file brought over:

```sh
curl -fsSLO https://raw.githubusercontent.com/mh-mobile/RoamRun/main/scripts/set-up-mac.sh
TS_AUTHKEY=tskey-auth-… sh set-up-mac.sh ~/for-the-other-mac.json
```

Read the script first: it runs `sudo`. It installs Tailscale and joins your tailnet, installs
RoamRun and opens it, installs the agent skill, and imports the pairing — skipping what is
already done, so it can be run again. `TS_AUTHKEY=file:/path/to/key` keeps the key out of the
process list.

By hand, it is:

```sh
brew install tailscale
sudo brew services start tailscale
sudo tailscale up --auth-key=tskey-auth-…
brew install --cask mh-mobile/tap/roamrun
open -a RoamRun
roamrun init
roamrun key import ~/for-the-other-mac.json
```

Without Homebrew, RoamRun is the dmg on [Releases](https://github.com/mh-mobile/RoamRun/releases/latest)
(signed and notarized): copy `RoamRun.app` to `/Applications`, and the command is
`/Applications/RoamRun.app/Contents/MacOS/RoamRun`.

The first time RoamRun opens, macOS asks at that Mac's screen whether it may find devices on
the local network. `import` removes the file once the pairing is saved, sealed under a key in
that Mac's Keychain.

## 4. Check

```sh
roamrun status iPhone        # "Device control: connected"
roamrun look iPhone /tmp/now.png
```

The device has to be awake and on a Wi‑Fi for the connection to be made; it then stays through
cellular. If it doesn't connect, `roamrun doctor iPhone` says which step fails.

For an agent there: the skill `roamrun init` installed tells it how to look and act, and
`roamrun mcp` is the same as MCP tools (a stdio server: the command `roamrun`, the argument `mcp`).

## 5. When that Mac is done with

- On the device, remove "other-mac" under Developer Mode: the pairing ends, wherever
  copies of the file are.
- In Tailscale's admin console, remove the machine (an ephemeral one goes by itself).
- On that Mac, if it stays yours: `brew uninstall --zap --cask roamrun`, and the two Keychain
  items the README's uninstall section names.
