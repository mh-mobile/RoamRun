# Installing and launching on a real device from CI

A CI job on a GitHub-hosted runner can install an app on your iPhone and launch it with
`roamrunctl`, the released one, over Tailscale. There are two ways, and one setup can offer both:

| | roamrunctl on the runner | A relay beside the device |
|---|---|---|
| Who talks to the device | the runner | a machine of yours, by `roamrunctl mcp --http` |
| What CI holds | a pairing (a key to the device) and a Tailscale OAuth client | a token for the relay and a Tailscale OAuth client |
| What the runner has to reach | the device, on its pairing port and the tunnel port it names | the relay, on one port |
| What has to keep running | nothing | the relay, started by you |

The key never leaves your machine in the second way; the first needs no machine of yours. Both
were run, as below, on 2026-10-22 (UTC).

This page doesn't build or sign the app: CI needs an `.ipa` already signed for the device (a
development profile that lists it), which `roamrunctl` checks and installs as it is.

## What was run

- The device: an iPhone 15 Pro on iOS 27.0, unlocked with its screen on, on the home Wi‑Fi and a
  charger.
- CI: GitHub Actions, `ubuntu-24.04`, a job started by hand (`workflow_dispatch`) in a private
  repository, roamrunctl 0.8.1 from its release (`roamrunctl-linux-x86_64.tar.gz`).
- The relay: a MacBook Pro on the device's Wi‑Fi, roamrunctl 0.8.1 from Homebrew, in macOS's
  Terminal. Yours can be another machine; only this one was tried.
- The app: a 1 MB `.ipa`.
- Tailscale: the tailnet's policy allowed everything (the default); the runner joined with the
  tag `tag:ci`. In each run, its path to the device and to the relay began through a DERP server
  (Tokyo) and turned direct within a few seconds.

| Run | roamrunctl on the runner | The relay |
|---|---|---|
| both, the relay right after | import 3 s, install 15 s, launch 4 s | install timed out after 315 s |
| the relay alone | — | upload 1 s, install 6 s, launch 1 s |
| both again | import 3 s, install 9 s, launch 3 s | upload 2 s, install 71 s, launch 1 s |

Both times the relay's install was slow, it began within 3 seconds of the runner's launch. What
held it up on the device wasn't looked into. A device is to be driven from one machine at a time:
let one way, not both, serve a device in your workflow.

## What both ways need

### Tailscale: a tag and an OAuth client

1. In the tailnet's policy (Access controls), give CI a tag:

   ```json
   "tagOwners": {
     "tag:ci": ["autogroup:admin"]
   }
   ```

2. Settings › Trust credentials: a new OAuth client with **Keys › Auth Keys › Write** and the tag
   `tag:ci`, nothing else.
3. In the repository's Settings › Secrets and variables › Actions, as repository secrets:
   `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_SECRET`.

The job joins with [tailscale/github-action](https://github.com/tailscale/github-action):

```yaml
- uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
```

With a policy that allows everything, the runner reaches every machine on your tailnet while the
job runs. To let it reach only what it needs, write grants for `tag:ci`: the relay on its port, or
for roamrunctl on the runner, the device on TCP (the pairing port is one of 49152–49167, and the
tunnel port is another the device names for each connection). Such a policy wasn't tried.

### The workflow

One device serves one job at a time:

```yaml
concurrency:
  group: iphone-15-pro
  cancel-in-progress: false
```

The runs above were started by hand. GitHub doesn't give secrets to workflows run for pull
requests from forks.

## roamrunctl on the runner

### A pairing for CI

On a Mac with RoamRun, with the device on its Wi‑Fi, unlocked:

```sh
roamrun key create iPhone ci-key.json --as ci
```

Pick "ci" on the device under Settings › Privacy & Security › Developer Mode, and enter the code.
Then store the file as a secret and remove it:

```sh
gh secret set ROAMRUN_CI_KEY --repo <owner>/<repo> < ci-key.json && rm ci-key.json
```

The secret is a key to the device: anyone who can run a workflow that reads it, and reach the
device, can see and operate it. To take it back, remove "ci" from the device's list. A pairing
made without a Mac (`roamrunctl pair control --to` on a machine on the device's Wi‑Fi) wasn't
tried as a CI key.

### The steps

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

`key import` connects to the device before it keeps the pairing, and removes the file it read.
`umask 077` keeps the file written with the key the runner user's alone.

## A relay beside the device

### On the relay

1. A pairing of its own, made on the device's Wi‑Fi:

   ```sh
   roamrunctl pair control --to iphone-15-pro --as relay
   ```

   On the device: Settings › Privacy & Security › Developer Mode › the relay's Tailscale name, and
   the code that shows. On the MacBook Pro, run from the Claude app's terminal, the device never
   listed it; from macOS's Terminal it did. macOS asks about local network access per app.

2. A token, and the same token as a secret:

   ```sh
   mkdir -p ~/.config/roamrunctl && openssl rand -hex 32 > ~/.config/roamrunctl/ci-token && chmod 600 ~/.config/roamrunctl/ci-token
   gh secret set RELAY_TOKEN --repo <owner>/<repo> < ~/.config/roamrunctl/ci-token
   ```

3. The server, left running (Ctrl-C ends it):

   ```sh
   roamrunctl mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-install relay
   ```

   It writes a line for each request: when, the caller's address and tag, the tool, the outcome.
   Running it as a service (launchd, systemd) wasn't tried.

### The steps

The job uploads the `.ipa`, starts the install, asks how it goes every 5 seconds until it ends,
and launches. `RELAY` is the relay's Tailscale IPv4 address and port: the server listens there
only.

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

`initialize` isn't needed before a call. Only the runner that uploaded can install the upload, and
only by the sha256 it was answered. What the tools answer, and the limits on uploads, are in
[roamrunctl-reference.md](roamrunctl-reference.md#mcp-over-http).

## Not tried

- The device locked or asleep, on cellular alone, or an iPad.
- A relay on Linux or Windows, or run as a service.
- macOS or Windows runners, or a self-hosted runner.
- A Tailscale policy narrowed to `tag:ci`'s needs.
- An `.ipa` larger than 1 MB from CI, and whether the app's data survives an install over it.
- A Mac beside the device that CI reaches by SSH and that installs with `xcrun devicectl`.
