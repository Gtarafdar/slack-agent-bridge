#!/usr/bin/env bash
#
# Packages the built .app into a distributable .dmg.
#
set -euo pipefail

cd "$(dirname "$0")/.."

DISPLAY_NAME="Slack Agent Bridge"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0)"
APP_DIR="dist/${DISPLAY_NAME}.app"
DMG_PATH="dist/SlackAgentBridge-${VERSION}.dmg"

if [[ ! -d "${APP_DIR}" ]]; then
  echo "error: ${APP_DIR} not found — run ./scripts/build_app.sh first" >&2
  exit 1
fi

echo "==> Staging DMG contents"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp -R "${APP_DIR}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

echo "==> Creating ${DMG_PATH}"
rm -f "${DMG_PATH}"
hdiutil create \
  -volname "${DISPLAY_NAME}" \
  -srcfolder "${STAGE}" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "${DMG_PATH}" >/dev/null

mkdir -p docs/downloads
cp "${DMG_PATH}" "docs/downloads/SlackAgentBridge-${VERSION}.dmg"

SIZE="$(du -h "${DMG_PATH}" | cut -f1 | tr -d ' ')"
echo ""
echo "Built: ${DMG_PATH} (${SIZE})"
echo "Test:  open \"${DMG_PATH}\""
