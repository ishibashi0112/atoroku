#!/bin/bash
# あとろくをビルドして iPhone に入れ直す。
#
# 無料の Apple ID（Personal Team）で入れたアプリは7日で起動できなくなるので、週に1回これを実行する。
# 入れ直しても、アプリのデータ（録音ファイルと記録.txt）は残る。
#
# 使い方:
#   scripts/reinstall.sh             いつもの iPhone（下の DEVICE）に入れる
#   scripts/reinstall.sh <UDID>      別の端末に入れる（UDID は `xcrun devicectl list devices` で見る）
#   ATOROKU_CONFIGURATION=Debug scripts/reinstall.sh
#                                    デバッグ版で入れる（ふだんは最適化した Release。電池の計測もこちらで）
#
# 前もって: iPhone を USB か同じ Wi-Fi でつなぎ、ロックを外しておく。
#           `xcrun devicectl list devices` に出ていれば OK。
set -euo pipefail

# このスクリプトの場所（scripts/）の一つ上 = リポジトリの一番上に移る
cd "$(dirname "$0")/.."

DEVICE="${1:-${ATOROKU_DEVICE:-00008150-000C63410E20401C}}"  # 既定は榊原さんの iPhone 17
CONFIGURATION="${ATOROKU_CONFIGURATION:-Release}"
DERIVED_DATA="build/DerivedData"  # ビルドの出力先（.gitignore 済み）
APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/Atoroku.app"

echo "==> ビルド（$CONFIGURATION、端末 $DEVICE）"
# -allowProvisioningUpdates: 期限が切れた署名の情報（プロビジョニングプロファイル）を、
#   Xcode に登録した Apple ID で自動で取り直す。7日ごとの入れ直しに必要。
xcodebuild \
  -project Atoroku.xcodeproj \
  -scheme Atoroku \
  -configuration "$CONFIGURATION" \
  -destination "platform=iOS,id=$DEVICE" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -quiet \
  build

echo "==> iPhone にインストール"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "==> 完了。iPhone で「あとろく」を開いて「開始」を押してください。"
echo "    （初めて入れたときは 設定 > 一般 > VPNとデバイス管理 で開発者を「信頼」する）"
