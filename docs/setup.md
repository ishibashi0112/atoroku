# 開発環境の用意

Xcode は macOS でしか動かない。Windows や Linux では iPhone アプリをビルドも実機インストールもできないので、まず Mac が必要。クラウドの Mac は、無料の Apple ID では iPhone を USB でつないで署名・インストールする必要があるため向かない。

## Mac に必要なもの
| 項目 | 内容 |
| --- | --- |
| Mac と macOS | Xcode 27 は Apple シリコンの Mac と macOS Tahoe 26.6 以上が必要（[Apple の要件表](https://developer.apple.com/xcode/system-requirements/)）。Intel の Mac なら Xcode 26.6（Tahoe 26.2 以上）を使う |
| Xcode | App Store から Xcode を入れる（2026-10 時点で 27.1、十数 GB）。初回起動の「Install Required」で共通部品を入れ、Components で iOS を追加する（watchOS は段階5で追加すればよい）。あとからは Xcode > Settings > Components |
| 対応する端末 | Xcode 27 は iOS 15〜27・watchOS 9〜27 向けにビルドでき、実機は iOS 17 以上・watchOS 10 以上に対応する。iPhone 17（iOS 26）も Series 5（watchOS 10）も使える。シミュレーターは iOS 27.1 だが、アプリの最低対応は iOS 26 にする |
| External Agent Access | 初回起動で聞かれる。「While Xcode is Open」にしておく。Claude のビルドと実機インストールは `xcodebuild` と `devicectl` で行うので、この設定には左右されない。あとから Settings > Intelligence で変えられる |
| コマンドライン | `xcodebuild -version` で版が出ることを確認する。「requires Xcode, but active developer directory ... is a command line tools instance」と出たら `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` で Xcode 本体に切り替える。ライセンスのエラーなら `sudo xcodebuild -license accept` |
| Apple ID | Xcode > Settings > Accounts に自分の Apple ID を追加する。Personal Team として表示されれば OK（年会費不要） |
| 空き容量 | Xcode とプラットフォームで 30〜40 GB を見ておく |

## iPhone と Watch
1. iPhone を iOS 26 以上に、Apple Watch を watchOS 10 の最新版に更新する。
2. iPhone を USB で Mac につなぎ、「このコンピュータを信頼」する。`xcrun devicectl list devices` に出れば OK。以後は Wi-Fi でも接続できる。
3. iPhone: 設定 > プライバシーとセキュリティ > デベロッパモード を ON にする（再起動あり）。この項目は最初は隠れていて、Xcode から一度アプリを iPhone で実行しようとしたあとに現れる（つないだだけでは出ないことがある）。
4. Watch: iPhone とペアリング済みなら Xcode に一緒に表示される。Watch 側でもデベロッパモードを求められたら ON にする。
5. 初めて実機にアプリを入れたあと、iPhone の 設定 > 一般 > VPNとデバイス管理 で自分の Apple ID の開発者を「信頼」する。

### 試し用アプリで通しを確かめる
Xcode で試し用の iOS アプリを作り、iPhone で「Hello, world!」が出るまで通すと、署名・デベロッパモード・信頼がまとめて片付く。
- 新しいプロジェクトは Minimum Deployments が端末の iOS より新しいことがあるので、General タブで iOS 26.x にする。
- Bundle Identifier は仮の値（`devplaceholder…` や `com.mycompany.MyApp`）になっているので、`com.ishibashi0112.<名前>` に変える。Signing の「Set Up」画面では変えられないので、Set Up のあと General タブの Identity か Signing & Capabilities で直す。
- Signing & Capabilities で Team を Personal Team にして署名を設定すると、実行先の一覧に iPhone が出る。「Your team has no devices」の警告は、iPhone を実行先に選べば消える。
- 初回の実行では「Copying OS library symbols」が数分出る。iPhone の iOS の情報を Mac にコピーしているだけで、iOS のバージョンごとに1回。
- iPhone に「信頼されていないデベロッパ」と出たら、上の 5. の手順で信頼する。
- 確かめたら試し用アプリは iPhone から消す（1台に3アプリまで）。Bundle ID の登録は7日で10個までなので、試しに何度も作らない。

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

## 用意した環境（2026-10-19）
| 項目 | 内容 |
| --- | --- |
| Mac | MacBook Air 13インチ（Apple M5、24GB）、macOS Tahoe 26.6.2 |
| Xcode | 27.1（Build 27A9275）、iOS 27.1 / 27.0 シミュレーター |
| iPhone | iPhone 17（型番 iPhone18,3）、iOS 26.6.2、デベロッパモード ON。最初は `devicectl` に出ず、つなぎ直して「信頼」したら出た。試し用アプリ `com.ishibashi0112.hello` で実行まで確認 |
