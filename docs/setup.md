# 開発環境の用意

Xcode は macOS でしか動かない。Windows や Linux では iPhone アプリをビルドも実機インストールもできないので、まず Mac が必要。クラウドの Mac は、無料の Apple ID では iPhone を USB でつないで署名・インストールする必要があるため向かない。

## Mac に必要なもの
| 項目 | 内容 |
| --- | --- |
| macOS | Xcode 26.0〜26.3 は macOS Sequoia 15.6 以上、Xcode 26.4 以降は macOS Tahoe 26.2 以上（[Xcode のバージョン一覧](https://mungomash.com/software/xcode/versions/)） |
| Xcode | App Store から Xcode 26 を入れる（十数 GB、時間がかかる）。初回起動で iOS 26 と watchOS のプラットフォームを追加する（Xcode > Settings > Components） |
| コマンドライン | `sudo xcodebuild -license accept`、`xcode-select -p` で Xcode を指していることを確認 |
| Apple ID | Xcode > Settings > Accounts に自分の Apple ID を追加する。Personal Team として表示されれば OK（年会費不要） |
| 空き容量 | Xcode とプラットフォームで 30〜40 GB を見ておく |

## iPhone と Watch
1. iPhone を iOS 26 に、Apple Watch を watchOS 10 の最新版に更新する。
2. iPhone: 設定 > プライバシーとセキュリティ > デベロッパモード を ON にする（再起動あり）。
3. iPhone を USB で Mac につなぎ、「このコンピュータを信頼」する。Xcode の Window > Devices and Simulators に表示されれば OK。以後は Wi-Fi でも接続できる。
4. Watch: iPhone とペアリング済みなら Xcode に一緒に表示される。Watch 側でもデベロッパモードを求められたら ON にする。
5. 初めて実機にアプリを入れたあと、iPhone の 設定 > 一般 > VPNとデバイス管理 で自分の Apple ID の開発者を「信頼」する。

## 無料アカウントの制限
- アプリは7日で起動できなくなる。週に1回 Mac につないで入れ直す（データは残る）。`scripts/reinstall.sh` を段階0で用意する（`xcodebuild -scheme Atoroku -destination 'platform=iOS,id=<UDID>' build` → `xcrun devicectl device install app --device <UDID> <path>.app`）。
- 端末あたり3アプリ、アプリ ID は10個まで。Bundle ID は `com.<name>.atoroku` のように固定して増やさない。
- プッシュ通知・iCloud・TestFlight は使えない（この設計では不要）。

## 確認コマンド
```sh
xcodebuild -version
xcrun devicectl list devices
```

## Claude との作業
Claude は Remote Control で利用者の Mac に入って、この リポジトリの中で作業する。Mac 側で Claude デスクトップアプリから Remote Control を有効にし、このリポジトリのフォルダを許可する。ビルド・実機インストール・計測はすべて Mac 側で行う。
