# atoroku

さかのぼり録音 × 端末内の日本語文字起こし × Claude で整理、の iPhone + Apple Watch アプリ。計画と背景は `docs/concept.md`、環境の用意は `docs/setup.md`。

## 絶対ルール
- 音声は iPhone の外に出さない。Claude（Anthropic API）に送るのは文字だけ。
- サーバーを持たない。API キーは利用者自身のもので、Keychain に保存して端末から直接呼ぶ。
- 無料の Apple ID（Personal Team）で動く範囲で作る: プッシュ通知・iCloud・TestFlight は使わない。
- 録音はバックグラウンドから開始できない前提で設計する（朝に前面で開始し、`audio` バックグラウンドモードで続ける）。Watch はボタンだけで、マイクにしない。
- マイクは iPhone 本体に固定する（Bluetooth イヤホンのマイクは使わない。イヤホンは A2DP の再生専用）。
- 音声・文字起こし・要約の保存期間は設定で変えられるようにし、固定した録音は消さない。

## 技術
- Swift / SwiftUI。Expo / React Native は使わない（Watch アプリ、バックグラウンド音声、SpeechAnalyzer、App Intents がどれも Swift 側に必要なため）。
- iPhone: iOS 26 以上。文字起こしは SpeechAnalyzer / SpeechTranscriber（端末内）。精度が足りなければ WhisperKit に差し替えられる境界を置く。
- Watch: watchOS 10 を対象（Series 5 の上限）。WatchConnectivity の `transferUserInfo` で合図を送る。
- リングバッファはメモリではなく、1分ごとの音声ファイル（AAC、16kHz モノラル）をストレージに書いて古いものから消す。
- 保管は SwiftData。Claude は構造化出力（JSON）で受け、不明な箇所は「？」を付けて作文させない。
- 利用者は Swift が初めてなので、コードには読めるように日本語のコメントを多めに書く。

## 進め方
- 段階は `docs/concept.md` の「MVP と段階」の順（0 計測 → 1 iPhone 単体 → 2 文字起こし → 3 Claude → 4 入口 → 5 Watch → 6 磨き）。段階3のあとに続けるかを判断する。
- ビルドと実機確認は利用者の Mac（Xcode 27、アプリの最低対応は iOS 26）で行う。無料アカウントのアプリは7日で起動できなくなるので、`xcodebuild` + `devicectl` の再インストールを1本のスクリプトにしておく。
- 各段階の計測結果は `docs/stageN.md` に残す。
