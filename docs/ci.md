# Installing and launching on a real device from GitHub Actions

<p align="center">English | <a href="ci.ja.md">日本語</a></p>

A GitHub Actions job on a GitHub-hosted runner can install an app on your iPhone and launch it over
Tailscale with the released `roamrunctl`, unchanged. Other CI services weren't tried. There are two
ways:

| | roamrunctl on the runner | A relay beside the device |
|---|---|---|
| Who talks to the device | the runner | a machine of yours, by `roamrunctl mcp --http` |
| What CI holds | a pairing (a key to the device) and a Tailscale OAuth client | a token for the relay and a Tailscale OAuth client |
| What the runner has to reach | the device, on its pairing port and the tunnel port it names | the relay, on one port |
| What has to keep running | nothing | the relay, started by you |

With a relay, the key never leaves your machine. With roamrunctl on the runner, nothing of yours
runs while the job does. A repository can be set up for both. "Relay" on this page is that
machine beside the device, not Tailscale's DERP relays.

The job here doesn't build or sign the app. CI needs an `.ipa` already signed for the device (a
development profile that lists it); `roamrunctl` checks the archive's shape, not its signature,
and installs it as it is. In the runs below, the job took the `.ipa` from a release of its own
repository (`gh release download`).

## What was run

All on 2026-10-22 (UTC):

- The device: an iPhone 15 Pro on iOS 27.0, unlocked with its screen on, on a Wi‑Fi and a charger.
- CI: GitHub Actions, `ubuntu-24.04`, a job started by hand (`workflow_dispatch`) in a private
  repository, roamrunctl 0.8.1 from its release (`roamrunctl-linux-x86_64.tar.gz`).
- Relays, each on the device's Wi‑Fi: a MacBook Pro with roamrunctl 0.8.1 from Homebrew, run in
  macOS's Terminal; and an Ubuntu 24.04 (arm64) virtual machine with roamrunctl 0.8.1 from the
  README's Linux install command.
- Pairings for the runner: one made on a Mac with RoamRun, and one made on that Ubuntu machine.
- The app: a 1 MB `.ipa`.
- Tailscale: the tailnet's policy allowed everything; the runner joined with the tag `tag:ci`. In
  each run, its path to the device and to the relay began through a DERP server (Tokyo) and
  turned direct within a few seconds.

| Run | roamrunctl on the runner | The relay |
|---|---|---|
| both (the relay's step right after the runner's) | Mac's key: import 3 s, install 15 s, launch 4 s | Mac: upload 2 s, install timed out at its 315 s limit |
| the relay alone | — | Mac: upload 1 s, install 6 s, launch 1 s |
| both, again | Mac's key: import 3 s, install 9 s, launch 3 s | Mac: upload 2 s, install 71 s, launch 1 s |
| the runner alone | Linux's key: install 11 s, launch 3 s | — |
| the relay alone, 2 minutes after that | — | Linux: upload 2 s, install 48 s, launch 1 s |

