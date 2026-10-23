# GitHub Actions から実機にインストールして起動する

<p align="center"><a href="ci.md">English</a> | 日本語</p>

GitHub がホストするランナーで動く GitHub Actions のジョブから、Tailscale 越しに自分の iPhone へアプリをインストールし、起動できます。リリース版の `roamrunctl` を、そのまま使います。ほかの CI サービスでは試していません。やり方は 2 つあります。

| | ランナーで roamrunctl を動かす | デバイスのそばの relay に頼む |
|---|---|---|
| デバイスとやりとりするもの | ランナー | 手元のマシン（`roamrunctl mcp --http` を動かす） |
| CI に置くもの | ペアリング（デバイスの鍵）と Tailscale の OAuth クライアント | relay のトークンと Tailscale の OAuth クライアント |
| ランナーから届く必要がある先 | デバイス（ペアリング用ポートと、デバイスが指定するトンネル用のポート） | relay の 1 つのポート |
| 動かしておくもの | なし | relay（自分で起動する） |

relay に頼むやり方では、鍵が手元のマシンから出ません。ランナーで動かすやり方では、ジョブの間に手元で動かしておくものがありません。1 つのリポジトリに両方を用意しておくこともできます。このページの「relay」は、デバイスのそばに置くそのマシンのことです。Tailscale の DERP によるリレーのことではありません。

このページのジョブは、アプリのビルドや署名をしません。CI には、そのデバイス向けに署名済みの `.ipa`（そのデバイスを含む開発用プロファイルで署名したもの）が必要です。`roamrunctl` が確かめるのはアーカイブの構成だけで、署名は確かめずにそのままインストールします。下の実行では、ジョブは自分のリポジトリのリリースから `.ipa` を取得しました（`gh release download`）。

## 実行した環境と結果

CI からの実行は、どれも 2026-10-22（UTC）です。

- デバイス：iPhone 15 Pro（iOS 27.0）。ロックを解除して画面をつけたまま、Wi-Fi と充電器につないでおきました。
- CI：GitHub Actions の `ubuntu-24.04`。非公開のリポジトリで、ジョブは手動（`workflow_dispatch`）で起動しました。roamrunctl はリリースの 0.8.1（`roamrunctl-linux-x86_64.tar.gz`）です。
- relay：どちらもデバイスと同じ Wi-Fi にあるマシンです。1 台目は MacBook Pro で、Homebrew で入れた roamrunctl 0.8.1 を macOS のターミナルで動かしました。2 台目は Ubuntu 24.04（arm64）の仮想マシンで、README の Linux 用の手順で roamrunctl 0.8.1 を入れました。
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

遅かったインストールとタイムアウトは、充電中のデバイスで前面にあるアプリを上書きしたときの止まり方と合います。これらの実行では、デバイスは充電器の上で画面をつけたままでした。ある実行で起動したアプリを、終了させる操作もしていません。理由は、あとで Mac からデバイスのログを見ながら試して分かりました（idevice の `syslog_relay` を使いました）。iOS は置き換える前にアプリの終了を求めますが、その要求は「termination resistance」で断られ、インストールはアプリが前面から外れるまで待たされていました。roamrunctl 0.8.1 で、LAN 越しに試した結果です。日付は、これも UTC で 2026-10-22 です。

| デバイス | アプリ | インストール |
|---|---|---|
| 充電中 | 前面 | 待たされた（手でアプリを終了させるまで 122 秒。そうしなければ 315 秒でタイムアウト） |
| 充電していない | 前面 | 4 秒 |
| 充電中 | 起動していない | 5 秒 |

上の各実行の前に、アプリが前面にあったかどうかは記録していません。そのため、速かった実行のすべてを説明できるわけではありません。48 秒と 71 秒のインストールも、誰もアプリを終了させないまま終わっていて、説明できていません（そのときデバイスに誰かが触れたかどうかも、記録していません）。roamrunctl 0.9.0 は、インストールの前に、そのアプリの起動中のプロセスを終了させます（#196）。この変更を入れたビルドを Mac から LAN 越しに動かしたところ、充電中のデバイスでアプリが前面にあっても、インストールは 4〜5 秒で終わりました。CI からは試していません。0.8.1 を使う場合は、ジョブがインストールするアプリを、充電中のデバイスで前面に残さないでください。アプリを終了させておくか、デバイスを充電器から外しておきます。

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

