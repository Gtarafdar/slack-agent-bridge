#!/usr/bin/env bash
# Generates AppIcon.icns and menu-bar PNGs from Resources/AppIcon-1024.png
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Resources/AppIcon-1024.png"
MENU_SRC="Resources/MenuBarIcon-source.png"
ICONSET="Resources/AppIcon.iconset"

if [[ ! -f "${SRC}" ]]; then
  echo "error: missing ${SRC}" >&2
  exit 1
fi

echo "==> Building AppIcon.iconset"
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"

for base in 16 32 128 256 512; do
  sips -z "${base}" "${base}" "${SRC}" --out "${ICONSET}/icon_${base}x${base}.png" >/dev/null
  double=$((base * 2))
  sips -z "${double}" "${double}" "${SRC}" --out "${ICONSET}/icon_${base}x${base}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET}" -o "Resources/AppIcon.icns"
rm -rf "${ICONSET}"
echo "    Resources/AppIcon.icns"

if [[ -f "${MENU_SRC}" ]]; then
  echo "==> Menu bar template icons"
  sips -z 18 18 "${MENU_SRC}" --out "Resources/MenuBarIcon.png" >/dev/null
  sips -z 36 36 "${MENU_SRC}" --out "Resources/MenuBarIcon@2x.png" >/dev/null
  echo "    Resources/MenuBarIcon.png (+ @2x)"
fi

echo "==> In-app branding sizes"
sips -z 64 64 "${SRC}" --out "Resources/AppIcon-64.png" >/dev/null
sips -z 128 128 "${SRC}" --out "Resources/AppIcon-128.png" >/dev/null
echo "Done."
