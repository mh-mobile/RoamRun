# Xcode Cloud から実機にインストールして起動する

<p align="center"><a href="xcode-cloud.md">English</a> | 日本語</p>

Xcode Cloud のビルドから、アーカイブしたアプリを自分の iPhone にインストールして起動できます。Tailscale 越しに、手元の relay を経由します。プロジェクトにスクリプト（`ci_scripts/ci_post_xcodebuild.sh`）を置きます。このスクリプトが tailnet に参加し、relay の `roamrunctl mcp --http` を呼びます。スクリプトは Tailscale を root なしの userspace モードで動かすので、tailnet へは Tailscale の SOCKS5 プロキシを通ります。roamrunctl 0.9.0 にはプロキシを通す方法がありません。そのため、[GitHub Actions の手順](ci.ja.md)の 2 つのやり方のうち relay に頼むほうを使い、relay は `curl` で呼びます。0.10.0 からは roamrunctl が HTTP プロキシを通せるので、どちらのやり方も使えます（[roamrunctl そのものを使う](#roamrunctl-そのものを使う0100)）。

auth key を持つ人は、`tag:ci` として tailnet へ参加でき、ポリシーがそのタグに許す範囲のマシンへ届きます。ポリシーが「すべて許可」なら、すべてのマシンです（[GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)を参照）。relay のトークンもあれば、relay が動いている間、デバイスを操作できます。どちらもワークフローの環境に入ります。そのため、ビルドを始められる人や、ワークフローがビルドするブランチにコミットできる人も、同じことができます。スクリプトは、どの変数も出力できるからです。止めるには、管理画面で鍵を取り消し、新しいトークンで relay を起動し直します。

## 実行した環境と結果

2026-10-24（UTC）に、最小限の SwiftUI アプリを入れた非公開のリポジトリで試しました。プロジェクトは XcodeGen で作り、共有スキームを付けています。

- Xcode Cloud：macOS 27.0.1、Xcode 27.1。ビルドは手動で開始し、アクションは Archive（iOS、Distribution Preparation は None）です。
- relay：MacBook Pro で、Homebrew で入れた roamrunctl 0.9.0 を動かしました。相手は iPhone 15 Pro（iOS 27.0）です。
- スクリプト：下に載せたものを、そのまま使いました。

ビルドはアプリをアーカイブし、スクリプトがそれを iPhone にインストールして起動しました。relay のログでは、アップロードから起動まで 8 秒で、そのうちインストールが 5 秒です。より多くを出力する前の形のスクリプトでは、3 回の実行（2 回は Build のあと、1 回は Archive のあと）で次のことが分かりました。

- スクリプトの環境に、プロキシの設定はありませんでした（`HTTP_PROXY` などは未設定）。Tailscale の制御サーバーには、直接届きました。
- UDP は通りませんでした（netcheck）。Tailscale は、DERP（中継サーバー）を経由してつなぎました。いちばん近い DERP は、1 回はニューヨーク、ほかの 2 回はサンフランシスコとロサンゼルスでした。relay のマシンへの `tailscale ping` は DERP（東京）経由で返り、ほとんどは約 130〜190 ms、何回かは 0.7〜1.8 秒でした。出力には「direct connection not established」と出ました。
- Tailscale は Homebrew の bottle（1.104.1）で入り、`tailscaled --tun=userspace-networking` は root なしで起動しました。
- Archive の回では、開発用に署名した `.ipa` が書き出されました（`CI_DEVELOPMENT_SIGNED_APP_PATH`）。Distribution Preparation は「None」のままです。そのプロファイルには 7 台の端末が入っていて、この iPhone も含まれていました。

## 必要なもの

### Tailscale：auth key

Tailscale の管理画面で Settings › Keys › Generate auth key を選び、次のように作ります。

- Reusable をオンにします。ビルドのたびに使うためです。
- Ephemeral をオンにします。ビルドのマシンがログアウトすると、tailnet から消えます。
- タグは `tag:ci` にします（[GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)と同じもの）。
- 有効期限は短くします。

Tailnet Lock を有効にした tailnet では、鍵を先に署名し、署名した鍵を渡します。署名した鍵は、持つ人なら誰でも Tailnet Lock を通れます。やり方は [GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)にあります。GitHub Actions からは試しましたが、Xcode Cloud からは試していません。

GitHub Actions で使う OAuth クライアントは、ここでは試していません。

### relay

[GitHub Actions の手順](ci.ja.md#relay-で用意すること)と同じです。relay 自身のデバイスとのペアリングと、トークンを用意します。そのうえで、`roamrunctl mcp --http 9090 --allow tag:ci --token-file … --allow-install <デバイス>` を動かしたままにします。relay は roamrunctl 0.9.0 以降である必要があります。スクリプトは、relay が返すインストールの id で、そのインストールを待つからです。

### アプリ

Xcode Cloud には、読める Git リポジトリに入ったプロジェクトと、共有スキームが要ります。開発用に署名した `.ipa` は、Xcode Cloud の自動署名で作られます。そのプロファイルに、デバイスが入っている必要があります。今回の iPhone は、このチームで以前から開発に使っていたもので、プロファイルに入っていました。

### ワークフロー

- Start Conditions：ビルドは Xcode Cloud の計算時間を使います。Branch Changes などの条件があると、push のたびにビルドが始まります。手動でだけ始めるなら、**Manual Start** を残して、ほかを消します（上の実行では、Branch Changes を `main` に絞って残していました）。
- Actions は Archive（iOS）にし、Distribution Preparation は None にします。
- Environment › Environment Variables に、次の 4 つを入れます。

| 名前 | 値 | Secret |
|---|---|---|
| `TS_AUTHKEY` | auth key | **オン** |
| `RELAY` | relay の Tailscale のアドレスとポート（`100.x.y.z:9090`。サーバーが起動時に表示します） | オフ |
| `RELAY_TOKEN` | relay のトークン | **オン** |
| `RELAY_DEVICE` | relay の側でのデバイスの名前（`--allow-install` に渡した名前） | オフ |

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

relay への呼び出しは、どれも Tailscale の SOCKS5 プロキシ（`socks5h://127.0.0.1:1055`）を通ります。relay は、トークンと、呼び出し元が `tag:ci` であることを確かめます。スクリプトは、`install`、`install_status`、`launch` への relay の答えを出力します（アップロードの答えは、sha256 が違うときだけです）。relay がエラーを返したときや、インストールが 10 分で終わらないときは、ビルドを失敗にします。最後に Tailscale からログアウトし、ephemeral のマシンが tailnet から消えるようにします。

## roamrunctl そのものを使う（0.10.0）

0.10.0 からは、roamrunctl が `ROAMRUNCTL_PROXY` の指す HTTP プロキシを通せます。userspace で動く Tailscale は、tailnet へのそうしたプロキシを出せます（`--outbound-http-proxy-listen`）。そのため、スクリプトで roamrunctl そのものを動かせます。relay を経由してもよく、デバイスの鍵をビルドのマシンに置いて relay なしで使うこともできます。この変更のビルドで、2026-10-24 に Xcode Cloud から両方を試しました。リポジトリ、アプリ、デバイス、relay は上と同じです。上のスクリプトと違うのは次の行で、relay を `curl` で呼ぶ部分（`token=` から最後まで）は roamrunctl に置き換えました。

```bash
rr="$CI_PRIMARY_REPOSITORY_PATH/bin/roamrunctl"
"$bin/tailscaled" --tun=userspace-networking --socket="$t/sock" --statedir="$t/state" \
  --outbound-http-proxy-listen=127.0.0.1:1056 > "$t/log" 2>&1 &
# … tailscale up は上と同じ …
export ROAMRUNCTL_PROXY=http://127.0.0.1:1056

# Through the relay.
ROAMRUNCTL_TOKEN="$RELAY_TOKEN" "$rr" install "$RELAY_DEVICE" "$ipa" --relay "$RELAY" --launch

# With the key here, no relay.
export XDG_CONFIG_HOME="$t/config"
( umask 077 && printf '%s' "$ROAMRUN_KEY" | "$rr" key import - --as dev )
"$rr" install dev "$ipa" --launch
"$rr" look dev "$t/look.png"
```

- relay 経由：インストールして起動しました。10 秒です。
- 鍵を置いて relay なし：`key import` のあと、インストールして起動するまで 14 秒でした。そのあとの `look` は 8 秒です。鍵は、RoamRun の入った Mac で作りました（`roamrun key create iPhone ~/xcc-key.json --as xcc`）。それを Secret の変数 `ROAMRUN_KEY` に入れました。
- `$rr` は、この変更のビルドの roamrunctl で、リポジトリに入れました（`bin/roamrunctl`）。0.10.0 のリリース後は、GitHub Action と同じく、RoamRun のリリースからアーカイブを取得する形になります。その形はまだ試していません。

鍵をビルドのマシンに置く場合、変数は `TS_AUTHKEY` と `ROAMRUN_KEY` で、どちらも Secret にします。`RELAY`、`RELAY_TOKEN`、`RELAY_DEVICE` は使いません。tailnet のポリシーは、relay のポートだけでなく、デバイスそのものに `tag:ci` が届くことを許す必要があります。ポートは [GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)に書いたとおりです。止める relay も、作り直すトークンもありません。`ROAMRUN_KEY` を読めてデバイスに届く人は、デバイスのデベロッパモードの一覧からその名前を削除するまで（設定 › プライバシーとセキュリティ › デベロッパモード）、デバイスを操作できます。

## 試していないこと

- roamrunctl 0.10.0 をリリースから取得するスクリプト（今回は、この変更のビルドをリポジトリに入れて使いました）。
- auth key の代わりに OAuth クライアントを使うこと。`tag:ci` に必要な先だけに絞った Tailscale のポリシー。
- Xcode Cloud のほかの Xcode や macOS の版。ほかの Distribution Preparation の設定。大きなアプリ。iPad。
- プルリクエストやスケジュールでビルドを始めること。
