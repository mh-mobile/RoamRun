# Installing and launching on a real device from GitHub Actions

<p align="center">English | <a href="ci.ja.md">日本語</a></p>

A GitHub Actions job on a GitHub-hosted runner can install an app on your iPhone and launch it over
Tailscale with the released `roamrunctl`, unchanged. Xcode Cloud can too:
[xcode-cloud.md](xcode-cloud.md); and Bitrise, with a Step: [bitrise.md](bitrise.md). Other CI
services weren't tried. There are two ways:

| | roamrunctl on the runner | A relay |
|---|---|---|
| Who talks to the device | the runner | a machine of yours, by `roamrunctl mcp --http` |
| What CI holds | a pairing (a key to the device) and a Tailscale OAuth client or auth key | a token for the relay and a Tailscale OAuth client or auth key |
| What the runner has to reach | the device, on its pairing port and the tunnel port it names | the relay, on one port |
| What has to keep running | nothing | the relay, started by you |

"Relay" on this page is a machine of yours that keeps the device's key and runs `roamrunctl mcp
--http`, not Tailscale's DERP relays. It reaches the device over Tailscale, as the runner does, so
it can be anywhere on your tailnet: only pairing it needs the device's Wi‑Fi (`pair control --to`),
or a key made elsewhere (`roamrun key create`, then `key import`). With a relay, the key never
leaves that machine. With roamrunctl on the runner, nothing of yours runs while the job does. A
repository can be set up for both.

Either way, whoever can run a workflow that reads the secrets can see and operate the device: with
the pairing key for as long as the pairing stands, with the relay's token while the relay runs (the
relay offers all its tools to a caller it lets in); stopping the relay, or restarting it with a new
token, takes the token back. The Tailscale OAuth client lets whoever holds it join your tailnet as
`tag:ci` until it is revoked in the admin console; an auth key, until it expires or is revoked.

The job here doesn't build or sign the app. CI needs an `.ipa` already signed for the device (a
development profile that lists it); `roamrunctl` checks the archive's shape, not its signature,
and installs it as it is. In the runs below, the job took the `.ipa` from a release of its own
repository (`gh release download`).

## With the action

The GitHub Action [mh-mobile/roamrun-action](https://github.com/mh-mobile/roamrun-action) does either
of the two ways in one step, placed after the Tailscale step. It downloads roamrunctl (0.9.0 by
default) from RoamRun's release, checks it against `roamrunctl-SHA256SUMS`, and by default installs
and launches: `key import -` and `install --launch` on the runner, or `install --relay … --launch`
through a relay, which runs 0.9.0 too. Before using it, set up what this page describes: the
[Tailscale tag and OAuth client](#tailscale-a-tag-and-an-oauth-client), and either
[a pairing for CI](#a-pairing-for-ci), given as the secret `key`, or [a relay](#a-relay).

```yaml
- uses: mh-mobile/roamrun-action@v1
  with:
    key: ${{ secrets.ROAMRUN_CI_KEY }}   # for a relay: relay:, token: and device: instead of key:
    ipa: build/MyApp.ipa
