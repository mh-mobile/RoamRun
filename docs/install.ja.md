# インストールと必要なもの

<p align="center"><a href="install.md">English</a> | 日本語</p>

必要なものの詳細、インストールとアップデート、ソースからのビルド、Mac に作られるもの、アンインストールの手順をまとめています。

## 必要なもの

- **Apple シリコンの Mac と、macOS 13 以降**。管理者アカウントも必要です。RoamRun は `log stream` で `remotepairingd` のログを読みます。macOS から管理者権限が必要だと返された場合は、その旨を表示して止まります。
- **iOS 17.4 以降のデバイス**。RoamRun が中継するのは TCP だけです。iOS 17.0〜17.3 の QUIC トンネルには対応していません。iPad、Apple Vision Pro、Apple TV でも動かしています。以下の「デバイス」は、この 4 種類を指します。Apple Watch は、手元に実機がないため試していません。watchOS 用の Tailscale のアプリはないので、Apple Watch だけをブリッジできません。ペアの iPhone のブリッジを通して届くかどうかは、わかっていません。
- **`devicectl` を含む Xcode**（Xcode 15 以降）。デバイスの iOS のバージョンに対応している必要があります。対応は [Apple の表](https://developer.apple.com/support/xcode/)で確かめられます。`roamrun logs` と `run --logs` は、Xcode 16 で入った `devicectl` の `--console` を使います。
- **Tailscale**。デバイスのアドレスを手で入力する形なら、ほかの mesh VPN でも使えます。Mac とデバイスの両方で接続しておきます。
- **この Mac と一度ペアリングしたデバイス**。デベロッパモードを有効にしておきます。ペアリングは、USB で行うか、Xcode 27 と iOS 27 なら同じ Wi-Fi 上で行えます（Device Hub › ＋ › Pair Nearby Device）。
- **ブリッジを始めるときに、デバイスが Wi-Fi に接続していること**。モバイル通信だけの状態では、試したかぎり、デバイスは応答しませんでした。ブリッジが Ready になったあとなら、モバイル通信に移ってもセッションを保てます。それには「Keep debugging on cellular」をオンにしておく必要があります（初期設定はオフです）。[Mac から離れて作業する](away.ja.md)を参照してください。

デバイスの画面を見て操作する機能には、iOS 27 以降が必要です。離れた Mac を Xcode 用にペアリングするには、iOS 27 と Xcode 27 が必要です。

## インストールとアップデート

Homebrew を使う場合は、次のコマンドでインストールします。

```sh
brew install --cask mh-mobile/tap/roamrun
```

`/Applications` に `RoamRun.app` が入り、`roamrun` コマンドも使えるようになります。アップデートは `brew upgrade --cask roamrun` です。

Homebrew を使わない場合は、[Releases](https://github.com/mh-mobile/RoamRun/releases) から dmg をダウンロードし、RoamRun を「アプリケーション」にドラッグして開きます。最初の画面で、`roamrun` コマンドをインストールするか尋ねられます。あとから入れるには、Open RoamRun › Settings › Command line tool › Install… を使います。アップデートするには、RoamRun を終了して、アプリを新しいものに置き換えます。自動アップデートはありません。保存したデバイスはそのまま残り、動いていたブリッジは再び始まります。

アプリは Developer ID で署名し、Apple の公証を受けています。

## ソースからビルドする

ソースからビルドするには、Xcode 26 以降と、[rustup](https://rustup.rs) で入れた Rust が必要です。`make` は、リポジトリが指定するバージョンの Rust で、デバイス操作用のライブラリをビルドします。

```sh
git clone https://github.com/mh-mobile/RoamRun && cd RoamRun
make run            # ここに RoamRun.app をビルドして開く。インストール済みの RoamRun は先に終了しておく
make install-cli    # /usr/local/bin/roamrun をこのビルドにリンクする（別の場所にするなら BINDIR=$HOME/bin）
```

署名用の証明書がない場合、ビルドはアドホック署名になり、macOS はビルドし直すたびに別のアプリとして扱います。そのビルドでデバイス操作を設定すると、ビルドし直すたびに、キーチェーンが RoamRun の鍵へのアクセスを確認してきます。「常に許可」を選んでください。SSH でしか入れない Mac では、この確認に答える画面がないので、新しいビルドは保存済みのペアリングを読めません。その場合は、キーチェーンの 2 つの項目を削除して（[Mac に作られるものとアンインストール](#mac-に作られるものとアンインストール)を参照）、ペアリングを設定し直すか、取り込み直してください。キーチェーンに Apple Development の証明書があれば、`make app` はその証明書で署名します。

## Mac に作られるものとアンインストール

RoamRun は、自分のファイルを次の場所に置きます。

| 場所 | 中身 |
|---|---|
| `~/Library/Application Support/RoamRun/` | 保存したデバイス、ブリッジの状態、デバイス操作のペアリング（暗号化済み）、OTA 用に保存したビルド、インストールに向かうアプリ（`control/` にあるコピーと、HTTP の MCP サーバーにアップロードされた .ipa） |
| `~/Library/Logs/RoamRun/` | `roamrun up -d` のログ |
| `io.github.mh-mobile.roamrun`（defaults） | 設定と、動いていたブリッジの記録 |
| `/usr/local/bin/roamrun` | アプリか `make install-cli` で CLI を入れた場合だけ。Homebrew は、代わりに `/opt/homebrew/bin/roamrun` をリンクします |
| `~/.claude/skills/roamrun/` など | `roamrun init` を実行した場合だけ |
| ログインキーチェーンの「RoamRun device control」と「RoamRun device control (devices switched on)」 | デバイス操作を設定した場合だけ |

このほかに、次のものがあります。

- 一時ファイル（ビルドを展開するときと、`devicectl` の応答を受け取るとき）
- コマンドが、実行した場所や指定した場所に書くファイル（スクリーンショット、`look` の画像、鍵）
- 「Open at login」をオンにした場合の、ログイン項目
- `roamrun ota` のビルドを配信している間の、`tailscale serve` の設定 1 つ

アンインストールは、次の順で行います。

1. `roamrun up` で始めたブリッジ（`-d` を付けたものも、ターミナルで動いているものも）を止めます（`roamrun down <name>`）。このブリッジは、アプリがなくても動き続けます。
2. スキルを入れた場合は、ここで `roamrun init --uninstall` を実行します。`--output-dir` で入れたフォルダがあれば、フォルダごとに `roamrun init --output-dir <dir> --uninstall` も実行します。どちらも、`roamrun` コマンドがあるうちに実行してください。
3. 「Open at login」をオンにしていた場合はオフにして、RoamRun を終了します。終了するとき、RoamRun は `tailscale serve` の設定を自分で片づけます。
4. Homebrew を使っている場合は、`brew uninstall --zap --cask roamrun` を実行します。アプリ、CLI のリンク、設定、ログ、保存したデバイスが削除されます。キーチェーンの 2 つの項目は残るので、下の `security` の 2 行で削除してください。Homebrew を使っていない場合は、下の行のうち、該当するものを実行します。

OTA のポートを変えていた場合は、何かを削除する前に、ポートを確かめてください。`defaults read io.github.mh-mobile.roamrun otaPort` で確かめられます。`tailscale serve` の行では、そのポートを指定します。

```sh
rm /usr/local/bin/roamrun                 # アプリか make で CLI を入れた場合
rm -rf ~/Library/Application\ Support/RoamRun ~/Library/Logs/RoamRun
security delete-generic-password -s io.github.mh-mobile.roamrun.device-control -a pairings   # デバイス操作を設定した場合
security delete-generic-password -s io.github.mh-mobile.roamrun.device-control -a allowed
tailscale serve --https=41443 --set-path=/ off   # ビルドの配信中に、RoamRun を強制終了したか、異常終了した場合だけ
defaults delete io.github.mh-mobile.roamrun      # 上の行のあとに実行する。ポートを変えた場合、その値はここにある
defaults delete com.roamrun.app 2>/dev/null      # 0.1.12 より前のバージョンが残した設定
# 最後に /Applications/RoamRun.app を削除する
```
