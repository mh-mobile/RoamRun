# Xcode Cloud から実機にインストールして起動する

<p align="center"><a href="xcode-cloud.md">English</a> | 日本語</p>

Xcode Cloud のビルドから、アーカイブしたアプリを自分の iPhone にインストールして起動できます。Tailscale 越しに、手元の relay を経由します。プロジェクトにスクリプト（`ci_scripts/ci_post_xcodebuild.sh`）を置きます。このスクリプトが root なしで tailnet に参加し、relay の `roamrunctl mcp --http` を呼びます。使えるのは、[GitHub Actions の手順](ci.ja.md)のうち relay に頼むやり方だけです。Xcode Cloud の Tailscale は root なしで動くので、tailnet へは Tailscale の SOCKS5 プロキシを通ります。roamrunctl はプロキシを通せないので、スクリプトは relay を `curl` で呼びます。

ワークフローのビルドを始められる人や、その環境変数を読める人は、relay が動いていて Tailscale の鍵が有効な間、デバイスを操作できます。

## 実行した環境と結果

2026-10-24（UTC）に、Xcode のテンプレートから作ったアプリを入れた非公開のリポジトリで試しました。

- Xcode Cloud：macOS 27.0.1、Xcode 27.1。ワークフローは手動で開始し、アクションは Archive（iOS、Distribution Preparation は None）です。
- relay：自宅の MacBook Pro で、Homebrew で入れた roamrunctl 0.9.0 を動かしました。相手は iPhone 15 Pro（iOS 27.0）で、ロックを解除しておきました。
- スクリプト：下に載せたものを、そのまま使いました。

ビルドはアプリをアーカイブし、スクリプトがそれを iPhone にインストールして起動しました。relay のログでは、アップロードから起動まで 8 秒で、そのうちインストールが 5 秒です。より多くを出力する前の形のスクリプトでは、3 回の実行で次のことが分かりました。

- スクリプトの環境に、プロキシの設定はありませんでした（`HTTP_PROXY` などは未設定）。Tailscale の制御サーバーには、直接届きました。
- UDP は通りません。Tailscale は、DERP（中継サーバー）に HTTPS でつなぎました。いちばん近い DERP は、1 回はニューヨーク、ほかの 2 回はサンフランシスコとロサンゼルスでした。relay のマシンへの `tailscale ping` は DERP（東京）経由で返り、ほとんどは 130〜190 ms、何回かは 0.7〜1.8 秒でした。出力には「direct connection not established」と出ます。
- Tailscale は Homebrew の bottle（1.104.1）で入り、`tailscaled --tun=userspace-networking` は root なしで起動しました。
- Distribution Preparation が「None」でも、アーカイブは開発用に署名した `.ipa` を書き出しました（`CI_DEVELOPMENT_SIGNED_APP_PATH`）。そのプロファイルには 7 台の端末が入っていて、この iPhone も含まれていました。

## 必要なもの

### Tailscale：auth key

Tailscale の管理画面で Settings › Keys › Generate auth key を選び、次のように作ります。

- Reusable をオンにします。ビルドのたびに使うためです。
- Ephemeral をオンにします。ビルドのマシンがログアウトすると、tailnet から消えます。
- タグは `tag:ci` にします（[GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)と同じもの）。
- 有効期限は短くします。

GitHub Actions で使う OAuth クライアントは、ここでは試していません。

### relay

[GitHub Actions の手順](ci.ja.md#relay-で用意すること)と同じです。relay 自身のデバイスとのペアリングと、トークンを用意します。そのうえで、`roamrunctl mcp --http 9090 --allow tag:ci --token-file … --allow-install <デバイス>` を動かしたままにします。relay は roamrunctl 0.9.0 以降である必要があります。スクリプトは、relay が返すインストールの id で、そのインストールを待つからです。

### アプリ

Xcode Cloud には、読める Git リポジトリに入ったプロジェクトと、共有スキームが要ります。開発用に署名した `.ipa` は、Xcode Cloud の自動署名で作られます。そのプロファイルに、デバイスが入っている必要があります。今回の iPhone は、このチームで以前から開発に使っていたもので、プロファイルに入っていました。

### ワークフロー

- Start Conditions では、計算時間に気をつけます。ビルドは Xcode Cloud の計算時間を使います。Branch Changes などの条件があると、push のたびにビルドが始まります。手動でだけ始めるなら、**Manual Start** を残して、ほかを消します（上の実行では、Branch Changes を `main` に絞って残していました）。
- Actions は Archive（iOS）にし、Distribution Preparation は None にします。
- Environment › Environment Variables に、次の 4 つを入れます。

| 名前 | 値 | Secret |
|---|---|---|
| `TS_AUTHKEY` | auth key | **オン** |
| `RELAY` | relay の Tailscale のアドレスとポート（`100.x.y.z:9090`） | オフ |
| `RELAY_TOKEN` | relay のトークン | **オン** |
| `RELAY_DEVICE` | relay の側でのデバイスの名前 | オフ |

2 つの秘密の値は、必ず Secret にします。Xcode Cloud は、Secret でない変数を、値も含めてビルドのログの最初にすべて書き出します。今回の試しでも一度そうなったので、鍵を取り消し、トークンを作り直しました。

## スクリプト

`ci_scripts/ci_post_xcodebuild.sh` を `.xcodeproj` の隣に置き、実行できるようにして（`chmod +x`）、コミットします。Xcode Cloud は、`xcodebuild` のアクションのたびにこれを実行します。スクリプトが動くのは、アーカイブのあとだけです。

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

アップロードは、Tailscale の SOCKS5 プロキシ（`socks5h://127.0.0.1:1055`）を通ります。relay は、トークンと、呼び出し元が `tag:ci` であることを確かめます。スクリプトは relay の答えを 1 つずつ出力し、relay がエラーを返したときや、インストールが 10 分で終わらないときは、ビルドを失敗にします。最後に Tailscale からログアウトし、ephemeral のマシンは tailnet から消えます。

## 試していないこと

- Xcode Cloud の上で roamrunctl そのものを動かすこと。relay を使わずに、ビルドのマシンに鍵を置くこと。roamrunctl はプロキシを通せないためです。
- auth key の代わりに OAuth クライアントを使うこと。`tag:ci` に必要な先だけに絞った Tailscale のポリシー。
- Xcode Cloud のほかの Xcode や macOS の版。ほかの Distribution Preparation の設定。大きなアプリ。iPad。
- プルリクエストやスケジュールでビルドを始めること。