```

It runs on Linux and macOS runners. On macOS, with MagicDNS on, the Tailscale action set the
system's DNS to `100.100.100.100`; on the tailnet it was tried with, github.com then stopped
resolving. The action's README shows the line that puts the runner's own DNS back, between the two
steps. Its inputs (installing only, launching only, and more) and what was tried with it are in
[its README](https://github.com/mh-mobile/roamrun-action#readme).

What the action runs is the 0.9.0 form of [the runner's step](#the-runners-step) and
[the step that calls the relay](#the-step-that-calls-the-relay). The rest of this page is the setup,
and the runs made without the action.

## What was run

The CI runs with roamrunctl 0.8.1 were all on 2026-10-22 (UTC); those with 0.9.0 are
[below](#with-roamrunctl-090-from-ci).

- The device: an iPhone 15 Pro on iOS 27.0, unlocked, on a Wi‑Fi and a wireless charger. Whether
  its screen stayed on between runs wasn't recorded.
- CI: GitHub Actions, `ubuntu-24.04`, a job started by hand (`workflow_dispatch`) in a private
  repository, roamrunctl 0.8.1 from its release (`roamrunctl-linux-x86_64.tar.gz`).
- Relays, each on the device's Wi‑Fi (where they were paired): a MacBook Pro with roamrunctl 0.8.1
  from Homebrew, run in macOS's Terminal; and an Ubuntu 24.04 (arm64) virtual machine with
  roamrunctl 0.8.1 from the README's Linux install command.
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

The slow installs and the timeout fit an install over the app while it is in front on a device on
its wireless charger: in these runs the device lay on that charger, and each run ended by launching
the app. Later, from the Mac with the device's log streamed
(idevice's `syslog_relay`), it was seen why: iOS asked to end the app before replacing it, and the
request "failed due to termination resistance"; the install waited until the app left the front.
With roamrunctl 0.8.1 over the LAN, also on 2026-10-22 (UTC):

| Device | App | Install |
|---|---|---|
| on its wireless charger | in front | waited (122 s, until the app was ended by hand; 315 s timeouts otherwise) |
| off it | in front | 4 s |
| on it | not running | 5 s |

Whether the app was still in front when each run above began wasn't recorded (the screen may have
locked between runs, which takes the app out of the front), so the fast runs and the 48 s and 71 s
installs aren't explained by this. Cable charging wasn't tried. roamrunctl 0.9.0 ends the app's
running processes before it installs (#196): a build of that change, run from the Mac over the LAN,
installed in 4–5 s with the app in front on a device on its wireless charger. From CI, 0.9.0's
installs ran ([below](#with-roamrunctl-090-from-ci)), but that case wasn't set up for them. With
0.9.0, the app is ended from the start of the upload, and stays ended if the install fails, which
0.8.1 didn't do. With 0.8.1, don't leave the app in front on a device on its charger when a
job installs it: end it, or take the device off its charger.

### With roamrunctl 0.9.0, from CI

On 2026-10-24 (UTC), the same device, runner and private repository ran roamrunctl 0.9.0 before it
was released: the archive CI built from `release/0.9.0` at f21291c, put in that repository as a
release asset. The device was unlocked, on a Wi‑Fi; whether it lay on its charger, and whether the
app was in front when each install began, wasn't recorded. The relay was the MacBook Pro, with a
build of the same code, started from a shell on that Mac.

| Step | Took |
|---|---|
| The Mac's key (`roamrun key create`): `printf '%s' "$ROAMRUN_CI_KEY" \| roamrunctl key import - --as ci` | 3 s |
| `roamrunctl install ci app/RoamRunIntroducer.ipa --launch` | 18 s |
| The Linux machine's key (a file roamrunctl saved), the same way: `key import - --as ci-linux` | 3 s |
| `roamrunctl install ci-linux app/RoamRunIntroducer.ipa --launch` | 16 s |
| `roamrunctl install relay app/RoamRunIntroducer.ipa --relay "$RELAY" --launch` | 10 s (the install 5 s) |

Each step ended with the app launched. The relay logged four calls from `tag:ci`: the upload,
`install`, `install_status` and `launch`.

## What both ways need

### Tailscale: a tag and an OAuth client

On a tailnet with Tailnet Lock, use a signed auth key ([below](#or-an-auth-key)): a runner that
joined by an OAuth client was locked out.

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

The job joins the tailnet with
[tailscale/github-action](https://github.com/tailscale/github-action):

```yaml
- uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
```

#### Or an auth key

Under Settings › Keys, generate an auth key that is Reusable and Ephemeral, with the tag `tag:ci`
and a short expiry (and Pre-approved, where the tailnet requires device approval, which can't be on
with Tailnet Lock: not tried), and add it as the repository secret `TS_AUTHKEY`:

```yaml
- uses: tailscale/github-action@v4
  with:
    authkey: ${{ secrets.TS_AUTHKEY }}
