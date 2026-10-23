#!/usr/bin/env bash
# 在 macOS 上編出未簽名的 VoAssist IPA（給自己用證書重簽）。
# 使用：bash scripts/build-ios.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- 換成自己的識別碼（App 與擴充、App Group 必須一致）----
OLD_ID="com.zdyi.voassist"
NEW_ID="${VOASSIST_BUNDLE_PREFIX:-com.wentsy.voassist}"

files=$(grep -rl "$OLD_ID" . \
  --include='*.swift' --include='*.yml' --include='*.plist' --include='*.entitlements' \
  --exclude-dir=build --exclude-dir=.git || true)
for f in $files; do
  sed -i '' "s/${OLD_ID}/${NEW_ID}/g" "$f"
done
# 未簽名流程不帶團隊身分
sed -i '' '/DEVELOPMENT_TEAM/d' project.yml || true

echo "== 識別碼 =="
grep -n "${NEW_ID}" project.yml | head -8

# ---- 產生工程並編譯 ----
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

xcodebuild \
  -project VoAssist.xcodeproj \
  -scheme VoAssist \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

# ---- 打包 ----
APP="build/Build/Products/Release-iphoneos/VoAssist.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist")
NAME="VoAssist_ios_${VERSION}+${BUILD}_unsigned.ipa"

rm -rf Payload
mkdir -p Payload
cp -R "$APP" Payload/
zip -r9 "$NAME" Payload

echo "== 打包完成：$NAME =="
unzip -l "$NAME" | grep -E 'PlugIns|\.appex' | head -5 || true
