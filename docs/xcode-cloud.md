# Installing and launching on a real device from Xcode Cloud

<p align="center">English | <a href="xcode-cloud.ja.md">日本語</a></p>

An Xcode Cloud build can install the app it archived on your iPhone and launch it, through a relay
of yours, over Tailscale. A script in the project (`ci_scripts/ci_post_xcodebuild.sh`) joins the
tailnet and calls the relay's `roamrunctl mcp --http`. It runs Tailscale without root, in userspace,
so it reaches the tailnet through Tailscale's SOCKS5 proxy; roamrunctl 0.9.0 has no way to go
through a proxy, so of [the GitHub Actions guide](ci.md)'s two ways this is the relay's, with
`curl` calling the relay. From 0.10.0, roamrunctl goes through an HTTP proxy, and both ways work:
[With roamrunctl itself](#with-roamrunctl-itself-0100).

Whoever holds the auth key can join your tailnet as `tag:ci` and reach whatever your policy lets
that tag reach (with a policy that allows everything, every machine: see
[the GitHub Actions guide](ci.md#tailscale-a-tag-and-an-oauth-client)); with the relay's token as
well, they can operate the device while the relay runs. Both are in the workflow's environment, so
whoever can start its builds, or commit to a branch it builds (a script can print any variable),
can too. Revoking the key in the admin console and restarting the relay with a new token ends it.

## What was run

On 2026-10-24 (UTC), from a private repository holding a minimal SwiftUI app (its project made
with XcodeGen, with a shared scheme):

- Xcode Cloud: macOS 27.0.1, Xcode 27.1, builds started by hand, with an Archive action (iOS,
  Distribution Preparation: None).
- The relay: a MacBook Pro with roamrunctl 0.9.0 from Homebrew, serving an iPhone 15 Pro (iOS 27.0).
- The script below, as it is.

The build archived the app, and the script installed and launched it on the iPhone: 8 s from the
upload to the launch, the install 5 s of it, by the relay's log. Three runs of an earlier form of
the script, which printed more (two after a Build action, one after an Archive), showed:

- No proxy settings in the script's environment (`HTTP_PROXY` and the like were unset), and
  Tailscale's control server reached directly.
- UDP blocked (netcheck), so Tailscale connected through its DERP relay servers (the nearest was New
  York in one run, San Francisco and Los Angeles in the others). `tailscale ping` to the relay's
  machine was answered through DERP (Tokyo), mostly in about 130–190 ms, a few times in 0.7–1.8 s,
  and printed "direct connection not established".
- Tailscale 1.104.1 from Homebrew (a bottle), and `tailscaled --tun=userspace-networking` started
  without root.
- In the run with an Archive, Distribution Preparation "None" still exported a development-signed
  `.ipa` (`CI_DEVELOPMENT_SIGNED_APP_PATH`). Its profile listed 7 devices, the iPhone among them.

## What it needs

### Tailscale: an auth key

In the Tailscale admin console, Settings › Keys › Generate auth key: **Reusable** (each build
uses it), **Ephemeral** (the build's machine leaves the tailnet when it logs out), the tag `tag:ci`
(set up as in [the GitHub Actions guide](ci.md#tailscale-a-tag-and-an-oauth-client)), and a short
expiry. An OAuth client, which GitHub Actions uses, wasn't tried here.

### The relay

As in [the GitHub Actions guide](ci.md#on-the-relay): a pairing of the relay's own with the
device, a token, and `roamrunctl mcp --http 9090 --allow tag:ci --token-file … --allow-install
<device>` left running. The relay has to run roamrunctl 0.9.0 or later: the script waits for its
install by the id the relay gives it.

### The app

Xcode Cloud needs the project in a Git repository it can read, and a shared scheme. The
development-signed `.ipa` is made with Xcode Cloud's automatic signing, and its profile has to list
the device. The iPhone here had been used for development with the team before, and was listed.

### The workflow

- **Start Conditions**: builds use your Xcode Cloud compute hours. A condition such as Branch
  Changes starts a build at each push; to start it by hand only, keep **Manual Start** and remove
  the others (in the runs above, Branch Changes stayed, limited to `main`).
- **Actions**: Archive (iOS), Distribution Preparation: None.
- **Environment › Environment Variables**:

| Name | Value | Secret |
|---|---|---|
| `TS_AUTHKEY` | the auth key | **on** |
| `RELAY` | the relay's Tailscale address and port, `100.x.y.z:9090` (the server prints it as it starts) | off |
| `RELAY_TOKEN` | the relay's token | **on** |
| `RELAY_DEVICE` | the device as the relay names it: the name given to `--allow-install` | off |

Mark the two secrets as Secret: Xcode Cloud prints every variable that isn't, values included, at
the start of the build's log. That happened once in these runs, and the key was revoked and the
token made anew.

## The script

`ci_scripts/ci_post_xcodebuild.sh`, next to the `.xcodeproj`, executable (`chmod +x`), committed.
Xcode Cloud runs it after each `xcodebuild` action; it acts after an archive only.

```bash
#!/bin/bash
# After an archive on Xcode Cloud: install the development-signed .ipa on a device through a relay
# (roamrunctl mcp --http on a machine of yours) and launch it.
# Workflow environment: TS_AUTHKEY (secret), RELAY (its address and port, 100.x.y.z:9090),
# RELAY_TOKEN (secret), RELAY_DEVICE (the device as the relay names it).
set -euo pipefail
[ "${CI_XCODEBUILD_ACTION:-}" = archive ] || exit 0
ipa=$(find "${CI_DEVELOPMENT_SIGNED_APP_PATH:-/nonexistent}" -maxdepth 1 -name '*.ipa' | head -1)
[ -n "$ipa" ] || { echo "no development-signed .ipa in CI_DEVELOPMENT_SIGNED_APP_PATH"; exit 1; }

# Tailscale without root: userspace networking, and its SOCKS5 server to reach the tailnet.
HOMEBREW_NO_AUTO_UPDATE=1 brew install tailscale > /dev/null
bin=$(brew --prefix)/bin
t=$(mktemp -d /tmp/ts.XXXXXX) # short: a unix socket's path must stay under 104 bytes
"$bin/tailscaled" --tun=userspace-networking --socket="$t/sock" --statedir="$t/state" \
  --socks5-server=127.0.0.1:1055 > "$t/log" 2>&1 &
daemon=$!
ts() { "$bin/tailscale" --socket="$t/sock" "$@"; }
trap 'ts logout > /dev/null 2>&1; kill "$daemon"; rm -rf "$t"' EXIT
for _ in $(seq 20); do [ -S "$t/sock" ] && break; sleep 1; done
ts up --auth-key="$TS_AUTHKEY" --hostname="xcode-cloud-$CI_BUILD_NUMBER" --accept-dns=false --timeout=120s

token=$(printf '%s' "$RELAY_TOKEN" | tr -d '\r\n')
relay() { curl -sS --retry 3 -x socks5h://127.0.0.1:1055 -H "Authorization: Bearer $token" "$@"; }
# One of the relay's tools: its answer goes to the log and to stdout; an error the relay gives fails it.
call() {
  local out
  out=$(relay --max-time 60 -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" \
    "http://$RELAY/mcp")
  echo "$1: $out" >&2
  printf '%s' "$out"
  ! printf '%s' "$out" | grep -q -e '"isError":true' -e '"error":'
}
field() { sed -E "s/.*\"$1\":\"([^\"]+)\".*/\1/"; }

up=$(relay --fail-with-body --max-time 1800 -T "$ipa" "http://$RELAY/upload")
sha=$(printf '%s' "$up" | field sha256)
[ "$sha" = "$(shasum -a 256 "$ipa" | cut -d' ' -f1)" ] || { echo "the relay's sha256 differs: $up"; exit 1; }
begun=$(call install "{\"device\":\"$RELAY_DEVICE\",\"upload\":\"$(printf '%s' "$up" | field upload)\",\"sha256\":\"$sha\"}")
id=$(printf '%s' "$begun" | sed -nE 's/.*\(install ([0-9a-f]+)\).*/\1/p')
[ -n "$id" ] || { echo "the relay gave no install id: it has to run roamrunctl 0.9.0 or later"; exit 1; }
# Until it ends: a failed install is an error, which stops this.
for _ in $(seq 120); do
  sleep 5
  status=$(call install_status "{\"device\":\"$RELAY_DEVICE\",\"install\":\"$id\"}")
  printf '%s' "$status" | grep -q '"text":"installing ' || break
done
printf '%s' "$status" | grep -q ' is installed on ' || { echo "not installed in 10 minutes"; exit 1; }
call launch "{\"device\":\"$RELAY_DEVICE\",\"bundle\":\"$CI_BUNDLE_ID\"}" > /dev/null
```

Every call to the relay goes through Tailscale's SOCKS5 proxy (`socks5h://127.0.0.1:1055`); the
relay checks the token and that the caller is `tag:ci`. The script prints the relay's answers to
`install`, `install_status` and `launch` (the upload's only when its sha256 differs), and fails the
build when the relay gives an error or the install doesn't end in 10 minutes. At its end it logs out
of Tailscale, so that the ephemeral machine leaves the tailnet.

## With roamrunctl itself (0.10.0)

From 0.10.0, roamrunctl goes through the HTTP proxy `ROAMRUNCTL_PROXY` names, and Tailscale in
userspace gives one into the tailnet (`--outbound-http-proxy-listen`). The script can then run
roamrunctl itself: through the relay, or with the device's key on the build machine and no relay.
A build of that change ran both on Xcode Cloud on 2026-10-24, from the same repository, app,
device and relay as above. Its script differed from the one above in these lines, and the part
that calls the relay with `curl` (from `token=` to the end) was replaced by roamrunctl:

```bash
rr="$CI_PRIMARY_REPOSITORY_PATH/bin/roamrunctl"
"$bin/tailscaled" --tun=userspace-networking --socket="$t/sock" --statedir="$t/state" \
  --outbound-http-proxy-listen=127.0.0.1:1056 > "$t/log" 2>&1 &
# … tailscale up, as above …
export ROAMRUNCTL_PROXY=http://127.0.0.1:1056

# Through the relay.
ROAMRUNCTL_TOKEN="$RELAY_TOKEN" "$rr" install "$RELAY_DEVICE" "$ipa" --relay "$RELAY" --launch

# With the key here, no relay.
export XDG_CONFIG_HOME="$t/config"
( umask 077 && printf '%s' "$ROAMRUN_KEY" | "$rr" key import - --as dev )
"$rr" install dev "$ipa" --launch
"$rr" look dev "$t/look.png"
```

- Through the relay: installed and launched, 10 s.
- With the key, no relay: after `key import`, installed and launched in 14 s, and the look took
  8 s. The key was made on a Mac with RoamRun (`roamrun key create iPhone ~/xcc-key.json --as
  xcc`) and given as the Secret variable `ROAMRUN_KEY`.
- `$rr` was that build of roamrunctl, committed to the repository (`bin/roamrunctl`). With 0.10.0
  released, a script would download the archive from RoamRun's release instead, as the GitHub
  Action does; that wasn't run.

With the key on the build machine, the variables are `TS_AUTHKEY` and `ROAMRUN_KEY`, both Secret;
`RELAY`, `RELAY_TOKEN` and `RELAY_DEVICE` aren't used. The tailnet's policy has to let `tag:ci`
reach the device itself, on the ports [the GitHub Actions guide](ci.md#tailscale-a-tag-and-an-oauth-client)
names, not only the relay's port. There is no relay to stop and no token to change: whoever can
read `ROAMRUN_KEY` and reach the device can operate it until its name is removed from the device's
Developer Mode list (Settings › Privacy & Security › Developer Mode).

## Not tried

- A script that downloads roamrunctl 0.10.0 from its release (a build of the change was committed
  instead).
- An OAuth client instead of an auth key; a Tailscale policy narrowed to `tag:ci`'s needs.
- Other Xcode or macOS versions on Xcode Cloud, other Distribution Preparation settings, a larger
  app, an iPad.
- Starting builds from pull requests or schedules.
