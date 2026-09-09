#!/usr/bin/env bash
# ==============================================================================
# CodeLiteX - Release Manifest & Checksum Generator (Phase 11.1 & 11.2)
# ==============================================================================
# Generates version.json with SHA256 hashes and platform release strategies (D3).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$WORKSPACE_ROOT/dist/release"
MANIFEST_FILE="$DIST_DIR/version.json"
VERSION="${VERSION:-0.2.0}"
RELEASE_DATE="$(date +%Y-%m-%d)"

echo "================================================================================"
echo "           📦 Generating CodeLiteX Release Manifest: version.json"
echo "================================================================================"

mkdir -p "$DIST_DIR"

compute_sha256() {
  local file="$1"
  if [ -f "$file" ]; then
    if command -v shasum &>/dev/null; then
      shasum -a 256 "$file" | cut -d' ' -f1
    elif command -v sha256sum &>/dev/null; then
      sha256sum "$file" | cut -d' ' -f1
    else
      echo "0000000000000000000000000000000000000000000000000000000000000000"
    fi
  else
    echo "0000000000000000000000000000000000000000000000000000000000000000"
  fi
}

get_size() {
  local file="$1"
  if [ -f "$file" ]; then
    wc -c < "$file" | tr -d ' '
  else
    echo "0"
  fi
}

MACOS_DYLIB="$DIST_DIR/macos/libcodelite.dylib"
MACOS_APP="$DIST_DIR/macos/code-lite-app"
MACOS_DYLIB_SHA="$(compute_sha256 "$MACOS_DYLIB")"
MACOS_DYLIB_SIZE="$(get_size "$MACOS_DYLIB")"

LINUX_SO="$DIST_DIR/linux/CodeLiteX-linux-x64/lib/libcodelite.so"
LINUX_APP="$DIST_DIR/linux/CodeLiteX-linux-x64/bin/code-lite-app"
LINUX_SO_SHA="$(compute_sha256 "$LINUX_SO")"
LINUX_SO_SIZE="$(get_size "$LINUX_SO")"

cat << EOF > "$MANIFEST_FILE"
{
  "version": "${VERSION}",
  "release_date": "${RELEASE_DATE}",
  "release_notes": "### CodeLiteX v${VERSION}\n- Phase 11: Cross-platform packaging & differential auto-updater\n- Phase 10: Unified Context Engine, Memory Store & Prompt-first Skills\n- Preserved macOS code signatures via Sparkle-style AppBundleDelta\n- Fine-grained Linux/Windows ComponentDelta with automated rollback",
  "min_compatible_version": "0.1.0",
  "platforms": {
    "macos": {
      "strategy": "app_bundle_delta",
      "artifacts": [
        {
          "target_name": "libcodelite.dylib",
          "target_path": "Contents/Frameworks/libcodelite.dylib",
          "url": "https://releases.codelitex.org/v${VERSION}/macos/libcodelite.dylib",
          "sha256": "${MACOS_DYLIB_SHA}",
          "size_bytes": ${MACOS_DYLIB_SIZE}
        }
      ],
      "installer_url": "https://releases.codelitex.org/v${VERSION}/macos/CodeLiteX.dmg"
    },
    "linux": {
      "strategy": "component_delta",
      "artifacts": [
        {
          "target_name": "libcodelite.so",
          "target_path": "lib/libcodelite.so",
          "url": "https://releases.codelitex.org/v${VERSION}/linux/libcodelite.so",
          "sha256": "${LINUX_SO_SHA}",
          "size_bytes": ${LINUX_SO_SIZE}
        }
      ],
      "installer_url": "https://releases.codelitex.org/v${VERSION}/linux/codelitex_${VERSION}-1_amd64.deb"
    },
    "windows": {
      "strategy": "component_delta",
      "artifacts": [
        {
          "target_name": "codelite.dll",
          "target_path": "codelite.dll",
          "url": "https://releases.codelitex.org/v${VERSION}/windows/codelite.dll",
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
          "size_bytes": 0
        }
      ],
      "installer_url": "https://releases.codelitex.org/v${VERSION}/windows/CodeLiteX-Setup-${VERSION}.exe"
    }
  }
}
EOF

echo "✓ Manifest successfully written to: $MANIFEST_FILE"
cat "$MANIFEST_FILE"
echo ""
