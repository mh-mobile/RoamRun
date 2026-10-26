# GitHub Actions から実機にインストールして起動する

<p align="center"><a href="ci.md">English</a> | 日本語</p>

GitHub がホストするランナーで動く GitHub Actions のジョブから、Tailscale 越しに自分の iPhone へアプリをインストールし、起動できます。リリース版の `roamrunctl` を、そのまま使います。Xcode Cloud からもできます（[xcode-cloud.ja.md](xcode-cloud.ja.md)）。Bitrise からは、Step を使ってできます（[bitrise.ja.md](bitrise.ja.md)）。ほかの CI サービスでは試していません。やり方は 2 つあります。

| | ランナーで roamrunctl を動かす | relay に頼む |
|---|---|---|
| デバイスとやりとりするもの | ランナー | 手元のマシン（`roamrunctl mcp --http` を動かす） |
| CI に置くもの | ペアリング（デバイスの鍵）と、Tailscale の OAuth クライアントか auth key | relay のトークンと、Tailscale の OAuth クライアントか auth key |
| ランナーから届く必要がある先 | デバイス（ペアリング用ポートと、デバイスが指定するトンネル用のポート） | relay の 1 つのポート |
| 動かしておくもの | なし | relay（自分で起動する） |

このページの「relay」は、デバイスの鍵を持ち、`roamrunctl mcp --http` を動かす手元のマシンのことです。Tailscale の DERP によるリレーのことではありません。relay は、ランナーと同じく Tailscale 越しにデバイスへつなぎます。そのため、tailnet のどこに置いてもかまいません。デバイスと同じ Wi-Fi が要るのは、`pair control --to` でペアリングするときだけです。別の場所で作った鍵を取り込む方法もあります（`roamrun key create` のあと `key import`）。relay に頼むやり方では、鍵がそのマシンから出ません。ランナーで動かすやり方では、ジョブの間に手元で動かしておくものがありません。1 つのリポジトリに両方を用意しておくこともできます。

どちらのやり方でも、シークレットを読むワークフローを動かせる人は、デバイスを見て操作できます。ペアリングの鍵なら、そのペアリングがある限りです。relay のトークンなら、relay が動いている間です（relay は、通した呼び出し元にすべてのツールを使わせます）。relay を止めるか、新しいトークンで起動し直せば、そのトークンは使えなくなります。Tailscale の OAuth クライアントを持つ人は、管理画面で取り消されるまで `tag:ci` として tailnet に参加できます。auth key なら、期限が切れるか取り消されるまでです。

このページのジョブは、アプリのビルドや署名をしません。CI には、そのデバイス向けに署名済みの `.ipa`（そのデバイスを含む開発用プロファイルで署名したもの）が必要です。`roamrunctl` が確かめるのはアーカイブの構成だけで、署名は確かめずにそのままインストールします。下の実行では、ジョブは自分のリポジトリのリリースから `.ipa` を取得しました（`gh release download`）。

## action を使う

