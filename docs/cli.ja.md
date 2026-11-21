# `roamrun` コマンド

<p align="center"><a href="cli.md">English</a> | 日本語</p>

ブリッジと Xcode に使う `roamrun` コマンドの細かい動作です。デバイス操作のコマンドは [device-control.ja.md](device-control.ja.md) にあります。よく使うものだけなら、[README](../README.ja.md#コマンド)で足ります。

RoamRun の実行ファイルは、`roamrun` コマンドとしても使えます。SSH 越しの操作や、スクリプトで使うためのものです。

```sh
roamrun devices               # 保存したデバイス（名前、UDID、id）と状態
roamrun up <name>             # ブリッジを始めて、進み具合を表示する。Ctrl-C で止めるまで動く
roamrun up <name> -d          # バックグラウンドで始める。ターミナルを閉じても動き続ける
roamrun status <name>         # Xcode からデバイスを使える状態なら、終了コード 0
roamrun down <name>           # ブリッジを止める。アプリが始めたものも、別のターミナルが始めたものも止められる
roamrun doctor                # Mac → Tailscale → デバイスの順に確かめ、直し方を表示する
roamrun run <name> [--scheme S] [--logs]   # プロジェクトのフォルダで実行する。ビルド、インストール、起動まで行う
roamrun install <name> <App.ipa|App.app>   # そのデバイス向けに署名したビルドをインストールする
roamrun logs <name> <bundle-id>            # アプリを起動し直して、print / os_log の出力を流す
roamrun screenshot <name> [file.png]       # デバイスの画面を PNG で保存し、パスを表示する
roamrun ota [<name>] <App.ipa> [--replace] # デバイスが自分でインストールできるように、ビルドを公開する
```

`<name>` は、RoamRun でデバイスに付けた名前です。大文字と小文字は区別せず、同じ名前は付けられません。名前は `roamrun devices` で確かめられ、デバイスのページの鉛筆のアイコンで変えられます。iOS の「設定」に出るデバイス名は使いません。その名前のデバイスが保存されていなければ、Tailscale 上の名前（`roamrunctl` に渡すのと同じ `iphone-15-pro` など）でも指定できます。`iphone-15-pro.tail1234.ts.net` のような完全な名前は使えません。デバイスの id か、その先頭 8 文字以上でも指定できます。

デバイスは、アプリから追加するほかに、次のコマンドでも追加できます。使い方は、[デバイス操作](device-control.ja.md)と[離れた Mac のペアリング](far-mac.ja.md)にあります。

- `roamrun devices add <line>`（別の Mac が出力した行を渡す）
- `roamrun key import <file>`
- `roamrun pair xcode --with <Tailscale name>`
- `roamrun pair control --with <Tailscale name>`

各コマンドの細かい動作は、次のとおりです。

- `up -d` は、Ready（または On this Wi‑Fi）になるまで最大 60 秒待ち、ならなければ終了コード 1 で終わります。その場合も、ブリッジはバックグラウンドで試み続けます。やり直しても直らないエラーのときだけ止まります。ログは `~/Library/Logs/RoamRun/` に出ます。
- `status` は、名前を付けずに実行すると、保存したデバイスをすべて表示します。1 台でも使える状態なら、終了コードは 0 です。スクリプトで特定のデバイスの状態を知りたいときは、名前を指定してください。`--wait N` を付けると、最大 N 秒待ちます。1 回の確認ごとに `devicectl` を呼ぶため、数秒遅れて戻ることがあります。
- `doctor` にも、名前を指定できます。指定しなければ、ブリッジが動いているデバイスを確かめます。動いているブリッジがなければ、すべてのデバイスを確かめます。
- `run` は、いまいるフォルダの Xcode プロジェクトを `-allowProvisioningUpdates` 付きでビルドします。そのため、Xcode と同じく、プロビジョニングプロファイルを作ることがあります。`--scheme` は、スキームが複数あるときだけ必要です。`--workspace`、`--project`、`--configuration`（既定は `Debug`）も指定できます。
- `run` と `logs` には、起動時のオプションを渡せます。`--arg A`（繰り返し指定できます）、`--env NAME=value`（同じく）、`--url myapp://settings` の 3 つです。`logs` がアプリを起動し直すのは、`devicectl` が実行中のアプリにコンソールをつなげられないためです。
- `install` は、先に署名を確かめます。受け付けるのは、Debugging か Release Testing（Ad Hoc）用に書き出したビルドで、プロビジョニングプロファイルにそのデバイスが入っているものです。Enterprise 用のビルドも受け付けます。こちらは、証明書を信頼しているデバイスならどれでも構いません。App Store Connect 用のビルドは拒否します。`install` を使えるのは、この Mac とペアリングしたデバイスだけです。それ以外のデバイスには、`roamrun ota` か TestFlight を使ってください。
- `screenshot` は、ファイル名を指定しなければ `./<名前>-<日時>.png` に保存します。Xcode 26.3 以降で動かしました。それより前のバージョンでは試していません。
- `--json` は `devices`、`status`、`doctor` で使えます。`-v` は `up` で使えます。`devices --json` の `ready` が表すのは、ブリッジが Ready か、デバイスが同じ Wi-Fi にあるかだけです。`status` は、これに加えて CoreDevice にも問い合わせます。対応していないオプションを渡すと、コマンドは終了コード 2 で終わります。`roamrun --help` で、すべてのオプションを確かめられます。

アプリと CLI が、同じデバイスを同時にブリッジすることはありません。あとから始めたほうが拒否されます。ただし、例外が 1 つあります。待機中（On this Wi‑Fi）のブリッジと、エラーになっているブリッジは、引き継げます。引き継げるのは、アプリの Start ボタンを押したときと、`roamrun up` を実行したときだけです。アプリの自動のやり直しでは、引き継ぎません。すでに `roamrun up` が動いているデバイスに 2 つ目の `roamrun up` を実行しても、2 つ目は始まりません。1 つ目が Ready か待機中なら終了コード 0、開始の途中かエラーなら 1 で終わります。

CLI は、アプリの設定をそのまま使います。SSH 越しのように、アプリの設定画面を開けない場合は、`defaults` で設定を変えられます。

```bash
defaults write io.github.mh-mobile.roamrun keepDebuggingOnCellular -bool true    # オフに戻すときは false
```

## ブリッジ越しに使えるほかのツール

ブリッジが Ready の間、Xcode のコマンドラインツールは、デバイスが同じ Wi-Fi にあるときと同じように使えます。次のコマンドは、実際にブリッジ越しで動かしたものです。

```sh
xcrun devicectl device capture screenshot --device <udid> --destination shot.png   # `roamrun screenshot` が実行しているもの
xcrun devicectl device process launch --device <udid> <bundle-id>
xcodebuild test -destination id=<udid> …                                           # デバイス上での UI テスト（XCUITest）
xcrun devicectl device info files --device <udid> --domain-type appDataContainer --domain-identifier <bundle-id>
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier <bundle-id> --source <path> --destination <local path>
xcrun devicectl device pasteboard copy --file image.png --type public.png --device <udid>
xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs     # クラッシュログ（.ips）
```

UDID は `roamrun status <name>` で確かめられます。XCUITest を土台にしたツールも動きますが、同じ Wi-Fi のときより遅くなります。そのうち 2 つのツールを、テザリング越しに試しました。WebDriverAgent は、1 回のタップに約 2 秒かかりました。agent-device は、1 回の操作に 25〜35 秒かかり、ウインドウ表示の iPad アプリではタップが外れました。

## AI エージェントから使う

Claude Code、Codex、Cursor などのエージェントは、RoamRun を使ってビルド、インストール、デバッグを行えます。使い方は、スキルでエージェントに教えます。

```sh
roamrun init                                  # ~ にあるエージェントすべてにスキルを入れる（.claude、.codex、.cursor、.gemini、.copilot、.devin）
roamrun init --client claude                  # 指定したエージェントだけに入れる（--client は繰り返し指定できる）
```

`init` が入れるのは、いま使っている RoamRun に同梱されているスキルです。そのため、スキルと RoamRun のバージョンがそろいます。RoamRun をアップデートしたら、`roamrun init` をもう一度実行してください。入っているスキルのバージョンが違う場合は、`roamrun status` と `roamrun doctor` がそれを知らせます。スキルを別のツールで管理している場合は、RoamRun のリリースに合わせて固定してください。たとえば、次のようにします。

```sh
gh skill install mh-mobile/RoamRun roamrun --pin "v$(roamrun --version | cut -d" " -f2)"
```

スキルが扱うのは、デバイスの接続とスクリーンショットです。接続では、`roamrun up -d` のあと、`roamrun status --wait 60 --json` で UDID を取得します。デバイスのロック解除のように、人にしかできない作業も含みます。終了コードは、使える状態なら 0、使えないか失敗なら 1、使い方の誤りなら 2 です。