```

The tag comes from the key (`tags:` is for an OAuth client). The action marks `authkey` as
deprecated in favour of an OAuth client: the run shows a warning and goes on. Run on 2026-10-26 from
GitHub-hosted runners: `ubuntu-24.04` and `macos-15` joined as `tag:ci` and reached the relay's
machine (both through DERP), and an `ubuntu-24.04` job installed and launched an app on
an iPhone Duo through a relay (roamrun-action v1, its roamrunctl 0.9.0; the relay a roamrunctl built
from 0.11.0's branch), which logged the upload, `install`, `install_status` and `launch` from
`tag:ci`.

On a tailnet with [Tailnet Lock](https://tailscale.com/docs/features/tailnet-lock), a node that
joins needs a signature from a trusted node before others take its connections. An auth key can be
signed once, with `tailscale lock sign <the key>` on a node that holds a trusted Tailnet Lock key;
the key it prints is the one CI is given
([Tailscale's guide](https://tailscale.com/docs/features/tailnet-lock#add-a-node-using-a-pre-signed-auth-key)).
A signed key passes Tailnet Lock as it is: whoever holds it adds a node the lock trusts, with no
signing node asked, until the key expires or is revoked. Keep its expiry short, and revoke it in the
admin console when it may have leaked. An OAuth client makes a new key at each run, which can't be
signed beforehand. Run on 2026-10-26 on
a tailnet with Tailnet Lock (two signing nodes): with a signed auth key, `ubuntu-24.04` and
`macos-15` joined as `tag:ci`, and the relay job installed and launched the app on the iPhone Duo as
above; with the OAuth client, the runner joined, but `tailscale lock status` on it said "This node
is LOCKED OUT by Tailnet Lock", and it didn't reach the relay's machine (`tailscale ping` timed out).

The action also takes `ping:`, hosts it waits for, up to 3 minutes, once it is up (a path direct
or relayed). The runs with roamrunctl 0.8.1 and 0.9.0 pinged in a step of their own (`tailscale ping -c 5`), which shows
whether a path is direct; the input wasn't tried.

With a policy that allows everything, the runner reaches every machine on your tailnet while the
job runs. To let it reach only what it needs, write grants for `tag:ci`. For a relay, that is its
one port. For roamrunctl on the runner, it is the device on TCP: the pairing port, one of
49152–49167, and the tunnel port, which the device names anew for each connection, with no range
known, so in effect any TCP port. Such a policy wasn't tried.

### The workflow

Installs to one device have to take turns (they aren't coordinated). A concurrency group on the
workflow makes its runs take turns:

```yaml
concurrency:
  group: iphone-15-pro
  cancel-in-progress: false
```

It groups runs, not jobs: two jobs of one run still go at the same time, so put a device's
installs in one job, or give each job the same group under `jobs.<id>.concurrency`. A group holds
within one repository: two repositories that use one device aren't kept apart. By default one run
at most waits in a group: a newer one cancels the one waiting; GitHub's `queue: max` lets up to 100
wait (not tried). A relay keeps one upload at a time, from whichever caller, so jobs for two devices
on one relay belong in one group too.

The runs above were started by hand. GitHub gives no secrets but `GITHUB_TOKEN` to a workflow run
on `pull_request` from a fork, and both ways need them. A `pull_request_target` workflow gets them
even for a fork's pull request: don't use these secrets in one.

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
list. A pairing made with `pair control --to` is announced under the machine's Tailscale name,
whatever `--as` says, so the Ubuntu machine's two pairings (this one and the relay's below) carry
the same name there; how the list tells them apart wasn't checked. One made with `roamrun key
create --as ci` is listed as "ci".

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

With 0.9.0, `key import -` reads the key from standard input and takes a file roamrunctl saved as
well, so either key goes in one way, with no temporary file for the secret (the device's file
roamrunctl saves holds the key, as before):
`printf '%s' "$ROAMRUN_CI_KEY" | "$rr" key import - --as ci`. It ran from CI with both keys, a file
`roamrun key create` wrote and a file roamrunctl saved
([above](#with-roamrunctl-090-from-ci)).

## A relay

### On the relay

1. Make a pairing of its own, on the device's Wi‑Fi (the relay itself can be anywhere on your
   tailnet afterwards):

   ```sh
   roamrunctl pair control --to iphone-15-pro --as phone
   ```

   On the device, under Settings › Privacy & Security › Developer Mode, select the relay's
   Tailscale name and enter the code the command prints. `phone` is the name the device is saved
   under on that machine; the server below and the job's calls name it so, while `--relay` names
   the machine. (The runs used `relay` for it; it is `phone` here so the two don't read alike.) On
   the MacBook Pro, the device never listed the Mac while the command ran in the Claude app's
   terminal, and did when it ran in macOS's Terminal: most likely the Claude app had no Local
   Network permission, which macOS gives per app (not checked).

2. Make a token, and store the same token as a secret:

   ```sh
   (umask 077 && mkdir -p ~/.config/roamrunctl && openssl rand -hex 32 > ~/.config/roamrunctl/ci-token)
   gh secret set RELAY_TOKEN --repo <owner>/<repo> < ~/.config/roamrunctl/ci-token
   ```

   For the Ubuntu relay, the same token was copied there from the Mac:
   `ssh admin@ubuntu-standin 'mkdir -p ~/.config/roamrunctl && umask 077 && cat > ~/.config/roamrunctl/ci-token' < ~/.config/roamrunctl/ci-token`.

3. Start the server and leave it running (Ctrl-C ends it):

   ```sh
   roamrunctl mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-install phone
   ```

   It prints its address (`http://<its Tailscale IPv4 address>:9090/mcp`) as it starts, and a line
   on standard error for each request: the time, the caller's address and who Tailscale says it
   is, the tool, the outcome and how long it took. Running it as a service (launchd, systemd)
   wasn't tried.

