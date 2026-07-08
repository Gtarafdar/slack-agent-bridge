#!/usr/bin/env bash
#
# Builds Slack Agent Bridge as a universal (arm64 + x86_64) macOS .app bundle.
# Uses ad-hoc signing only — no Apple Developer Program / notarization required.
#
# Usage:
#   ./scripts/build_app.sh
#   CONFIG=debug ./scripts/build_app.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SlackAgentBridge"
DISPLAY_NAME="Slack Agent Bridge"
CONFIG="${CONFIG:-release}"
OUTPUT_DIR="dist"
APP_DIR="${OUTPUT_DIR}/${DISPLAY_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "==> Building universal binary (arm64 + x86_64), config=${CONFIG}"
swift build -c "${CONFIG}" --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c "${CONFIG}" --arch arm64 --arch x86_64 --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "error: built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> Assembling ${APP_DIR}"
mkdir -p "${OUTPUT_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

if [[ ! -f "Resources/AppIcon.icns" ]]; then
  ./scripts/generate_icons.sh
fi

cp "${BIN_PATH}" "${MACOS_DIR}/${APP_NAME}"
cp "Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

for asset in AppIcon.icns AppIcon-64.png AppIcon-128.png MenuBarIcon.png MenuBarIcon@2x.png; do
  if [[ -f "Resources/${asset}" ]]; then
    cp "Resources/${asset}" "${RESOURCES_DIR}/${asset}"
  fi
done

# First-open instructions for Gatekeeper (ad-hoc builds)
cat > "${RESOURCES_DIR}/FirstOpen.txt" <<'EOF'
Slack Agent Bridge — first open on macOS

This build is ad-hoc signed (no paid Apple Developer certificate).
That is normal for free, local open-source Mac apps.

If Gatekeeper blocks the app:
1. Right-click Slack Agent Bridge → Open → Open
   or
2. System Settings → Privacy & Security → Open Anyway

You will not be asked for an Apple Developer login.
EOF

echo "==> Verifying architectures"
lipo -info "${MACOS_DIR}/${APP_NAME}" || true

echo "==> Ad-hoc code signing (no Developer ID / notarization)"
codesign --force --deep --sign - "${APP_DIR}"
touch "${APP_DIR}"

echo ""
echo "Built: ${APP_DIR}"
echo "Run:   open \"${APP_DIR}\""
echo ""
echo "Distribution note:"
echo "  This project ships ad-hoc signed so you do not need a yearly Apple Developer Program fee."
echo "  Users open it via right-click → Open (same pattern as many free Mac utilities)."
echo "  Optional paid notarization is undocumented here on purpose — it is not required for personal use."
