# Installing and launching on a real device from Bitrise

<p align="center">English | <a href="bitrise.ja.md">日本語</a></p>

A Bitrise build can install the app it archived on your iPhone and launch it, over Tailscale, with
the Bitrise Step [mh-mobile/bitrise-step-roamrun](https://github.com/mh-mobile/bitrise-step-roamrun).
Bitrise's Step Library had no Tailscale Step when this was written, so this Step joins the tailnet
itself: it installs Tailscale with Homebrew and runs it without root, in userspace, and gives
roamrunctl Tailscale's HTTP proxy into the tailnet (`ROAMRUNCTL_PROXY`, roamrunctl 0.10.0 or later).
Then it installs and launches in either of [the GitHub Actions guide](ci.md)'s two ways: with the
device's key on the build machine, or through a relay of yours. It runs on macOS stacks with macOS
15 or later (Xcode 16.3 or later), and stops on an older one.

```yaml
- xcode-archive@6:
    inputs:
      - distribution_method: development
      - automatic_code_signing: api-key
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.0.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - roamrun_key: $ROAMRUN_KEY
```

The Step isn't in Bitrise's Step Library: add it in `bitrise.yml` (the Workflow Editor's YAML view)
by its git URL and tag, as above. Through a relay, `relay_address`, `relay_token` and `device_name`
take the place of `roamrun_key`. `ipa_path` defaults to `$BITRISE_IPA_PATH`, which Xcode Archive &
Export sets when it runs before the Step; give it a path to install another `.ipa`. The Step's
README lists its inputs, what to prepare, and what it does.

## What to prepare

- The device as [roamrunctl](../Rust/roamrunctl/README.md#requirements) needs it: iOS 27 or later,
  Developer Mode on, Tailscale on it in your tailnet, on Wi‑Fi, unlocked once since it started.
- The app signed with a development profile that lists the device (the device in your team's
  device list): Xcode Archive & Export with `distribution_method: development`, and code signing
  set up on Bitrise. In the third run below: an App Store Connect API key (role
  Developer), added under the workspace's Settings › Integrations › App Store Connect and chosen
  under the project's Project settings › Integrations › Stores; and the Apple Development
  certificate as a `.p12` under Project settings › Code signing.
- A Tailscale auth key (admin console › Settings › Keys; an OAuth client wasn't tried): Reusable,
  Ephemeral, the tag `tag:ci`, a short expiry. The tag and the policy are as in
  [the GitHub Actions guide](ci.md#tailscale-a-tag-and-an-oauth-client); with the key on the build
  machine, the policy has to let the tag reach the device itself, not only a relay. On a tailnet
  with Tailnet Lock, sign the key first and give the signed one, which passes the lock for whoever
  holds it (as in that guide; run from GitHub
  Actions, not from Bitrise).
- The device's key ([a pairing for CI](ci.md#a-pairing-for-ci): the whole file `roamrun key create`
  wrote, or one `roamrunctl pair control` saved, in a Secret), or [a relay](ci.md#on-the-relay).
- Bitrise Secrets for the auth key, the device's key and the relay's token. The relay's address and
  the device's name needn't be Secrets: Bitrise hides every occurrence of a Secret's value in the
  log, so a name such as `relay` kept as a Secret puts `[REDACTED]` into roamrunctl's messages
  wherever the word appears.

One device takes one install at a time: keep builds that install on it from running together (the
Hobby plan used below allows one concurrent build).

Whoever can start a build, or push to a branch that builds, can read the Secrets (a Script Step can
print any of them). With the auth key they join your tailnet as `tag:ci` and reach whatever your
policy lets it reach (with a policy that allows everything, every machine); with the device's key
or the relay's token, they can operate the device. A pull request's build gets no Secrets unless
they are exposed to pull requests; with them empty, the Step stops and says so. Revoking the auth key, removing
the key's entry from the device's Developer Mode list, and restarting the relay with a new token
take each back.

## What was run

On 2026-10-24 (UTC), on bitrise.io (Hobby plan; stack Xcode 27.1, machine M2 Pro Medium), from a
private repository holding a minimal SwiftUI app, on a tailnet whose policy allowed
everything; the Step at its first commit (6e57e27), and roamrunctl 0.10.0 built from this
repository's `release/0.10.0`, given to the Step as `roamrunctl_path` (0.10.0 wasn't released yet);
an iPhone 15 Pro (iOS 27.0) at home, unlocked:

| Workflow | Result |
|---|---|
| The key on the build machine, an `.ipa` (21 KB) signed on a Mac and committed | installed and launched; the Step took 26 s |
| Through a relay (a MacBook Pro, Homebrew roamrunctl 0.9.0), the same `.ipa` | installed (5 s) and launched; the Step took 16 s |
| Xcode Archive & Export (as above), then the key on the build machine | installed and launched; the Step took 21 s |

Each time, Homebrew poured Tailscale 1.104.1's ready-built package and the machine joined as
`bitrise-<build number>`. After the first, the machine wasn't among the tailnet's machines, and a
look at the device showed the app in front. The relay logged the upload, `install`,
`install_status` and `launch` from `tag:ci`.

After the release, on 2026-10-24 (UTC), the first workflow ran once more with the Step's 1.0.0 and
no `roamrunctl_path`: it downloaded roamrunctl 0.10.0 from this repository's release, checked it
against `roamrunctl-SHA256SUMS`, and installed and launched the same `.ipa`; the Step took 27 s.

Not tried, among others the Step's README lists: a Step stopped by its timeout, the Bitrise CLI on a
Mac of your own, an iPad.
