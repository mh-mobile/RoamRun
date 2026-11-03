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

ジョブは、Mac の前に誰もいなくても、ビルドをページに載せられます。そのために、RoamRun のアプリが動いている Mac で、**OTA server** を起動しておきます。`roamrun mcp --http` に `--allow-ota` を付けたものです。OTA server のツールは `ota` の 1 つだけで、デバイスは操作しません。この OTA server で、そのトークンを持つジョブにできるのは、ページへの公開だけです。トークンは relay のものとは別に作り、シークレット（ここでは `OTA_TOKEN`）にも入れておきます。ジョブは、そのシークレットを `$TOKEN` として使います。

```sh
(umask 077 && mkdir -p ~/.config/roamrun && openssl rand -hex 32 > ~/.config/roamrun/ota-token)
gh secret set OTA_TOKEN --repo <owner>/<repo> < ~/.config/roamrun/ota-token
roamrun mcp --http 9091 --allow tag:ci --token-file ~/.config/roamrun/ota-token --allow-ota
```

`--allow-ota` と `--allow-install` は、1 つのサーバーには付けられません。インストール用のサーバーは、別のポートで並べて動かせます。そちらには別のトークンを付けてください。付けないと、その `--allow` が通すジョブは、そこからアプリのインストールやデバイスの操作ができます。下の `$MAC` は Mac の Tailscale のアドレスで、サーバーが起動したときに表示します。

ジョブは、roamrunctl（0.12.0 以降。アーカイブは [Releases](https://github.com/mh-mobile/RoamRun/releases) にあります）で公開します。

```sh
ROAMRUNCTL_TOKEN="$TOKEN" roamrunctl ota MyApp.ipa --server "$MAC:9091"
```

このコマンドは、何かを送る前に、相手のサーバーが何かを尋ねます。relay や、`ota` のないサーバーなら、そう言って断ります。そのあと .ipa をアップロードし、サーバーが答えた sha256 を確かめてから、`ota` を呼びます。ビルドは、サーバーが `roamrun ota` と同じように検査します。コマンドは、サーバーの答え（保存したもの、自分のデバイスのうちどれに入るか、ページのアドレス）を表示します。ビルドが拒否されたら失敗します。`--replace` は、`roamrun ota` の `--replace` と同じです。詳しくは [roamrunctl のリファレンス](roamrunctl-reference.ja.md#ota---server)にあります。

GitHub Actions では、[roamrun-action](https://github.com/mh-mobile/roamrun-action#publishing-to-the-ota-page)（v1.2.0 以降）がこの手順になります。ジョブが、サーバーの許可するタグで tailnet へ参加したあとに置きます（[ci.ja.md](ci.ja.md#tailscaleタグと-oauth-クライアント)）。

```yaml
- uses: mh-mobile/roamrun-action@v1
  with:
    ota-server: 100.x.y.z:9091          # Mac の Tailscale のアドレス。サーバーが表示したもの
    ota-server-token: ${{ secrets.OTA_TOKEN }}
    ipa: build/MyApp.ipa
```

Bitrise では、[RoamRun の Step](https://github.com/mh-mobile/bitrise-step-roamrun#to-the-ota-page)（1.2.0 以降）が、自分で tailnet に参加して同じことをします（[bitrise.ja.md](bitrise.ja.md)）。`ipa_path` の既定は、前に置いた Xcode Archive & Export が作った `.ipa` です。インストールのときの `development` ではなく、`ad-hoc`（または `enterprise`）で書き出します。トークンは Bitrise の Secret の `OTA_TOKEN` に入れます。

```yaml
- xcode-archive@6:
    inputs:
      - distribution_method: ad-hoc
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.2.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - ota_server: 100.x.y.z:9091
      - ota_server_token: $OTA_TOKEN
```

- **保存できても、すぐにはページに出ません。** 手順が成功したということは、ビルドを保存できたということです。RoamRun のアプリが動いていれば、30 秒ほどでページに出ます。ページが出ていないときは、答えにそのことと理由が書かれます。
- **Mac で動かし続けるもの。** RoamRun のアプリと、このサーバーです。`roamrun mcp --http` は Ctrl-C を押すまで動きます。サービスとして動かす形は試していません。ジョブのタグからこのポートへ届くことを、tailnet のアクセス規則で許可しておきます。
- **公開するジョブは 1 つずつ動かします。** サーバーが持てるアップロードは 1 つだけです。このジョブが `ota` を呼ぶ前に、別のジョブがアップロードを始めたとします。すると、このジョブのアップロードは置き換えられます。`roamrunctl ota` は、ほかのアップロードの最中なら待ち、置き換えられたら 1 回だけ送り直します。それ以上に重なると失敗することがあり、長く待つ場合は `--timeout` を延ばす必要があります。GitHub Actions では、公開するジョブを 1 つの [concurrency](https://docs.github.com/actions/using-jobs/using-concurrency) のグループに入れます。

2026-11-02 に、この Mac 自身からトークン付きで試しました。テスト用アプリの Ad Hoc ビルドをアップロードして、保存できました。答えには、保存してあるデバイスのうち、そのプロファイルに入っている 2 台の名前が出ました。`tools/list` に出たのは `ota` だけで、`look` はすぐに断られました。`--allow-ota` と `--allow-install` を一緒に付けると、起動を断りました。同じ日のそれより前には、使い終わったアップロードで 2 回目の `ota` を呼び、断られることも確かめています。そのあと、tailnet の別のマシン（ログイン名で許可した macOS の VM）からも試しました。この Mac では、9091 で OTA server を、9090 でインストール用のサーバーを並べて動かしました。`roamrunctl ota` は 25 MB の Ad Hoc ビルドを保存しました（アップロードは 22 秒）。手元の CONNECT プロキシを通しても（`ROAMRUNCTL_PROXY`、`--replace` 付き）保存できました。そのマシンから取得したページには、そのビルドが載っていました。9090 に向けると、何も送る前に「`ota` がない」と断りました。2026-11-03（UTC）には、GitHub Actions の `ubuntu-24.04` からも試しました。ランナーは、署名した auth key で `tag:ci` として参加しました。使ったのは roamrun-action の `ota-server` と、それが取得した roamrunctl 0.12.0 です。1 MB の Ad Hoc ビルドを、先にページから外しておいて公開しました。ビルドは保存され、ランナーから取得したページにも載っていました。同じ日に、Bitrise Step の `ota_server` を、この Mac の Bitrise CLI で動かしました（Step 自身の Tailscale を userspace で使用）。結果は同じでした。bitrise.io と Windows からは、まだ試していません。

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
