# OTA でのインストール：詳細

<p align="center"><a href="ota.md">English</a> | 日本語</p>

`roamrun ota` は、tailnet の中のページにビルドを公開します。デバイスは、そのページから自分でビルドをインストールします。どんな場合に使うかと、基本の使い方は、[README](../README.ja.md#ブリッジを使わずにインストールするota) にあります。この文書では、それ以外の細かい決まりを説明します。

## 動作

```sh
roamrun ota build/MyApp.ipa            # RoamRun が知っているすべてのデバイスについて、ビルドを確かめる
roamrun ota iPhone build/MyApp.ipa     # 名前を指定すると、そのデバイスについてだけ確かめる
```

RoamRun はビルドを保存し、アプリが動いている間、`tailscale serve` を使ってページを公開します。コマンドを実行すると、ページのアドレスと、そのビルドをインストールできるデバイスが表示されます。ターミナルで実行した場合は、アドレスが QR コードとしても表示されます。デバイスでアドレスを開き、Install をタップします。

- 最初のビルドを保存してからページが出るまでに、30 秒ほどかかることがあります。RoamRun は、起動したときと、そのあと 30 秒ごとに、保存されたビルドを確かめるためです。
- ビルドが保存されていて、Tailscale がこの Mac に名前を付けていれば、`roamrun doctor` でもアドレスを確かめられます。
- ページには、アプリごとに直近 5 つのビルドが、新しい順に並びます。前のバージョンに戻すこともできます。
- ビルドし直しても、たいていはバージョン番号が変わりません。その場合、同じバージョンの下にビルドが並び、日時で区別できます。まったく同じ .ipa をもう一度公開しても、行は増えません。その行が、いちばん上に移ります。
- `--replace` を付けると、同じバージョン番号とビルド番号で並んでいたビルドが削除されます。新しいビルドのプロファイルに自分のデバイスが 1 台も入っていない場合、`--replace` は無視されます。インストールできるビルドを消してしまわないためです。

## 必要なもの

**Release Testing（Ad Hoc）か Enterprise 用に署名した .ipa**。どちらにも、有料の Apple Developer アカウントが必要です。Xcode では、Product › Archive › Distribute App › Release Testing で作れます。スクリプトからは、`xcodebuild -exportArchive` に `"method": "release-testing"` を指定します。`roamrun run` では作れません。`roamrun run` の署名は Development 用です。

`roamrun ota` は、次のビルドを保存せずに拒否します。

- Development ビルド、App Store / TestFlight 用のビルド、署名のないビルド
- プロビジョニングプロファイルの期限が切れているビルド（保存したあとに期限が切れたビルドは、ページに EXPIRED と表示されます）
- Bundle ID に、ASCII の英数字と `.`、`-`、`_` 以外の文字を含むビルドと、Bundle ID が `.` で始まるビルド

Ad Hoc ビルドをインストールできるのは、プロビジョニングプロファイルに入っているデバイスだけです。RoamRun は、自分のデバイスのうち、どれがプロファイルに入っているかを表示します。RoamRun は、ブリッジしたことのあるデバイスの UDID を知っています。まだブリッジしたことのないデバイスは、一度ブリッジして（`roamrun up <name> -d`）、UDID を覚えさせてください。自分のデバイスが 1 台も入っていないビルドも、警告を出したうえで保存します。この Mac の知らないデバイスが、プロファイルに入っている場合もあるためです。Enterprise ビルドには、こうした条件はありません。

**tailnet の HTTPS**。MagicDNS と HTTPS 証明書を有効にしておきます。

**起動している RoamRun**。ページを配信するのは、RoamRun のアプリです。

## CI のジョブから

ジョブは、Mac の前に誰もいなくても、ビルドをページに載せられます。使うのは、Mac のアプリの HTTP の MCP サーバーです。RoamRun が動いている Mac で、`--allow-ota` を付けて起動しておきます。トークンは、relay と同じ手順で作り、シークレットにも入れておきます（[ci.ja.md](ci.ja.md#relay-で用意すること) の手順 2）。ジョブは、そのシークレットを `$TOKEN` として使います。

```sh
roamrun mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-ota
```

ジョブは、まず `PUT /upload` で .ipa を送り、返ってきた id と sha256 で `ota` ツールを呼びます。アップロードを使えるのは送ってきたマシンだけなので、2 つの呼び出しは同じマシンから行います。

```sh
up=$(curl -fsS -H "Authorization: Bearer $TOKEN" -T MyApp.ipa "http://$MAC:9090/upload")
id=$(echo "$up" | jq -r .upload); sha=$(echo "$up" | jq -r .sha256)
said=$(curl -fsS -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ota\",\"arguments\":{\"upload\":\"$id\",\"sha256\":\"$sha\"}}}" \
  "http://$MAC:9090/mcp")
echo "$said" | jq -r '.result.content[0].text'
echo "$said" | jq -e '.result.isError == false' > /dev/null   # 拒否されたビルドで手順を失敗にする
```

`ota` は、`roamrun ota` と同じ検査をします。答えは、保存したもの、自分のデバイスのうちどれに入るか、ページのアドレスです。拒否されたビルドは、HTTP のエラーではなく、`isError` 付きの答えとして返ります。`"replace": true` を付けると、`--replace` と同じ動きになります。拒否されたビルドのアップロードは、もう一度試せるように残ります。保存されたら、そのアップロードは使い終わりです。`--allow-ota` で使えるのは `ota` だけで、`install` は使えません。`install` には `--allow-install` が必要で、両方を付けることもできます。`$MAC` は Mac の Tailscale のアドレスで、サーバーが起動したときに表示します。

2026-11-02 に、この Mac 自身からトークン付きで試しました。テスト用アプリの Ad Hoc ビルドをアップロードして、保存できました。答えには、保存してあるデバイスのうち、そのプロファイルに入っている 2 台の名前が出ました。同じアップロードで 2 回目の `ota` を呼ぶと断られ、`install` は一覧に出ませんでした。CI のジョブからと、ほかのマシンからは、まだ試していません。

## ポートと Funnel

RoamRun は、専用のポートで配信します。既定は 41443 で、終了するときにポートを解放します。tailnet のポート 443 は使いません。443 でほかのものを配信していても、ぶつからないようにするためです。ポートは、次のコマンドで変えられます。

```bash
defaults write io.github.mh-mobile.roamrun otaPort -int 41444
```

ポート 443、8443、10000 は使えません。これらを指定した場合と、1024 より小さいか 65535 より大きいポートを指定した場合は、既定の 41443 で配信します。443、8443、10000 の 3 つは、Tailscale Funnel でインターネットに公開できるポートです（Tailscale の現在の仕様）。それ以外のポートは、Funnel では公開できません。RoamRun が Funnel を有効にすることはありません。配信用のポートで Funnel が有効になっている場合、`roamrun doctor` に失敗として表示されます。

RoamRun を強制終了した場合と、RoamRun が異常終了した場合は、`tailscale serve` の設定が残ります。RoamRun をもう一度開くと、残った設定は取り消されます。RoamRun は、いま設定されているポートと、直近 5 回の登録で使ったポートを調べて、自分が残した設定を見つけます。手動で取り消すには、`tailscale serve --https=41443 --set-path=/ off` を実行します。

## インストールできる人

**tailnet のメンバーなら、だれでもページを開いて、ビルドをインストールできます**。tailnet を共有している場合は、Tailscale のアクセス制御で制限してください。

ページの公開をやめるには、`~/Library/Application Support/RoamRun/ota/` を削除します。RoamRun は、次に確かめたとき（30 秒以内）に配信を止め、ポートを解放します。ビルドごとのフォルダを削除すると、そのビルドだけがページから消えます。`ota/` フォルダは、Time Machine のバックアップから除外されています。

## デバイス側の条件

次の 2 つは、デバイス上で起きることなので、RoamRun からは確かめられません。

- iOS 16 以降では、Ad Hoc ビルドの起動に、デベロッパモードが必要です。デベロッパモードのスイッチは、アプリをインストールしたあとに、設定 › プライバシーとセキュリティ に表示されます。有効にするとき、デバイスが一度再起動します。
- Enterprise ビルドは、設定 › 一般 › VPN とデバイス管理 で、デベロッパを信頼すると使えます。
