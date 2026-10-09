#!/bin/sh
# Puts roamrunctl from a RoamRun release in ~/.local/bin (Linux):
#   curl -fsSL https://raw.githubusercontent.com/mh-mobile/RoamRun/main/scripts/install-roamrunctl.sh | sh
# ROAMRUNCTL_VERSION picks a release other than the newest, ROAMRUNCTL_BIN another folder;
# ROAMRUNCTL_FROM, where a release's files are (for trying archives before they are released).
set -eu
repo=mh-mobile/RoamRun
case "$(uname -s)" in
    Linux) ;;
    Darwin) echo "On a Mac: brew install mh-mobile/tap/roamrunctl" >&2; exit 1 ;;
    *) echo "roamrunctl has no build for $(uname -s): see Rust/roamrunctl/README.md for building it" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) echo "roamrunctl has no build for $(uname -m): see Rust/roamrunctl/README.md for building it" >&2; exit 1 ;;
esac
version=${ROAMRUNCTL_VERSION:-$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)}
[ -n "$version" ] || { echo "couldn't learn which release is the newest: set ROAMRUNCTL_VERSION" >&2; exit 1; }
name=roamrunctl-$version-linux-$arch
from=${ROAMRUNCTL_FROM:-https://github.com/$repo/releases/download/v$version}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$name.tar.gz" "$from/$name.tar.gz" || { echo "release $version has no $name.tar.gz" >&2; exit 1; }
curl -fsSL -o "$tmp/sums" "$from/roamrunctl-$version-SHA256SUMS"
# What came is what the release lists: not a page in its place, nor half of it.
(cd "$tmp" && grep " $name.tar.gz\$" sums | sha256sum -c - >/dev/null) || { echo "$name.tar.gz isn't the file the release lists" >&2; exit 1; }
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
bin=${ROAMRUNCTL_BIN:-$HOME/.local/bin}
mkdir -p "$bin"
install -m 755 "$tmp/$name/roamrunctl" "$bin/roamrunctl"
echo "roamrunctl $version is in $bin"
case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "$bin isn't on your PATH: add it, or run $bin/roamrunctl" ;;
esac
