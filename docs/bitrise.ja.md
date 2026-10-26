# Bitrise から実機にインストールして起動する

<p align="center"><a href="bitrise.md">English</a> | 日本語</p>

Bitrise のビルドから、アーカイブしたアプリを Tailscale 越しに自分の iPhone へインストールし、起動できます。使うのは Bitrise Step の [mh-mobile/bitrise-step-roamrun](https://github.com/mh-mobile/bitrise-step-roamrun) です。

これを書いた時点で、Bitrise の Step Library には Tailscale の Step がありませんでした。そのため、この Step が自分で tailnet に参加します。Tailscale は Homebrew で入れ、root なしの userspace で動かします。Tailscale が出す tailnet への HTTP プロキシを、`ROAMRUNCTL_PROXY` で roamrunctl に渡します。これは roamrunctl 0.10.0 からの機能です。インストールと起動には、[GitHub Actions の手順](ci.ja.md)の 2 つのやり方を使えます。デバイスの鍵をビルドのマシンに置くやり方と、手元の relay に頼むやり方です。macOS 15 以降（Xcode 16.3 以降）のスタックで動き、それより古いスタックでは止まります。

```yaml
- xcode-archive@6:
    inputs:
      - distribution_method: development
      - automatic_code_signing: api-key
- git::https://github.com/mh-mobile/bitrise-step-roamrun.git@1.1.0:
    inputs:
      - tailscale_auth_key: $TS_AUTHKEY
      - roamrun_key: $ROAMRUN_KEY
```

Step は Bitrise の Step Library にありません。上のように、`bitrise.yml`（Workflow Editor の YAML 表示）に git の URL とタグで書きます。relay に頼むときは、`roamrun_key` の代わりに `relay_address`、`relay_token`、`device_name` を渡します。`ipa_path` の既定値は `$BITRISE_IPA_PATH` で、前に置いた Xcode Archive & Export が設定します。別の `.ipa` を入れるときは、そのパスを渡します。入力の一覧、用意するもの、Step がすることは、Step の README にあります。

## 用意するもの

- [roamrunctl に必要なもの](../Rust/roamrunctl/README.ja.md#必要なもの)を満たすデバイス。iOS 27 以降で、デベロッパモードをオンにし、Tailscale を入れて同じ tailnet に参加させます。Wi‑Fi につなぎ、起動してから一度はロックを解除しておきます。
- デバイスを含む開発用プロファイルで署名したアプリ（デバイスをチームのデバイス一覧に登録しておきます）。Xcode Archive & Export を `distribution_method: development` で動かし、Bitrise にコード署名を設定します。下の 3 回目の試行では、次の 2 つを設定しました。
  - App Store Connect の API キー（役割は Developer）。追加は Workspace の Settings › Integrations › App Store Connect で行いました。プロジェクトでの選択は、Project settings › Integrations › Stores で行いました。
  - Apple Development の証明書。`.p12` にして、Project settings › Code signing に入れました。
- Tailscale の auth key（管理画面の Settings › Keys）。OAuth クライアントでは試していません。Reusable と Ephemeral をオンにし、タグは `tag:ci`、期限は短くします。タグとポリシーは [GitHub Actions の手順](ci.ja.md#tailscaleタグと-oauth-クライアント)と同じです。鍵をビルドのマシンに置くなら、ポリシーで、タグからデバイスそのものへの接続を許す必要があります。relay への接続だけでは足りません。Tailnet Lock を有効にした tailnet では、鍵を先に署名し、署名した鍵を渡します。署名した鍵は、持つ人なら誰でも Tailnet Lock を通れます。やり方は同じ手順のページにあります。GitHub Actions からは試しましたが、Bitrise からは試していません。
- デバイスの鍵（[CI 用のペアリング](ci.ja.md#ci-用のペアリング)）。`roamrun key create` が書いたファイルか、`roamrunctl pair control` が保存したファイルを使います。中身をまるごと Secret に入れます。または [relay](ci.ja.md#relay-で用意すること)。
- auth key、デバイスの鍵、relay のトークンを入れる Bitrise の Secret。relay のアドレスとデバイスの名前は、Secret にしなくてかまいません。Bitrise は、Secret の値と同じ文字列をログの中で全部伏せます。そのため、`relay` のような名前を Secret にすると、roamrunctl のメッセージの一部が `[REDACTED]` になります。

1 台のデバイスへのインストールは、同時に 1 つです。同じデバイスへインストールするビルドが重ならないようにします（下で使った Hobby プランは、同時に 1 ビルドです）。

ビルドを始められる人と、ビルドするブランチに push できる人は、Secret を読めます。Script の Step は、どの値も出力できるからです。auth key があれば、`tag:ci` として tailnet に参加し、ポリシーがそのタグに許す範囲のマシンに届きます。ポリシーが「すべて許可」なら、すべてのマシンです。デバイスの鍵か relay のトークンがあれば、デバイスを操作できます。PR のビルドでは、PR へ渡す設定をオンにしない限り、Secret の値は空です。空なら、Step はそう言って止まります。

取り消し方は、それぞれ次のとおりです。

- auth key：管理画面で取り消す。
- デバイスの鍵：デバイスのデベロッパモードの一覧から、その項目を消す。
- relay のトークン：新しいトークンで relay を起動し直す。

## 実行した環境と結果

2026-10-24（UTC）に、bitrise.io（Hobby プラン、スタック Xcode 27.1、マシン M2 Pro Medium）で試しました。

- リポジトリは private で、最小限の SwiftUI アプリを入れました。
- tailnet のポリシーは「すべて許可」でした。
- Step は最初のコミット（6e57e27）のものです。
- roamrunctl は、このリポジトリの `release/0.10.0` からビルドした 0.10.0 を、`roamrunctl_path` で Step に渡しました。0.10.0 はまだリリースしていなかったからです。
- デバイスは、自宅の iPhone 15 Pro（iOS 27.0）で、ロックを解除しておきました。

| ワークフロー | 結果 |
|---|---|
| 鍵をビルドのマシンに置く。`.ipa`（21 KB）は Mac で署名してリポジトリに入れたもの | インストールして起動。Step は 26 秒 |
| relay に頼む（MacBook Pro、Homebrew の roamrunctl 0.9.0）。`.ipa` は同じもの | インストール（5 秒）して起動。Step は 16 秒 |
| Xcode Archive & Export（上の設定）のあと、鍵をビルドのマシンに置く | インストールして起動。Step は 21 秒 |

どの回も、Homebrew は Tailscale 1.104.1 のビルド済みパッケージを入れ、マシンは `bitrise-<ビルド番号>` として tailnet に参加しました。1 回目のあとに確かめると、マシンは tailnet の一覧から消えていて、デバイスの画面ではアプリが前に出ていました。relay のログには、`tag:ci` からのアップロード、`install`、`install_status`、`launch` が残りました。

リリース後の 2026-10-24（UTC）には、1 つ目のワークフローをもう一度流しました。Step は `1.0.0` で、`roamrunctl_path` は渡していません。Step はこのリポジトリのリリースから roamrunctl 0.10.0 をダウンロードし、`roamrunctl-SHA256SUMS` と照らし合わせました。そのうえで、同じ `.ipa` をインストールして起動しました。Step は 27 秒でした。

試していないことは、次のとおりです。ほかにも、Step の README に挙げています。

- 時間切れで止められた Step。
- 手元の Mac での Bitrise CLI。
- iPad。