GitHub Action の [mh-mobile/roamrun-action](https://github.com/mh-mobile/roamrun-action) を使うと、どちらのやり方も 1 つのステップで書けます。Tailscale のステップのあとに置きます。この action は、roamrunctl（既定では 0.9.0）を RoamRun のリリースから取得し、`roamrunctl-SHA256SUMS` と照らし合わせます。そのうえで、既定ではインストールして起動します。ランナーで動かすなら `key import -` と `install --launch`、relay に頼むなら `install --relay … --launch` を使います。relay の側も 0.9.0 である必要があります。使う前に、このページにある準備をしておきます。[Tailscale のタグと OAuth クライアント](#tailscaleタグと-oauth-クライアント)と、[CI 用のペアリング](#ci-用のペアリング)（シークレットを `key` に渡します）か [relay](#relay-に頼む) のどちらかです。

```yaml
- uses: mh-mobile/roamrun-action@v1
  with:
    key: ${{ secrets.ROAMRUN_CI_KEY }}   # relay に頼むなら、key: の代わりに relay:、token:、device: を書く
    ipa: build/MyApp.ipa
```

Linux と macOS のランナーで動きます。macOS では、MagicDNS が有効なとき、Tailscale のアクションがシステムの DNS を `100.100.100.100` に切り替えました。試した tailnet では、そのあと github.com の名前を引けなくなりました。2 つのステップの間に置いて、ランナーのもとの DNS に戻す 1 行は、action の README にあります。入力の一覧と action で試したことは、[その README](https://github.com/mh-mobile/roamrun-action#readme) にあります。インストールだけ、または起動だけにする入力もあります。

action が実行するのは、[ランナーの手順](#ランナーの手順)と [relay を呼ぶ手順](#relay-を呼ぶ手順)の 0.9.0 の形です。このページの残りは、準備と、action を使わずに実行した記録です。

## 実行した環境と結果

roamrunctl 0.8.1 での CI からの実行は、どれも 2026-10-22（UTC）です。0.9.0 での実行は[あとに](#roamrunctl-090-での-ci-からの実行)まとめました。

- デバイス：iPhone 15 Pro（iOS 27.0）。ロックを解除し、Wi-Fi につないで、ワイヤレス充電器に載せておきました。実行の合間に画面がつき続けていたかどうかは、記録していません。
- CI：GitHub Actions の `ubuntu-24.04`。非公開のリポジトリで、ジョブは手動（`workflow_dispatch`）で起動しました。roamrunctl はリリースの 0.8.1（`roamrunctl-linux-x86_64.tar.gz`）です。
- relay：どちらもデバイスと同じ Wi-Fi にあるマシンです（そこでペアリングしました）。1 台目は MacBook Pro で、Homebrew で入れた roamrunctl 0.8.1 を macOS のターミナルで動かしました。2 台目は Ubuntu 24.04（arm64）の仮想マシンで、README の Linux 用の手順で roamrunctl 0.8.1 を入れました。
- ランナー用のペアリング：RoamRun の入った Mac で作ったものと、その Ubuntu のマシンで作ったものの 2 つです。
- アプリ：1 MB の `.ipa`。
- Tailscale：tailnet のポリシーは「すべて許可」のままです。ランナーは `tag:ci` のタグで参加しました。どの実行でも、デバイスと relay への経路は DERP サーバー（東京）から始まり、数秒で直接の経路に切り替わりました。

| 実行 | ランナーで roamrunctl | relay |
|---|---|---|
| 両方（ランナーの直後に relay） | Mac の鍵：鍵の取り込み 3 秒、インストール 15 秒、起動 4 秒 | Mac：アップロード 2 秒、インストールは上限の 315 秒でタイムアウト |
| relay だけ | — | Mac：アップロード 1 秒、インストール 6 秒、起動 1 秒 |
| もう一度両方 | Mac の鍵：鍵の取り込み 3 秒、インストール 9 秒、起動 3 秒 | Mac：アップロード 2 秒、インストール 71 秒、起動 1 秒 |
| ランナーだけ | Linux の鍵：インストール 11 秒、起動 3 秒 | — |
| その 2 分後に relay だけ | — | Linux：アップロード 2 秒、インストール 48 秒、起動 1 秒 |

遅かったインストールとタイムアウトは、ワイヤレス充電器の上のデバイスで、前面にあるアプリを上書きしたときの止まり方と合います。これらの実行では、デバイスはその充電器の上にあり、どの実行もアプリの起動で終わっていました。理由は、あとで Mac からデバイスのログを見ながら試して分かりました（idevice の `syslog_relay` を使いました）。iOS は置き換える前にアプリの終了を求めますが、その要求は「termination resistance」で断られ、インストールはアプリが前面から外れるまで待たされていました。roamrunctl 0.8.1 で、LAN 越しに試した結果です。日付は、これも 2026-10-22（UTC）です。

| デバイス | アプリ | インストール |
|---|---|---|
| ワイヤレス充電器の上 | 前面 | 待たされた（手でアプリを終了させるまで 122 秒。そうしなければ 315 秒でタイムアウト） |
| 充電器から外した | 前面 | 4 秒 |
| ワイヤレス充電器の上 | 起動していない | 5 秒 |

上の各実行が始まったとき、アプリがまだ前面にあったかどうかは記録していません。実行の合間に画面がロックされれば、アプリは前面から外れます。そのため、速かった実行と、48 秒と 71 秒のインストールは、この説明では説明できていません。ケーブルでの充電は試していません。roamrunctl 0.9.0 は、インストールの前に、そのアプリの起動中のプロセスを終了させます（#196）。この変更を入れたビルドを Mac から LAN 越しに動かしたところ、ワイヤレス充電器の上でアプリが前面にあっても、インストールは 4〜5 秒で終わりました。CI からも 0.9.0 でインストールしました（[あと](#roamrunctl-090-での-ci-からの実行)を参照）。ただし、この状態をわざと作ってはいません。0.9.0 では、アプリは、アップロードの始めから終了したままになり、インストールが失敗しても戻りません。0.8.1 にはなかった動きです。0.8.1 を使う場合は、ジョブがインストールするアプリを、充電器の上のデバイスで前面に残さないでください。アプリを終了させておくか、デバイスを充電器から外しておきます。

### roamrunctl 0.9.0 での CI からの実行

2026-10-24（UTC）に、同じデバイス、同じランナーと非公開のリポジトリで、リリース前の roamrunctl 0.9.0 を動かしました。`release/0.9.0` の f21291c から CI が作ったアーカイブを、そのリポジトリのリリースに置いて使いました。デバイスはロックを解除し、Wi-Fi につないでいました。充電器に載っていたかどうかと、各インストールが始まったときにアプリが前面にあったかどうかは、記録していません。relay は MacBook Pro で、同じコードからビルドしたものを、その Mac のシェルから起動しました。

| 手順 | かかった時間 |
|---|---|
| Mac の鍵（`roamrun key create`）：`printf '%s' "$ROAMRUN_CI_KEY" \| roamrunctl key import - --as ci` | 3 秒 |
| `roamrunctl install ci app/RoamRunIntroducer.ipa --launch` | 18 秒 |
| Linux のマシンの鍵（roamrunctl が保存したファイル）を同じ形で：`key import - --as ci-linux` | 3 秒 |
| `roamrunctl install ci-linux app/RoamRunIntroducer.ipa --launch` | 16 秒 |
| `roamrunctl install relay app/RoamRunIntroducer.ipa --relay "$RELAY" --launch` | 10 秒（インストールは 5 秒） |

どの手順も、アプリの起動まで終わりました。relay のログには、`tag:ci` からの呼び出しが 4 つ残りました。アップロード、`install`、`install_status`、`launch` です。

## どちらのやり方にも必要なもの

### Tailscale：タグと OAuth クライアント

1. tailnet のポリシー（Access controls）で、CI 用のタグを作ります。

   ```json
   "tagOwners": {
     "tag:ci": ["autogroup:admin"]
   }
   ```

2. Settings › Trust credentials で、OAuth クライアントを新しく作ります。権限は **Keys › Auth Keys › Write** だけにし、タグに `tag:ci` を選びます。
3. 発行された 2 つの値を、`TS_OAUTH_CLIENT_ID` と `TS_OAUTH_SECRET` という名前でリポジトリのシークレットに登録します。登録先は Settings › Secrets and variables › Actions の Repository secrets です。

ジョブは [tailscale/github-action](https://github.com/tailscale/github-action) で tailnet に参加します。

```yaml
- uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
```

**auth key でも参加できます。** Settings › Keys で auth key を作ります。Reusable と Ephemeral にし、タグは `tag:ci`、期限は短くします。それを `TS_AUTHKEY` という名前でリポジトリのシークレットに登録します。

```yaml
- uses: tailscale/github-action@v4
  with:
    authkey: ${{ secrets.TS_AUTHKEY }}
```

タグは鍵に付けたものが使われます（`tags:` は OAuth クライアントのときの入力です）。このアクションは `authkey` を非推奨とし、OAuth クライアントを勧めています。そのため実行の画面に警告が出ますが、処理は続きます。2026-10-26 に GitHub のランナーで試しました。`ubuntu-24.04` と `macos-15` は `tag:ci` として参加し、relay のマシンに届きました（macOS のランナーは DERP 経由）。さらに `ubuntu-24.04` のジョブから、relay を通して iPhone Duo にアプリを入れて起動しました。使ったのは roamrun-action v1（roamrunctl 0.9.0）で、relay は 0.11.0 のブランチからビルドした roamrunctl です。relay のログには、アップロード、`install`、`install_status`、`launch` の 4 つが `tag:ci` から届いていました。

[Tailnet Lock](https://tailscale.com/docs/features/tailnet-lock) を有効にした tailnet では、参加したノードは、信頼されたノードの署名を受けるまで、ほかのノードとつながれません。auth key なら、信頼された Tailnet Lock の鍵を持つノードで `tailscale lock sign <鍵>` を一度実行して署名できます。そのとき表示される鍵を CI に渡します（[Tailscale の説明](https://tailscale.com/docs/features/tailnet-lock#add-a-node-using-a-pre-signed-auth-key)、英語）。OAuth クライアントは実行のたびに新しい鍵を作るので、前もって署名できません。どちらも、Tailnet Lock を有効にした tailnet では試していません。

このアクションは `ping:` も受け付けます。参加したあと、指定した相手につながるまで最大 3 分待つ入力です（経路は、直接か中継かを問いません）。上の実行では、別のステップで `tailscale ping -c 5` を実行しました。こちらは、経路が直接かどうかが出力に出ます。この入力は試していません。

ポリシーが「すべて許可」のままだと、ジョブが動いている間、ランナーは tailnet のどのマシンにも届きます。必要な先だけに届くようにするには、`tag:ci` の grants を書きます。relay に頼むなら、届く先は relay が待ち受ける 1 つのポートだけです。ランナーで動かすなら、デバイスへの TCP 接続を許可します。ペアリング用ポートは 49152〜49167 のどれかです。トンネル用のポートは、接続のたびにデバイスが新しく指定し、範囲も分かっていません。つまり実質は、デバイスのすべての TCP ポートを許可することになります。このように絞ったポリシーは試していません。

### ワークフロー

1 台のデバイスへのインストールは、順番に行う必要があります（同時に行うと調整されません）。ワークフローに concurrency のグループを付けると、実行が 1 つずつ動きます。

```yaml
concurrency:
  group: iphone-15-pro
  cancel-in-progress: false
```

このグループがまとめるのは実行で、ジョブではありません。1 つの実行の中の 2 つのジョブは、同時に動きます。1 台のデバイスへのインストールは 1 つのジョブにまとめるか、各ジョブの `jobs.<id>.concurrency` に同じグループを付けてください。このグループが効くのは、1 つのリポジトリの中だけです。2 つのリポジトリから同じデバイスを使う場合は、分けられません。また、既定ではグループの中で待てる実行は 1 つだけです。新しい実行が来ると、待っていた実行は取り消されます。GitHub の `queue: max` を使うと、100 件まで待てます（試していません）。relay が持てるアップロードは、呼び出し元にかかわらず 1 つだけです。そのため、1 台の relay にある 2 台のデバイスのジョブも、同じグループに入れてください。

上の実行は、どれも手動で起動しました。フォークから出されたプルリクエストで `pull_request` として動くワークフローには、GitHub は `GITHUB_TOKEN` 以外のシークレットを渡しません。どちらのやり方もシークレットを使うので、そうしたワークフローでは動きません。`pull_request_target` のワークフローには、フォークからのプルリクエストでもシークレットが渡ります。そこでは、これらのシークレットを使わないでください。

## ランナーで roamrunctl を動かす

### CI 用のペアリング

**RoamRun の入った Mac で作る場合**は、デバイスを同じ Wi-Fi につなぎ、ロックを解除してから実行します（`iPhone` は RoamRun でのデバイスの名前です）。

```sh
roamrun key create iPhone ~/ci-key.json --as ci
```

デバイスの 設定 › プライバシーとセキュリティ › デベロッパモード で「ci」を選び、ターミナルに表示されたコードを入力します。できたファイルをシークレットに登録し、手元からは消します。

```sh
gh secret set ROAMRUN_CI_KEY --repo <owner>/<repo> < ~/ci-key.json && rm ~/ci-key.json
```

**roamrunctl の入った Linux のマシンで作る場合**は、デバイスと同じ Wi-Fi で実行します（`iphone-15-pro` はデバイスの Tailscale 上の名前です）。設定のフォルダを別にすると、別のペアリングになります。roamrunctl は、ペアリングに使う自分の識別子をそのフォルダに置くからです。

```sh
export XDG_CONFIG_HOME=$(mktemp -d) && echo "$XDG_CONFIG_HOME" && roamrunctl pair control --to iphone-15-pro --as ci-linux
```

デバイスの 設定 › プライバシーとセキュリティ › デベロッパモード でそのマシンの Tailscale 上の名前を選び、ターミナルに表示されたコードを入力します。最初は、Tailscale がデバイスに直接届かないと言って断られました。そのマシンの LAN からはデバイスに届いていましたが、`tailscale ping iphone-15-pro` はタイムアウトしていました。そのマシンで `sudo systemctl restart tailscaled` を実行すると ping が直接届くようになり、ペアリングも通りました。できたファイルは、Mac から SSH で読んでシークレットに登録し、フォルダごと消しました。

```sh
ssh admin@ubuntu-standin cat /tmp/tmp.XXXXXXXXXX/roamrunctl/devices/ci-linux.json | gh secret set ROAMRUN_CI_KEY_LINUX --repo <owner>/<repo> && ssh admin@ubuntu-standin rm -rf /tmp/tmp.XXXXXXXXXX
```

どちらのシークレットも、デバイスの鍵です。それを読むワークフローを動かせて、デバイスに届く人なら、誰でもデバイスを見て操作できます。取り消すときは、デバイスのデベロッパモードの一覧から、その名前を削除します。`pair control --to` で作ったペアリングは、`--as` に何を付けても、マシンの Tailscale 上の名前で告知されます。そのため、Ubuntu のマシンで作った 2 つのペアリング（これと、下の relay のもの）は、一覧で同じ名前になります。一覧でどう見分けられるかは確かめていません。`roamrun key create --as ci` で作ったものは「ci」と表示されます。

### ランナーの手順

ここの手順は、実行したときのままです。roamrunctl は、当時のリリースの 0.8.1 です。Mac で作った鍵は、`key import` で取り込みます。0.8.1 の `key import` が受け付けるのは、`roamrun key create` が書いたファイルだけです。デバイスにつながることを確かめてからペアリングを保存し、保存できたら読んだファイルを消します。

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

Linux のマシンで作った鍵は、roamrunctl がデバイスを保存したファイルそのものです。そのため、roamrunctl がデバイスを置くフォルダに、中に書かれた名前のファイルとして置きます。

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

`XDG_CONFIG_HOME` を指定すると、roamrunctl が保存するものはジョブの一時フォルダに置かれます。`umask 077` は、鍵を書き出したファイルを、ランナーのユーザーだけが読めるようにするためのものです。保存ファイルをほかのユーザーも読める状態だと、roamrunctl はそのデバイスを使いません。`app/MyApp.ipa` と `com.example.MyApp` は、自分のアプリとその bundle identifier に置き換えてください。

0.9.0 の `key import -` は、鍵を標準入力から読みます。roamrunctl が保存したファイルも受け付けるので、どちらの鍵も同じ形で取り込めます。シークレットを一時ファイルに書き出す必要はありません（roamrunctl が保存するデバイスのファイルには、これまでどおり鍵が入ります）。`printf '%s' "$ROAMRUN_CI_KEY" | "$rr" key import - --as ci` です。CI から、2 種類の鍵で試しました。`roamrun key create` が書いたファイルと、roamrunctl が保存したファイルです（[上](#roamrunctl-090-での-ci-からの実行)を参照）。

## relay に頼む

### relay で用意すること

1. relay 専用のペアリングを、デバイスと同じ Wi-Fi で作ります（そのあと、relay は tailnet のどこに置いてもかまいません）。

   ```sh
   roamrunctl pair control --to iphone-15-pro --as phone
   ```

   デバイスの 設定 › プライバシーとセキュリティ › デベロッパモード で relay の Tailscale 上の名前を選び、ターミナルに表示されたコードを入力します。`phone` は、そのマシンにデバイスを保存するときの名前です。下のサーバーとジョブの呼び出しでも、この名前でデバイスを指します。一方、`--relay` が指すのはマシンです。実際の試行ではデバイスの名前も `relay` にしていましたが、ここでは両者が紛らわしくないように `phone` にしています。MacBook Pro では、Claude アプリのターミナルから実行したときは、デバイスのその一覧に Mac が出ませんでした。macOS のターミナルから実行すると出ました。Claude アプリに「ローカルネットワーク」の許可がなかったためとみられます（macOS はアプリごとに許可します。確かめてはいません）。

2. トークンを作り、同じトークンをシークレットにも登録します。

   ```sh
   (umask 077 && mkdir -p ~/.config/roamrunctl && openssl rand -hex 32 > ~/.config/roamrunctl/ci-token)
   gh secret set RELAY_TOKEN --repo <owner>/<repo> < ~/.config/roamrunctl/ci-token
   ```

   Ubuntu の relay には、同じトークンを Mac からコピーしました。
   `ssh admin@ubuntu-standin 'mkdir -p ~/.config/roamrunctl && umask 077 && cat > ~/.config/roamrunctl/ci-token' < ~/.config/roamrunctl/ci-token`

3. サーバーを起動し、動かしたままにします（Ctrl-C で止まります）。

   ```sh
   roamrunctl mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-install phone
   ```

   起動するときに、待ち受けるアドレス（`http://<Tailscale の IPv4 アドレス>:9090/mcp`）を表示します。そのあとは要求ごとに 1 行を標準エラー出力に書き出します。時刻、呼び出し元のアドレスと Tailscale が答えた相手、ツール、結果、かかった時間です。サービスとして動かすこと（launchd や systemd）は試していません。

### relay を呼ぶ手順

ランナーに roamrunctl 0.9.0 を入れれば、1 つのコマンドで済みます。`.ipa` をアップロードし、relay にインストールさせ、そのインストールが終わるのを待って、アプリを起動します。

```yaml
- name: Install and launch through the relay
  env:
    ROAMRUNCTL_TOKEN: ${{ secrets.RELAY_TOKEN }}
    RELAY: "100.x.y.z:9090"
  run: |
    curl -sSfL "https://github.com/mh-mobile/RoamRun/releases/download/v0.9.0/roamrunctl-linux-x86_64.tar.gz" | tar xz
    ./roamrunctl-linux-x86_64/roamrunctl install phone app/MyApp.ipa --relay "$RELAY" --launch
```

`phone` は relay の側でのデバイスの名前、`RELAY` はサーバーが表示したアドレスとポートです。トークンは relay のものを渡します。このコマンドは、アップロードに対して relay が答えた sha256 を照らし合わせ、relay が返す id で自分のインストールを待ちます。`--timeout <秒>` を付けると、全体でそれ以上待ちません（付けなければ、relay がアップロードとインストールに与える時間と、1 分の合計です）。アップロードとインストールは 1 つのコマンドの中、つまり同じジョブの中で行います。アップロードしたものをインストールできるのは、アップロードした呼び出し元（Tailscale のノード）だけです。GitHub がホストするランナーは、ジョブが変わると別のノードです。

relay の側も 0.9.0 である必要があります。コードによれば、0.8.1 の relay でも、relay の側でインストールは始まります。ただ、その答えにはインストールの id がないので、コマンドはそこで止まり、`--launch` も実行されません。この組み合わせは試していません。この手順は、0.9.0 の relay に対して CI から実行しました（[上](#roamrunctl-090-での-ci-からの実行)を参照）。

#### 0.8.1 で実行したスクリプト

roamrunctl 0.8.1 には、relay に頼むコマンドがありません。relay になる側（`mcp --http`）だけです。そのため上の実行では、curl で relay を呼びました。ジョブは `.ipa` をアップロードしてインストールを始め、終わるまで 5 秒ごとに `install_status` を呼んでから起動します。

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

ツールを呼ぶ前に `initialize` を送る必要はありません。このループは 10 分で諦めます。relay がインストールに与える時間は、5 分と、1 MB あたり 15 秒の合計です。約 20 MB を超える `.ipa` では、ループを長くしてください。ツールの答え方やアップロードの上限は、[roamrunctl-reference.ja.md](roamrunctl-reference.ja.md#http-で使う-mcp) にあります。

このスクリプトは、答えに「 is installed on 」が入っているかだけを見ます。そのため、自分のインストールと、直前に終わった別の呼び出し元のインストールを区別できません。0.9.0 の `install` は、答えに id（`(install <id>)`）を付けます。その id を `"install": "<id>"` として `install_status` に渡すと、そのインストールについてだけ答えます。これは Mac から試しました。CI からも、`install --relay` の中で使われています（このコマンドはその id で待ちます）。

## 試していないこと

- デバイスがロックされている、またはスリープしている場合。ケーブルでの充電。iPad での実行。（モバイル通信だけでつながっているデバイスは、こうした接続を受け付けません。roamrunctl の README にあるとおりです。）
- Windows の relay。relay をサービスとして動かすこと。
- このページの手順での macOS や Windows のランナー（action は `macos-15` で動きました。その README にあります）。セルフホストのランナー。
- `tag:ci` に必要な先だけに絞った Tailscale のポリシー。Tailnet Lock を有効にした tailnet。
- CI からの 1 MB より大きい `.ipa`。上書きでインストールしたときに、アプリのデータが残るかどうか。
- デバイスのそばの Mac に CI から SSH でつなぎ、`xcrun devicectl` でインストールするやり方。
- CI からの 0.9.0 で、ワイヤレス充電器の上のデバイスでアプリを前面に出した状態を、わざと作ってのインストール（0.9.0 はアプリを先に終了させます。これは Mac から試しました）。
- tailscale/github-action の `ping:` の入力と、GitHub の `queue: max`。