### The step that calls the relay

With roamrunctl 0.9.0 on the runner, one command uploads the `.ipa`, has the relay install it,
waits for that install and launches the app:

```yaml
- name: Install and launch through the relay
  env:
    ROAMRUNCTL_TOKEN: ${{ secrets.RELAY_TOKEN }}
    RELAY: "100.x.y.z:9090"
  run: |
    curl -sSfL "https://github.com/mh-mobile/RoamRun/releases/download/v0.9.0/roamrunctl-linux-x86_64.tar.gz" | tar xz
    ./roamrunctl-linux-x86_64/roamrunctl install phone app/MyApp.ipa --relay "$RELAY" --launch
```

`phone` is the device as the relay names it, and `RELAY` the address and port the server printed;
the token is the relay's. The command checks the sha256 the relay answers for the upload, and waits
for its own install by the id the relay gives it; `--timeout <s>` sets the most it waits in all (by
default, what the relay gives the upload and the install, and a minute more). The upload and the
install are in this one command, so in one job: only the caller that uploaded can install the
upload, by its Tailscale node, and a GitHub-hosted runner is a new node each job.

The relay has to run 0.9.0 too: by the code, with a 0.8.1 relay the install begins there, but the
command stops at that point, as the relay's answer carries no install id, and `--launch` doesn't
run. That pairing wasn't tried. This step ran from CI against a relay with 0.9.0
([above](#with-roamrunctl-090-from-ci)).

#### With 0.8.1: the script that ran

roamrunctl 0.8.1 has no command that asks a relay; it is only the relay's side (`mcp --http`). So
the runs above called the relay with curl: the job uploads the `.ipa`, starts the install, calls
`install_status` every 5 seconds until the install ends, and launches.

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
    call install "{\"device\":\"phone\",\"upload\":\"$id\",\"sha256\":\"$sha\"}"
    for _ in $(seq 1 120); do
      sleep 5
      call install_status '{"device":"phone"}' || exit 1
      jq -e '.result.content[0].text | test("^installing ")' "$RUNNER_TEMP/last.json" >/dev/null || break
    done
    jq -e '.result.content[0].text | test(" is installed on ")' "$RUNNER_TEMP/last.json" >/dev/null || exit 1
    call launch '{"device":"phone","bundle":"com.example.MyApp"}'
```

`initialize` isn't needed before a call. The loop gives up after 10 minutes, while the relay gives
an install 5 minutes plus 15 seconds a megabyte: for an `.ipa` over about 20 MB, lengthen it. What
the tools answer, and the limits on uploads, are in
[roamrunctl-reference.md](roamrunctl-reference.md#mcp-over-http).

The script checks only that the answer says " is installed on ": it doesn't tell its own install
from another caller's that ended just before. With 0.9.0, `install` answers with an id (`(install
<id>)`), and `install_status` given it as `"install": "<id>"` answers of that install alone; that
was run from the Mac, and from CI inside `install --relay` (which waits by that id).

## Not tried

- The device locked or asleep, on a cable charger, or an iPad. (A device on cellular alone doesn't
  take these connections: see the roamrunctl README.)
- A relay on Windows, or run as a service.
- macOS or Windows runners with this page's steps (the action ran on `macos-15`, as its README
  says), or a self-hosted runner.
- A Tailscale policy narrowed to `tag:ci`'s needs.
- An `.ipa` larger than 1 MB from CI, and whether the app's data survives an install over it.
- A Mac beside the device that CI reaches by SSH and that installs with `xcrun devicectl`.
- From CI with 0.9.0, an install with the app in front on a device on its wireless charger, set up
  on purpose (0.9.0 ends the app first: that ran from the Mac).
- tailscale/github-action's `ping:` input, and GitHub's `queue: max`.
