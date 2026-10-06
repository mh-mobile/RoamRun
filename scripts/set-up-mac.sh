#!/bin/sh
# Sets a Mac up to see and operate a device through RoamRun: Tailscale, RoamRun, the agent
# skill, and a pairing made on another Mac. docs/another-mac.md is this, step by step.
#
#   TS_AUTHKEY=tskey-auth-… sh set-up-mac.sh [pairing.json]
#
# Each step is skipped where it is already done, so it can be run again. It asks for an
# administrator's password once, to start Tailscale. TS_AUTHKEY is needed only while this Mac
# isn't on the tailnet; `file:/path` is taken too, which keeps the key out of the process list.
set -eu

say() { printf '\n== %s\n' "$*"; }
die() { printf 'set-up-mac: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "RoamRun runs on macOS"
[ "$(uname -m)" = arm64 ] || die "RoamRun needs a Mac with Apple silicon"
command -v brew >/dev/null || die "Homebrew isn't installed: see https://brew.sh, then run this again"
pairing=${1-}
[ -z "$pairing" ] || [ -f "$pairing" ] || die "no such file: $pairing"

say "Tailscale"
command -v tailscale >/dev/null || brew install tailscale
if ! tailscale status >/dev/null 2>&1; then
    [ -n "${TS_AUTHKEY-}" ] || die "this Mac isn't on your tailnet: set TS_AUTHKEY (an auth key from the Tailscale admin console › Settings › Keys) and run this again"
    # The App Store's and the standalone Tailscale run their own service; Homebrew's needs starting.
    brew list --formula tailscale >/dev/null 2>&1 && sudo brew services start tailscale
    sudo tailscale up --auth-key="$TS_AUTHKEY"
fi
tailscale status | head -3

say "RoamRun"
brew list --cask roamrun >/dev/null 2>&1 || brew install --cask mh-mobile/tap/roamrun
roamrun --version
# The app holds the connection to the device: it has to run, in a session at this Mac's screen.
open -g -a RoamRun || die "RoamRun didn't open: is somebody logged in at this Mac's screen?"

say "The agent skill"
roamrun init || echo "(no agent's folder found in ~: roamrun init --client <name> installs it for one)"

if [ -n "$pairing" ]; then
    say "The pairing"
    # Once the app is there to take it. Not tried twice: an import that failed part-way says
    # what it left, and a second one isn't the answer to it.
    n=0
    until pgrep -f "RoamRun.app/Contents/MacOS/RoamRun$" >/dev/null; do
        n=$((n + 1))
        [ "$n" -lt 15 ] || die "RoamRun isn't running"
        sleep 1
    done
    sleep 3
    roamrun pairing import "$pairing"
fi

say "As it stands"
roamrun status || true