このアクションは `ping:` も受け付けます。参加したあとに `tailscale ping` する相手を指定する入力で、それぞれへの経路が直接かどうかがログに出ます。上の実行では、別のステップで `tailscale ping -c 5` を実行しました。この入力は試していません。

ポリシーが「すべて許可」のままだと、ジョブが動いている間、ランナーは tailnet のどのマシンにも届きます。必要な先だけに届くようにするには、`tag:ci` の grants を書きます。relay に頼むなら、届く先は relay が待ち受ける 1 つのポートだけです。ランナーで動かすなら、デバイスへの TCP 接続を許可します。ペアリング用ポートは 49152〜49167 のどれかで、トンネル用のポートは、接続のたびにデバイスが別のものを指定します。このように絞ったポリシーは試していません。

### ワークフロー

1 台のデバイスを使うジョブは、一度に 1 つだけ動くようにします。

```yaml
concurrency:
  group: iphone-15-pro
  cancel-in-progress: false
```

このグループが効くのは、1 つのリポジトリの中だけです。2 つのリポジトリから同じデバイスを使う場合は、分けられません。また、既定ではグループの中で待てる実行は 1 つだけです。新しい実行が来ると、待っていた実行は取り消されます。GitHub の `queue: max` を使うと、100 件まで待てます。これは試していません。

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

どちらのシークレットも、デバイスの鍵です。それを読むワークフローを動かせて、デバイスに届く人なら、誰でもデバイスを見て操作できます。取り消すときは、デバイスのデベロッパモードの一覧から、その名前を削除します。

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

0.9.0 の `key import -` は、鍵を標準入力から読みます。roamrunctl が保存したファイルも受け付けるので、どちらの鍵も同じ形で取り込めます。シークレットを一時ファイルに書き出す必要はありません（roamrunctl が保存するデバイスのファイルには、これまでどおり鍵が入ります）。`printf '%s' "$ROAMRUN_CI_KEY" | "$rr" key import - --as ci` です。この変更（#193）を入れたビルドで、roamrunctl が保存したファイルを `-` から取り込む形を Mac で試しました。`roamrun key create` が書いたファイルでは試していません。CI からも試していません。

## デバイスのそばの relay に頼む

### relay で用意すること

1. relay 専用のペアリングを、デバイスと同じ Wi-Fi で作ります。

   ```sh
   roamrunctl pair control --to iphone-15-pro --as relay
   ```

   デバイスの 設定 › プライバシーとセキュリティ › デベロッパモード で relay の Tailscale 上の名前を選び、ターミナルに表示されたコードを入力します。`relay` は、そのマシンにデバイスを保存するときの名前です。下のサーバーとジョブの呼び出しでも、この名前でデバイスを指します。MacBook Pro では、Claude アプリのターミナルから実行したときは、デバイスのその一覧に Mac が出ませんでした。macOS のターミナルから実行すると出ました。

2. トークンを作り、同じトークンをシークレットにも登録します。

   ```sh
   (umask 077 && mkdir -p ~/.config/roamrunctl && openssl rand -hex 32 > ~/.config/roamrunctl/ci-token)
   gh secret set RELAY_TOKEN --repo <owner>/<repo> < ~/.config/roamrunctl/ci-token
   ```

   Ubuntu の relay には、同じトークンを Mac からコピーしました。
   `ssh admin@ubuntu-standin 'mkdir -p ~/.config/roamrunctl && umask 077 && cat > ~/.config/roamrunctl/ci-token' < ~/.config/roamrunctl/ci-token`

