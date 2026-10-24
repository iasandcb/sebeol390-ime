#!/bin/bash
# Build, test, and install the 세벌식 390 input method.
# Requires Xcode Command Line Tools (swift). Does not use xcodebuild or sudo.
set -euo pipefail
cd "$(dirname "$0")"

echo "== test =="
swift test

echo "== build =="
swift build -c release

APP_DIR="${HOME}/Library/Input Methods"
APP="${APP_DIR}/Sebeol390.app"
BIN=".build/release/Sebeol390"
STAGE="$(mktemp -d)/Sebeol390.app"

mkdir -p "${STAGE}/Contents/MacOS" "${STAGE}/Contents/Resources"
cp "${BIN}" "${STAGE}/Contents/MacOS/Sebeol390"
cp Resources/Info.plist "${STAGE}/Contents/Info.plist"
cp Resources/english-words.txt Resources/english-extra.txt Resources/korean-words.txt Resources/korean-valid.txt Resources/korean-valid.LICENSE "${STAGE}/Contents/Resources/"
printf 'APPL????' > "${STAGE}/Contents/PkgInfo"
chmod +x "${STAGE}/Contents/MacOS/Sebeol390"

codesign --force --sign - --identifier "com.sebeol390.inputmethod.Sebeol390" "${STAGE}"

mkdir -p "${APP_DIR}"
# Replace a previous copy. The system may be holding the old binary.
killall Sebeol390 2>/dev/null || true
rm -rf "${APP}"
cp -R "${STAGE}" "${APP}"
codesign --force --sign - --identifier "com.sebeol390.inputmethod.Sebeol390" "${APP}"

echo "== register =="
"${APP}/Contents/MacOS/Sebeol390" --register || echo "등록 호출이 실패했습니다. 로그아웃 후 시스템 설정에서 직접 추가하세요."

echo "설치됨: ${APP}"
