# The `roamrun` command

<p align="center">English | <a href="cli.ja.md">日本語</a></p>

What the `roamrun` commands for the bridge and Xcode do, in detail. Device control's commands are in
[device-control.md](device-control.md). The [README](../README.md#commands) has the ones used most.

The app's binary is also the `roamrun` command, for use over SSH or in scripts.

```sh
roamrun devices               # saved devices (name, UDID, id) and their status
roamrun up <name>             # start a bridge and show its progress; it runs until Ctrl-C
roamrun up <name> -d          # start it in the background; it survives closing the terminal
roamrun status <name>         # exits 0 when Xcode can use the device
roamrun down <name>           # stop a bridge, whether the app or another terminal started it
roamrun doctor                # check Mac → Tailscale → device step by step, and say how to fix
roamrun run <name> [--scheme S] [--logs]   # in a project folder: build, install, launch
roamrun install <name> <App.ipa|App.app>   # install a build signed for the device
roamrun logs <name> <bundle-id>            # relaunch the app and stream its print / os_log output
roamrun screenshot <name> [file.png]       # save the device's screen as PNG and print the path
roamrun ota [<name>] <App.ipa> [--replace] # publish a build for a device to install by itself
```

`<name>` is the name you gave the device in RoamRun. It is
case-insensitive and unique; `roamrun devices` lists the names, and the pencil on the device's page
renames it. The name in the device's Settings app is a separate one. When no saved device has that name, the device's Tailscale name (`iphone-15-pro`, as `roamrunctl` takes it, not the whole `iphone-15-pro.tail1234.ts.net`) works too, and so does its id or its first eight or more characters. A device is added in the app, or from the command line with
`roamrun devices add <line>` (a line that another Mac made), `roamrun key import <file>`,
`roamrun pair xcode --with <Tailscale name>` or `roamrun pair control --with <Tailscale name>`. They are described under
[Device control](device-control.md) and [Pairing a far Mac](far-mac.md).

What each command does, more exactly:

- `up -d` waits up to 60 seconds for Ready (or On this Wi‑Fi) and exits 1 if neither came. The
  bridge keeps trying in the background unless it met an error that retrying cannot fix. Its log
  is in `~/Library/Logs/RoamRun/`.
- `status` without a name lists every saved device and exits 0 if any one is ready, so name the
  device when a script needs the answer for that one. `--wait N` waits up to N seconds; it can
  return a few seconds late, because each round asks `devicectl` once.
- `doctor` takes a name too. Without one it checks the devices that have a bridge running, or all
  of them if none has.
- `run` builds the Xcode project in the current folder with `-allowProvisioningUpdates`, so like
  Xcode it may create provisioning profiles. `--scheme` is needed only when there are several;
  `--workspace`, `--project` and `--configuration` (default `Debug`) are also taken.
- `run` and `logs` take launch options: `--arg A` (repeatable), `--env NAME=value` (repeatable)
  and `--url myapp://settings`. `logs` relaunches the app, because `devicectl` cannot attach a
  console to one that is already running.
- `install` checks the signing first. It takes a build exported for Debugging or Release Testing
  (Ad Hoc), whose provisioning profile names the device, or for Enterprise (any device that trusts
  the certificate). It refuses a build made for App Store Connect. It reaches only devices paired with this Mac; for others, use
  `roamrun ota` or TestFlight.
- `screenshot` writes `./<name>-<date and time>.png` when no file is given. It was run with
  Xcode 26.3 and later; earlier versions were not tried.
- `--json` is taken by `devices`, `status` and `doctor`; `-v` by `up`. In `devices --json`, `ready`
  says only that the bridge is Ready or the device is on this Wi‑Fi; `status` also asks CoreDevice. A command rejects an option
  it does not take, with exit code 2. `roamrun --help` lists everything.

The app and the CLI never bridge the same device at once. Whichever starts second refuses, with
one exception: a bridge that is standing aside or has an error can be taken over, by the app's
Start button or by `roamrun up` (not by the app's automatic retries). A second `roamrun up` beside
a first one does not start: it exits 0 when the first has the device ready or standing aside, and
1 while the first is still starting or has an error.

The CLI uses the app's settings. Where you cannot reach the app's Settings window, such as over
SSH, change them with `defaults`:

```bash
defaults write io.github.mh-mobile.roamrun keepDebuggingOnCellular -bool true    # false to turn it off again
```

## Other tools over the bridge

While the bridge is Ready, Xcode's command-line tools reach the device as if it were on this
Wi-Fi. These were run that way:

```sh
xcrun devicectl device capture screenshot --device <udid> --destination shot.png   # what `roamrun screenshot` runs
xcrun devicectl device process launch --device <udid> <bundle-id>
xcodebuild test -destination id=<udid> …                                           # UI tests (XCUITest) on the device
xcrun devicectl device info files --device <udid> --domain-type appDataContainer --domain-identifier <bundle-id>
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <bundle-id> --source <path> --destination <local path>
xcrun devicectl device pasteboard copy --file image.png --type public.png --device <udid>
xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs     # crash logs (.ips)
```

`roamrun status <name>` shows the UDID. Tools built on XCUITest work too, more slowly than on the
same Wi-Fi. Two were tried over tethering: WebDriverAgent took about 2 seconds a tap;
agent-device took 25–35 seconds an action and missed taps in a windowed iPad app.

## Using it from an AI agent

Claude Code, Codex, Cursor and other agents can build, install and debug through RoamRun. A skill
teaches them how:

```sh
roamrun init                                  # add the skill to every agent found in ~ (.claude, .codex, .cursor, .gemini, .copilot, .devin)
roamrun init --client claude                  # or only to the ones you name (repeat --client)
```

`init` installs the skill that ships with your RoamRun, so the two match. After updating RoamRun,
run `roamrun init` again; `roamrun status` and `roamrun doctor` say so when an installed skill is
from another version. If another tool manages your skills, pin it to your RoamRun's release, for
example `gh skill install mh-mobile/RoamRun roamrun --pin "v$(roamrun --version | cut -d" " -f2)"`.

The skill covers connecting the device (`roamrun up -d`, then `roamrun status --wait 60 --json`
for the UDID), screenshots, and what only a person can do, such as unlocking the device. Exit codes
are 0 for ready, 1 for not ready or failed, and 2 for a usage error.
