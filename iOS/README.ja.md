# RoamRun Introducer

<p align="center"><a href="README.md">English</a> | 日本語</p>

デバイス自身の上で `roamrun pair introduce` の代わりをする iOS アプリです。離れた Mac のペアリングの申し出を、デバイスがいる Wi‑Fi で名乗り、「設定」からの 1 本の接続を受けて、デバイスにすでに入っている Tailscale の VPN 越しに、離れた Mac へ取り次ぎます。デバイスのそばに Mac は要りません。離れた Mac の側からの使い方は、メインの README の「[デバイス自身に引き合わせてもらう](../README.ja.md#デバイスと同じ場所にいたことのない-mac)」にあります。

<p align="center">
  <img src="../docs/introducer-home.png" width="200" alt="最初の画面: 離れた Mac の名前と Introduce">
  <img src="../docs/introducer-pairing.png" width="200" alt="引き合わせの途中: 設定でペアリングする">
  <img src="../docs/introducer-done.png" width="200" alt="終わり: 離れた Mac がこの iPhone を保存した">
</p>

`make app` には含まれず、App Store にもありません。ここでビルドします。ホーム画面と「設定」では「RoamRun」と表示されます（アイコンの下に、名前の全体は収まりません）。`Sources/Introduction.swift` は `Sources/RoamRun/Introductions.swift`（行の形式とその決まり）の写しです。同じ内容に保ってください。

iOS 27 以降が必要です。このアプリが代わりをするのは、Device Hub の Pair Nearby Device で待っている Mac で、Xcode 27 が iOS 27 以降のデバイス向けに用意するものだからです（Xcode のリリースノートの Device Hub の項）。

## ビルドして、デバイスで動かす

```
cd iOS
xcodegen generate
open RoamRunIntroducer.xcodeproj   # Signing でチームを設定し、iPhone で実行
```

Xcode 27 の入った Mac と [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）が、最初の 1 度だけ要ります。入れたあとは、デバイスのそばに Mac は要りません。無料の個人チームで署名した場合は 7 日間動き、そのあと入れ直しが要ります。有料のチームなら 1 年です。アプリ自身の版は 0.1 のままです。大事なのは離れた Mac の RoamRun の版で、0.5.0 以降が必要です。

シェルからビルドする場合: `xcodebuild -project RoamRunIntroducer.xcodeproj -scheme RoamRunIntroducer -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`。
エンタイトルメントも、バックグラウンドモードも使いません。ローカルネットワークの許可と `BGContinuedProcessingTask` だけで動きます。

## 流れ

行を手で運ぶことはありません。アプリが、`roamrun pair xcode --with` の引き合わせる側を受け持ちます。

1. 離れた Mac で: Xcode › Device Hub › Pair Nearby Device を押し、`roamrun pair xcode --with <この iPhone の Tailscale 上の名前>` を実行します（RoamRun 0.5.0 以降。それより前は、`--with` のあとに Mac しか指定できません）。
2. アプリで: 離れた Mac の Tailscale 上の名前を入れます（入力は 1 度だけで、覚えています）。**Introduce** をタップし、ローカルネットワークの許可を尋ねられたら許可します。
   `--with` のあとに `--qr` を付けると、離れた Mac が端末にコードを描きます。アプリの **Scan a Code** か iPhone のカメラで読むと、その名前が入った状態でアプリが開きます（`roamrun-introducer://<離れた Mac の Tailscale 上の名前>`）。何も入力せずに済みます。
3. 設定 › プライバシーとセキュリティ › デベロッパモード › 「<離れた Mac>」とペアリング を選び、離れた Mac の Device Hub に出るコードを入力します。
4. アプリが離れた Mac に伝え、離れた Mac がこの iPhone を、その Tailscale 上の名前で保存します。あちらで `roamrun up` を実行します。

デバイス操作（`look`、`tap` など）のペアリングも、同じ流れです。離れた Mac で RoamRun のアプリを開いたまま、`roamrun pair control --with <この iPhone の Tailscale 上の名前>` を実行します（アプリがまだ名前を覚えていない Mac には、ここでも `--qr` が使えます）。アプリ側に、ほかの設定は要りません。どちらのペアリングかは、離れた Mac の返事で決まります。コードは離れた Mac が決め、この iPhone に表示されます。通知と、iOS がアプリのバックグラウンド作業を表示する場所（「設定」の上）に出ます。

<p align="center">
  <img src="../docs/introducer-code.png" width="200" alt="デバイス操作のペアリング: コードがこの iPhone に出る">
  <img src="../docs/introducer-byhand.png" width="200" alt="手で運ぶ形: roamrun devices add に渡す行">
</p>

**Carry the lines by hand**（行を手で運ぶ）は、`--with` を使わない形です。`roamrun pair xcode` が出す `rr-xcode-offer-v1:` の行を貼り付けるか、`roamrun pair xcode --qr` が描くコードから、離れた Mac の名前と一緒に読み取ります。アプリが表示する `rr-device-v1:` の行を、`roamrun devices add` に渡します。問い合わせのできない離れた Mac のための形です。離れた Mac が保存したかどうかを答えなかったときも、アプリはこの行を表示します。

離れた Mac の名前と、この iPhone の Tailscale 上の名前は、アプリを閉じても覚えています。申し出の行は覚えません。その行は、離れた Mac で Pair Nearby Device のシートが開いている間しか使えず、押すたびに別のものになるからです。

アプリが「この iPhone 自身の名乗りが見えなかった」と表示したときは、まず離れた Mac で `roamrun devices` を確かめてください。すでに保存があれば、`roamrun up <name>` でそのまま使えます。なければ、この iPhone を保存している Mac で `roamrun devices export <name>` を実行し、その行を離れた Mac で追加します。「pairing was tried」という表示は、接続がアプリを通ったという意味で、Xcode がコードを受け付けたかどうかは表しません。

## 画面

`Sources/Session.swift` が 1 回の引き合わせ（段階、コード、終わり方）を持ち、`Sources/ContentView.swift` がそれを表示します。最初の画面（最後に引き合わせた離れた Mac、Scan、Edit）、進行中の 3 つの段階、終わり方と、運ぶ行があるときはその行です。離れた Mac なしで画面を見るには、デバッグビルドで次のようにします。

```
SIMCTL_CHILD_INTRODUCER_PREVIEW=pairing xcrun simctl launch booted io.github.mh-mobile.roamrun.introducer
```

（`empty`、`asking`、`pairing`、`code`、`finishing`、`done`、`byhand`、`failed`。）このページの画像は、この見本表示をシミュレータで撮ったものです。名前もコードも架空です。

離れた Mac は、Tailscale が付ける名前で指定します。1 語の名前、`ts.net` で終わる名前、または Tailscale のアドレスです。コードやリンクや名前が何を指していても、問い合わせもペアリングそのものも、Tailscale のものではないアドレスへは行きません。

## デバイスで試したこと

iOS 27 の iPhone 15 Pro と、Tailscale 越しに届く離れた Mac で試しました。Xcode のペアリングを、名前で指す形と `--qr` のコードで。行を手で運ぶ形。デバイス操作のペアリング。それぞれ、メインの README に書いてあるとおりです。iPad と、ほかの iOS の版では試していません。

「設定」からの接続がどこから来たかは、最初に受け付けた 1 本について記録します。
`log stream --level debug --predicate 'subsystem == "io.github.mh-mobile.roamrun.introducer"'`（Mac の「コンソール」でデバイスを選んで見ます）。

アイコンは RoamRun のもので、端まで塗っています: `xcrun swift ../scripts/make-icon.swift --ios Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`。

## この Mac での確認

`Checks/relay-check.swift` は、仕組みの部分を macOS 向けにコンパイルして、試験用の種類 `_rrtest._tcp` で動かします（本物の種類は使いません）。127.0.0.1 で返事をする偽の離れた Mac、断られるよそ者、許された接続の双方向の取り次ぎ、`.carried`、レコードの取り下げ、時間切れを確かめます。

```
xcrun swiftc -swift-version 6 -parse-as-library -o /tmp/relay-check Sources/StandIn.swift Sources/Introduction.swift Sources/Wire.swift Checks/relay-check.swift && /tmp/relay-check
```