The slow installs and the timeout fit an install over the app while it is in front on a charging
device: in these runs the device lay on its charger with its screen on, and nothing ended the app a
run had launched. Later, from the Mac with the device's log streamed
(idevice's `syslog_relay`), it was seen why: iOS asked to end the app before replacing it, and the
request "failed due to termination resistance"; the install waited until the app left the front.
With roamrunctl 0.8.1 over the LAN:

| Device | App | Install |
|---|---|---|
| charging | in front | waited (122 s, until the app was ended by hand; 315 s timeouts otherwise) |
| not charging | in front | 4 s |
| charging | not running | 5 s |

Whether the app was in front before each run above wasn't recorded, so not every fast run is
explained. roamrunctl 0.9.0 ends the app's running processes before it installs (#196): a build of
that change, run from the Mac over the LAN, installed in 4–5 s with the app in front on a charging
device. It wasn't run from CI. With 0.8.1, don't leave the app in front on a charging device when a
job installs it: end it, or leave the device off its charger.

## What both ways need

### Tailscale: a tag and an OAuth client

1. In the tailnet's policy (Access controls), give CI a tag:

   ```json
   "tagOwners": {
     "tag:ci": ["autogroup:admin"]
   }
   ```

2. Under Settings › Trust credentials, create an OAuth client with the scope
   **Keys › Auth Keys › Write** and the tag `tag:ci`, nothing else.
3. In the repository's Settings › Secrets and variables › Actions, add the repository secrets
   `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`.

The job joins the tailnet with [tailscale/github-action](https://github.com/tailscale/github-action):

```yaml
- uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
```

The action also takes `ping:`, hosts to `tailscale ping` once it is up, which shows in the log
whether the path to each is direct. The runs above pinged in a step of their own (`tailscale ping
-c 5`); the input wasn't tried.

With a policy that allows everything, the runner reaches every machine on your tailnet while the
job runs. To let it reach only what it needs, write grants for `tag:ci`. For a relay, that is its
one port. For roamrunctl on the runner, it is the device on TCP: the pairing port, one of
49152–49167, and the tunnel port, another one the device names for each connection. Such a policy
wasn't tried.

### The workflow

One device serves one job at a time:

```yaml
concurrency:
  group: iphone-15-pro
  cancel-in-progress: false
```

A group holds within one repository: two repositories that use one device aren't kept apart. And
one run at most waits in a group: a newer one cancels the one waiting.

The runs above were started by hand. GitHub gives no secrets to a workflow run on `pull_request`
from a fork, and both ways need them. A `pull_request_target` workflow gets them even for a fork's
pull request: don't use these secrets in one.

## roamrunctl on the runner

### A pairing for CI

**On a Mac with RoamRun**, with the device on its Wi‑Fi, unlocked (`iPhone` is the device's name
in RoamRun):

```sh
roamrun key create iPhone ~/ci-key.json --as ci
```

On the device, under Settings › Privacy & Security › Developer Mode, select "ci" and enter the
code the command prints. Then store the file as a secret and remove it:

```sh
gh secret set ROAMRUN_CI_KEY --repo <owner>/<repo> < ~/ci-key.json && rm ~/ci-key.json
```

**On a Linux machine with roamrunctl**, on the device's Wi‑Fi (`iphone-15-pro` is the device's
Tailscale name). A configuration folder of its own makes this a pairing of its own: roamrunctl
keeps the identity it pairs under in that folder.

```sh
export XDG_CONFIG_HOME=$(mktemp -d) && echo "$XDG_CONFIG_HOME" && roamrunctl pair control --to iphone-15-pro --as ci-linux
```

On the device, under Settings › Privacy & Security › Developer Mode, select the machine's
Tailscale name and enter the code the command prints. It refused at first, saying Tailscale
didn't reach the device directly: `tailscale ping iphone-15-pro` timed out on that machine,
although its LAN reached the device. After `sudo systemctl restart tailscaled` there, the ping went
direct and the pairing went through. The file was then stored as a secret from the Mac, over SSH,
and the folder removed:

```sh
ssh admin@ubuntu-standin cat /tmp/tmp.XXXXXXXXXX/roamrunctl/devices/ci-linux.json | gh secret set ROAMRUN_CI_KEY_LINUX --repo <owner>/<repo> && ssh admin@ubuntu-standin rm -rf /tmp/tmp.XXXXXXXXXX
```

Either secret is a key to the device: anyone who can run a workflow that reads it, and reach the
device, can see and operate it. To take it back, remove its name from the device's Developer Mode
list.

### The runner's step

These steps are as they ran, with roamrunctl 0.8.1, the release then. With the Mac's key,
`key import` takes it in; in 0.8.1 it accepts only a file `roamrun key create` wrote. It connects to
the device before it saves the pairing, and removes the file once the pairing is saved.

```yaml
- name: Install and launch
  env:
    ROAMRUN_CI_KEY: ${{ secrets.ROAMRUN_CI_KEY }}
  run: |
    curl -sSfL "https://github.com/mh-mobile/RoamRun/releases/download/v0.8.1/roamrunctl-linux-x86_64.tar.gz" | tar xz
    rr="$PWD/roamrunctl-linux-x86_64/roamrunctl"
    export XDG_CONFIG_HOME="$RUNNER_TEMP/config"
    umask 077
    printf '%s' "$ROAMRUN_CI_KEY" > "$RUNNER_TEMP/ci-key.json"
    "$rr" key import "$RUNNER_TEMP/ci-key.json" --as ci
    "$rr" install ci app/MyApp.ipa
    "$rr" launch ci com.example.MyApp
```

With the Linux machine's key, the file is what roamrunctl saves for a device, so it is put where
roamrunctl keeps devices, under the name inside it:

```yaml
- name: Install and launch
  env:
    ROAMRUN_CI_KEY_LINUX: ${{ secrets.ROAMRUN_CI_KEY_LINUX }}
  run: |
    curl -sSfL "https://github.com/mh-mobile/RoamRun/releases/download/v0.8.1/roamrunctl-linux-x86_64.tar.gz" | tar xz
    rr="$PWD/roamrunctl-linux-x86_64/roamrunctl"
    export XDG_CONFIG_HOME="$RUNNER_TEMP/config"
    umask 077
    mkdir -p "$XDG_CONFIG_HOME/roamrunctl/devices"
    printf '%s' "$ROAMRUN_CI_KEY_LINUX" > "$XDG_CONFIG_HOME/roamrunctl/devices/ci-linux.json"
    "$rr" install ci-linux app/MyApp.ipa
    "$rr" launch ci-linux com.example.MyApp
```

`XDG_CONFIG_HOME` puts what roamrunctl saves in the job's temporary folder. `umask 077` makes the
files written with the key readable by the runner's user alone; roamrunctl refuses a saved device
that others can read. `app/MyApp.ipa` and `com.example.MyApp` stand for your app and its bundle
identifier.

With 0.9.0 (not run from CI), `key import -` reads the key from standard input and takes a file
roamrunctl saved as well, so either key goes in one way, with no file written for it:
`printf '%s' "$ROAMRUN_CI_KEY" | "$rr" key import - --as ci`.

## A relay beside the device

### On the relay

1. Make a pairing of its own, on the device's Wi‑Fi:

   ```sh
   roamrunctl pair control --to iphone-15-pro --as relay
   ```

   On the device, under Settings › Privacy & Security › Developer Mode, select the relay's
   Tailscale name and enter the code the command prints. `relay` is the name the device is saved
   under on that machine; the server below and the job's calls name it so. On the MacBook Pro,
   the device never listed the Mac while the command ran in the Claude app's terminal. It did when
   the command ran in macOS's Terminal.

2. Make a token, and store the same token as a secret:

   ```sh
   (umask 077 && mkdir -p ~/.config/roamrunctl && openssl rand -hex 32 > ~/.config/roamrunctl/ci-token)
   gh secret set RELAY_TOKEN --repo <owner>/<repo> < ~/.config/roamrunctl/ci-token
   ```

   For the Ubuntu relay, the same token was copied there from the Mac:
   `ssh admin@ubuntu-standin 'mkdir -p ~/.config/roamrunctl && umask 077 && cat > ~/.config/roamrunctl/ci-token' < ~/.config/roamrunctl/ci-token`.

3. Start the server and leave it running (Ctrl-C ends it):

   ```sh
   roamrunctl mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-install relay
   ```

   It prints its address (`http://<its Tailscale IPv4 address>:9090/mcp`) as it starts, and a line
   on standard error for each request: the time, the caller's address and who Tailscale says it
   is, the tool, the outcome and how long it took. Running it as a service (launchd, systemd)
   wasn't tried.

### The step that calls the relay

The job uploads the `.ipa`, starts the install, calls `install_status` every 5 seconds until the
install ends, and launches. `RELAY` is the address and port the server printed. The upload and the
install have to be in one job: only the caller that uploaded can install the upload, by its
Tailscale node, and a GitHub-hosted runner is a new node each job.

```yaml
- name: Install and launch through the relay
  env:
    RR_TOKEN: ${{ secrets.RELAY_TOKEN }}
    RELAY: "100.x.y.z:9090"
  run: |
    token=$(printf '%s' "$RR_TOKEN" | tr -d '\r\n')
    base="http://$RELAY"
    # One tools/call; 503 (Tailscale didn't say who this is) is tried again.
    call() {
      local out code body
      for _ in 1 2 3 4 5; do
        out=$(printf '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$1" "$2" |
          curl -sS --max-time 600 -w '\n%{http_code}' -H 'Content-Type: application/json' -H "Authorization: Bearer $token" --data-binary @- "$base/mcp") || true
        code=${out##*$'\n'}; body=${out%$'\n'*}
        [ "$code" = 503 ] && { sleep 3; continue; }
        echo "$1: HTTP $code: $(printf '%s' "$body" | jq -c '.result.content | map(.text)' 2>/dev/null || printf '%s' "$body" | head -c 400)"
        [ "$code" = 200 ] && ! printf '%s' "$body" | jq -e '.result.isError == true' >/dev/null && { printf '%s' "$body" > "$RUNNER_TEMP/last.json"; return 0; }
        return 1
      done
      return 1
    }
    call devices '{}'
    up=$(curl -sS --max-time 2100 -w '\n%{http_code}' -H "Authorization: Bearer $token" -T app/MyApp.ipa "$base/upload") || true
    [ "${up##*$'\n'}" = 200 ] || { echo "${up%$'\n'*}"; exit 1; }
    id=$(printf '%s' "${up%$'\n'*}" | jq -r .upload); sha=$(printf '%s' "${up%$'\n'*}" | jq -r .sha256)
    [ "$sha" = "$(sha256sum app/MyApp.ipa | cut -d' ' -f1)" ] || { echo "the relay's sha256 differs"; exit 1; }
    call install "{\"device\":\"relay\",\"upload\":\"$id\",\"sha256\":\"$sha\"}"
    for _ in $(seq 1 120); do
      sleep 5
      call install_status '{"device":"relay"}' || exit 1
      jq -e '.result.content[0].text | test("^installing ")' "$RUNNER_TEMP/last.json" >/dev/null || break
    done
    jq -e '.result.content[0].text | test(" is installed on ")' "$RUNNER_TEMP/last.json" >/dev/null || exit 1
    call launch '{"device":"relay","bundle":"com.example.MyApp"}'
```

`initialize` isn't needed before a call. The loop gives up after 10 minutes, while the relay gives
an install 5 minutes plus 15 seconds a megabyte: for an `.ipa` over about 20 MB, lengthen it. What
the tools answer, and the limits on uploads, are in
[roamrunctl-reference.md](roamrunctl-reference.md#mcp-over-http).

With 0.9.0, `roamrunctl install <device> app/MyApp.ipa --relay <address>:<port> --launch`, with the
token in `ROAMRUNCTL_TOKEN` or `--token-file`, does the upload, the install, the wait and the launch
in place of this script. It was run from the Mac against a relay on the same Mac, not from CI.

## Not tried

- The device locked or asleep, or an iPad. (A device on cellular alone doesn't take these
  connections: see the roamrunctl README.)
- A relay on Windows, or run as a service.
- macOS or Windows runners, or a self-hosted runner.
- A Tailscale policy narrowed to `tag:ci`'s needs.
- An `.ipa` larger than 1 MB from CI, and whether the app's data survives an install over it.
- A Mac beside the device that CI reaches by SSH and that installs with `xcrun devicectl`.
- roamrunctl 0.9.0 from CI: `key import -`, `install --relay … --launch`, and the app ended before
  an install.