3. サーバーを起動し、動かしたままにします（Ctrl-C で止まります）。

   ```sh
   roamrunctl mcp --http 9090 --allow tag:ci --token-file ~/.config/roamrunctl/ci-token --allow-install relay
   ```

   起動するときに、待ち受けるアドレス（`http://<Tailscale の IPv4 アドレス>:9090/mcp`）を表示します。そのあとは要求ごとに 1 行を標準エラー出力に書き出します。時刻、呼び出し元のアドレスと Tailscale が答えた相手、ツール、結果、かかった時間です。サービスとして動かすこと（launchd や systemd）は試していません。

### relay を呼ぶ手順

ジョブは `.ipa` をアップロードしてインストールを始め、終わるまで 5 秒ごとに `install_status` を呼んでから起動します。`RELAY` は、サーバーが表示したアドレスとポートです。アップロードとインストールは、同じジョブの中で行います。アップロードしたものをインストールできるのは、アップロードした呼び出し元（Tailscale のノード）だけです。GitHub がホストするランナーは、ジョブが変わると別のノードです。

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
    call install "{\"device\":\"relay\",\"upload\":\"$id\",\"sha256\":\"$sha\"}"
    for _ in $(seq 1 120); do
      sleep 5
      call install_status '{"device":"relay"}' || exit 1
      jq -e '.result.content[0].text | test("^installing ")' "$RUNNER_TEMP/last.json" >/dev/null || break
    done
    jq -e '.result.content[0].text | test(" is installed on ")' "$RUNNER_TEMP/last.json" >/dev/null || exit 1
    call launch '{"device":"relay","bundle":"com.example.MyApp"}'
```

ツールを呼ぶ前に `initialize` を送る必要はありません。このループは 10 分で諦めます。relay がインストールに与える時間は、5 分と、1 MB あたり 15 秒の合計です。約 20 MB を超える `.ipa` では、ループを長くしてください。ツールの答え方やアップロードの上限は、[roamrunctl-reference.ja.md](roamrunctl-reference.ja.md#http-で使う-mcp) にあります。

このスクリプトは、答えに「 is installed on 」が入っているかだけを見ます。そのため、自分のインストールと、直前に終わった別の呼び出し元のインストールを区別できません。0.9.0 の `install` は、答えに id（`(install <id>)`）を付けます。その id を `"install": "<id>"` として `install_status` に渡すと、そのインストールについてだけ答えます。これは Mac から試しました。CI からは試していません。

0.9.0 では、このスクリプトの代わりに `roamrunctl install <デバイス> app/MyApp.ipa --relay <アドレス>:<ポート> --launch` が使えます。トークンは `ROAMRUNCTL_TOKEN` か `--token-file` で渡します。アップロード、インストール、終わるまでの待ち、起動までを、このコマンドが行います。この変更（#194）を入れたビルドを両端に使い、Mac から同じ Mac の relay に対して実行しました。CI からは試していません。relay の側も 0.9.0 である必要があります。コードによれば、0.8.1 の relay でも、relay の側でインストールは始まります。ただ、その答えにはインストールの id がないので、コマンドはそこで止まり、`--launch` も実行されません。この組み合わせは試していません。

## 試していないこと

- デバイスがロックされている、またはスリープしている場合。iPad での実行。（モバイル通信だけでつながっているデバイスは、こうした接続を受け付けません。roamrunctl の README にあるとおりです。）
- Windows の relay。relay をサービスとして動かすこと。
- macOS や Windows のランナー。セルフホストのランナー。
- `tag:ci` に必要な先だけに絞った Tailscale のポリシー。
- CI からの 1 MB より大きい `.ipa`。上書きでインストールしたときに、アプリのデータが残るかどうか。
- デバイスのそばの Mac に CI から SSH でつなぎ、`xcrun devicectl` でインストールするやり方。
- CI からの roamrunctl 0.9.0。`key import -`、`install --relay … --launch`、インストール前のアプリの終了を試していません。
- CI からの、インストールの id を渡した `install_status`。
- tailscale/github-action の `ping:` の入力と、GitHub の `queue: max`。
