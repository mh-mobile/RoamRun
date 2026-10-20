# RoamRun Introducer

<p align="center"><a href="README.md">English</a> | 日本語</p>

RoamRun Introducer は、離れたマシンを、このアプリを入れた iPhone とペアリングするための iPhone アプリです。デバイスのそばの Mac で `roamrun pair introduce` が行うことを、デバイス自身で行います。離れたマシンが出すペアリングのオファー（ペアリングを始めるためのデータ）を、デバイスがつながっている Wi-Fi 上に公開します。「設定」からの接続を受けて、デバイスに入っている Tailscale の VPN 経由で、離れたマシンへ中継します。デバイスのそばに Mac は要りません。

離れたマシンは、RoamRun を入れた Mac です。デバイス操作のペアリングに限り、`roamrunctl` を入れたマシン（Linux、Windows、macOS）でも構いません（RoamRun 0.7.0 以降）。離れた Mac の側から見た手順は、本体の README の「[デバイス自身に仲介させる](../README.ja.md#デバイス自身に仲介させる)」にあります。

<p align="center">
  <img src="../docs/images/introducer-home.png" width="200" alt="最初の画面：離れた Mac の名前と Introduce ボタン">
  <img src="../docs/images/introducer-pairing.png" width="200" alt="仲介の途中：「設定」でペアリングする">
  <img src="../docs/images/introducer-done.png" width="200" alt="完了：離れた Mac がこの iPhone を保存した">
</p>

このアプリは App Store になく、`make app` にも含まれません。自分でビルドします。iOS 27 以降が必要で、iPhone 専用です。iOS 27 が必要なのは、Device Hub の Pair Nearby Device で待っている Mac の代わりをするためです。Pair Nearby Device は、Xcode 27 が iOS 27 以降のデバイス向けに用意している機能です（Xcode のリリースノートの Device Hub の項）。ホーム画面と「設定」では、アプリの名前は「RoamRun」と表示されます。アイコンの下に、名前の全体が収まらないためです。

## ビルドとインストール

Xcode 27 を入れた Mac と、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）が必要です。必要なのは最初の 1 回だけで、インストールしたあとは、デバイスのそばに Mac は要りません。無料の個人チームで署名したアプリは 7 日間動き、そのあとはインストールし直します。有料のチームなら 1 年です。

```
cd iOS
xcodegen generate
open RoamRunIntroducer.xcodeproj   # Signing でチームを設定し、iPhone で実行する
```

署名せずにシェルからビルドするには、次のコマンドを使います。

```
xcodebuild -project RoamRunIntroducer.xcodeproj -scheme RoamRunIntroducer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

アプリにエンタイトルメントのファイルはなく、`UIBackgroundModes` も宣言していません。許可を求められるのは、次の 3 つです。

- ローカルネットワーク：最初に仲介するとき
- カメラ：QR コードを読み取るとき
- 通知：デバイス操作のペアリングをするとき

アプリ自身のバージョンは 0.1 のままです。必要なのは、離れた Mac の RoamRun が 0.5.0 以降であることです。

## 離れた Mac を Xcode 用にペアリングする

テキストを手で運ぶ必要はありません。`roamrun pair xcode --with` が待っている仲介役を、アプリが務めます。

1. 離れた Mac で、Xcode › Device Hub › Pair Nearby Device を開きます。続けて、`roamrun pair xcode --with <この iPhone の Tailscale 上の名前>` を実行します。
2. アプリで、離れた Mac の Tailscale 上の名前を入力し、**Introduce** をタップします。ローカルネットワークの許可を求められたら、許可します。
3. 設定 › プライバシーとセキュリティ › デベロッパモード で、Pair with “<離れた Mac>” を選びます。離れた Mac の Device Hub に表示されたコードを入力します。
4. アプリが離れた Mac に結果を伝え、離れた Mac がこの iPhone を、Tailscale 上の名前で保存します。離れた Mac で `roamrun up <name>` を実行します。`<name>` は、保存された名前です。

名前を入力したくない場合は、手順 1 のコマンドに `--qr` を付けます。離れた Mac のターミナルに、QR コードが表示されます。これをアプリで読み取ります。読み取りのボタンは、名前が入っていないときは「Scan the Mac's Code」、入っているときは「Scan a Code」です。iPhone のカメラで読み取っても構いません。その場合は、`roamrun-introducer://<離れた Mac の Tailscale 上の名前>` のリンクから、名前が入った状態でアプリが開きます。Introduce をタップした時点で、アプリは名前を覚えます。次からは、入力も読み取りも要りません。

アプリは、離れた Mac のオファーを最大 10 分待ちます。オファーを公開するのは、最大 5 分間です。

## デバイス操作用にペアリングする

デバイス操作（`look`、`tap` など）のペアリングも、同じ流れです。離れたマシンで、次のどちらかを実行します。

- RoamRun を入れた Mac の場合：Mac の RoamRun（メニューバーのアプリ）を開いておきます。そのうえで、`roamrun pair control --with <この iPhone の Tailscale 上の名前>` を実行します。ここでも `--qr` を使えます。
- `roamrunctl` を入れたマシンの場合：`roamrunctl pair control --with <この iPhone の Tailscale 上の名前>` を実行します。`roamrunctl` に `--qr` はありません。アプリには、そのマシンの Tailscale 上の名前を入力します。

アプリの側で、ほかに設定するものはありません。どちらのペアリングかは、離れたマシンの応答で決まります。入力するコードは離れたマシンが作り、この iPhone に表示されます。表示される場所は、アプリの画面（大きな数字）、通知、iOS がアプリのバックグラウンド処理を表示する場所の 3 つです。`roamrunctl` の場合は、離れたマシンにもコードが表示されます。

<p align="center">
  <img src="../docs/images/introducer-code.png" width="200" alt="デバイス操作のペアリング：コードがこの iPhone に表示される">
  <img src="../docs/images/introducer-byhand.png" width="200" alt="テキストを手で運ぶ方法：roamrun devices add に渡す行">
</p>

注意することが 2 つあります。

- **何ともペアリングしたことのない iPhone では使えません**。アプリは、Wi-Fi 上で、この iPhone 自身のペアリング用のサービスを探します。iPhone がこれを公開するのは、一度ペアリングしたあとだけです。「This iPhone isn't announcing itself」と表示された場合は、先に Xcode のペアリングをしてください。
- **「設定」に移ったら、すぐにコードを入力してください**。「設定」を開いている間も仲介を続けるために、アプリは iOS にバックグラウンド処理を申請します。iOS がこれを認めなかった場合、アプリがバックグラウンドで動けるのは約 30 秒です。その場合は、アプリにその旨が表示されます。Xcode のペアリングでも同じです。

## テキストを手で運ぶ方法

アプリから Tailscale 経由で問い合わせられない離れた Mac には、**Carry the lines by hand** を使います。使えるのは、Xcode のペアリングだけです。

1. 離れた Mac で、Pair Nearby Device を開いたまま、`roamrun pair xcode` を実行します。`rr-xcode-offer-v1:` で始まる 1 行が表示されます。`roamrun pair xcode --qr` を実行すると、その行と離れた Mac の名前が、QR コードとして表示されます。これをアプリで読み取ることもできます。
2. アプリで、その行を貼り付け、離れた Mac の Tailscale 上の名前と、この iPhone の Tailscale 上の名前を入力します。`--qr` の QR コードを読み取った場合は、行と離れた Mac の名前が入ります。
3. 上と同じように、「設定」でペアリングします。
4. アプリに、`rr-device-v1:` で始まる行が表示されます。離れた Mac で、この行を `roamrun devices add <line>` に渡します。

離れた Mac から、保存したかどうかの応答がなかった場合にも、アプリにこの行が表示されます。

オファーの行は、アプリを終了すると残りません。オファーが使えるのは、離れた Mac で Pair Nearby Device の画面が開いている間だけです。Pair Nearby Device を押すたびに、別のオファーになります。離れた Mac の名前と、この iPhone の Tailscale 上の名前は、アプリを終了しても残ります。

## アプリの接続先

- アプリが受け付けるのは、このデバイス自身のアドレスからの接続だけです。同時に受け付けるのは 2 本までです。データが両方向に流れた接続を閉じたあとは、受け付けをやめます。アプリの「A pairing was tried」という表示は、接続がアプリを通ったという意味です。Xcode がコードを受け入れたという意味ではありません。
- 離れたマシンは、Tailscale が付けた名前で指定します。1 語の名前、`ts.net` で終わる名前、`100.x` のアドレスのどれかです。IPv6 のアドレスは受け付けません。
- 問い合わせの送信先とペアリングの中継先は、Tailscale の範囲のアドレスだけです。QR コード、リンク、名前が何を指していても変わりません。アプリは、接続が確立したあとにこれを確かめます。範囲外のアドレスへの接続は、何も送らずに切ります。
- Wi-Fi 上のペアリング用のサービスのうち、どれがこの iPhone 自身のものかを調べるために、アプリは、公開されているサービスのそれぞれに接続し、何も送らずに閉じます。

## うまくいかないとき

- **この iPhone 自身のサービスが見つからなかった、と表示された**。まず、離れた Mac で `roamrun devices` を実行します。すでに保存されていれば、`roamrun up <name>` でそのまま使えます。保存されていなければ、この iPhone を保存している Mac で `roamrun devices export <name>` を実行します。表示された行を、離れた Mac で `roamrun devices add <line>` に渡します。
- **5 分たってもペアリングされなかった**。アプリは公開をやめています。手順 1 からやり直します。
- **バックグラウンドで iOS に止められた**。上の「『設定』に移ったら、すぐにコードを入力してください」を見てください。

「設定」からの接続がどこから来たかは、アプリの最後の画面の Details に表示されます。デバイスのログにも残ります。Mac の「コンソール」でデバイスを選び、サブシステム `io.github.mh-mobile.roamrun.introducer` で絞り込みます。

## 試したこと

iOS 27 の iPhone 15 Pro と、Tailscale 経由でつながる離れた Mac で、次のことを試しました。

- Xcode のペアリング（名前を入力する方法と、`--qr` の QR コードを読み取る方法）
- テキストを手で運ぶ方法
- デバイス操作のペアリング

次のものは試していません。

- `roamrunctl` を入れたマシンを離れたマシンにした、デバイス操作のペアリング
- iPad（アプリは iPhone 専用です）
- ほかのバージョンの iOS

## 開発者向け

`Sources/Introduction.swift` には、行の形式と、その決まりが入っています。本体の `Sources/RoamRun/Pairing/Introductions.swift` にも、同じものがあります。変えるときは、両方を変えてください。

`Sources/Session.swift` は、1 回の仲介の状態（段階、コード、終わり方）を持ちます。`Sources/ContentView.swift` は、その状態を画面にします。表示するのは、最初の画面、進行中の 3 つの段階、終わり方です。運ぶ行がある場合は、その行も表示します。離れた Mac なしで画面を見るには、デバッグビルドをシミュレータで次のように起動します。

```
SIMCTL_CHILD_INTRODUCER_PREVIEW=pairing xcrun simctl launch booted io.github.mh-mobile.roamrun.introducer
```

指定できる値は、`empty`、`asking`、`pairing`、`code`、`finishing`、`done`、`byhand`、`failed` です。これ以外の値を指定すると、名前が入った最初の画面になります。このページの画像は、このプレビューで撮りました。名前もコードも架空のものです。

`Checks/relay-check.swift` は、アプリの中核の部分を macOS 向けにビルドして動かします。サービスの種類には、テスト用の `_rrtest._tcp` を使います。本物の種類は使いません。確かめる内容には、次のものがあります。

- 127.0.0.1 で、受け取ったデータをそのまま返す偽の離れた Mac が動くこと
- 許可していないアドレスからの接続の拒否
- 許可した接続の、両方向の中継
- 接続でデータが流れたあとの終了
- 公開したレコードが消えること
- 時間切れ
- アプリと離れたマシンの間でやり取りする行の解釈
- Tailscale のアドレスかどうかの判定

`iOS/` で、次のコマンドを実行します。

```
xcrun swiftc -swift-version 6 -parse-as-library -o /tmp/relay-check Sources/StandIn.swift Sources/Introduction.swift Sources/Wire.swift Checks/relay-check.swift && /tmp/relay-check
```

アイコンは RoamRun のもので、余白のない全面の絵です。次のコマンドで作ります。

```
xcrun swift ../scripts/make-icon.swift --ios Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```
