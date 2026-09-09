#!/usr/bin/env bash
# ==============================================================================
# CodeLiteX - Production macOS Release & Packaging Script
# ==============================================================================
# This script:
# 1. Compiles Rust Core C-ABI release dynamic library (libcodelite.dylib).
# 2. Compiles Rust Core Release Daemon binary (code-lite-app).
# 3. Stages artifacts into dist/release/macos/.
# 4. If full Xcode is installed (xcodebuild available):
#    - Builds Flutter macOS Release Application bundle (CodeLiteX.app).
#    - Embeds libcodelite.dylib into CodeLiteX.app/Contents/Frameworks/.
#    - Updates dylib install name and rpaths using install_name_tool.
#    - Signs the application bundle using ad-hoc codesign.
# 5. If Xcode is not installed (CommandLineTools only):
#    - Explains that full Xcode.app is required for Flutter desktop bundling,
#      while staging standalone release binaries in dist/release/macos/.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLUTTER_APP_DIR="$WORKSPACE_ROOT/apps/code_lite_ui"
FLUTTER_BIN="${FLUTTER_BIN:-/Users/dev/development/flutter/bin/flutter}"
DIST_DIR="$WORKSPACE_ROOT/dist/release/macos"

export PATH="$HOME/.cargo/bin:$PATH"

echo "================================================================================"
echo "           🚀 Packaging CodeLiteX Standalone macOS Application 🚀"
echo "================================================================================"
echo "Workspace Root:    $WORKSPACE_ROOT"
echo "Flutter Directory: $FLUTTER_APP_DIR"
echo "Output Directory:  $DIST_DIR"
echo ""

mkdir -p "$DIST_DIR"

# Step 1: Build Rust Core C-ABI dynamic library in release mode
echo "[1/4] Building Rust Core C-ABI (libcodelite.dylib) in Release mode..."
cd "$WORKSPACE_ROOT"
cargo build --release --offline -p code-lite-ffi

DYLIB_SOURCE="$WORKSPACE_ROOT/target/release/libcodelite.dylib"
if [ ! -f "$DYLIB_SOURCE" ]; then
  echo "❌ Error: Release dynamic library not found at $DYLIB_SOURCE" >&2
  exit 1
fi
cp -f "$DYLIB_SOURCE" "$DIST_DIR/libcodelite.dylib"
echo "  ✓ Compiled & Staged: $DIST_DIR/libcodelite.dylib ($(du -h "$DYLIB_SOURCE" | cut -f1))"
echo ""

# Step 2: Build Rust Core Daemon binary in release mode
echo "[2/4] Building Rust Core Daemon (code-lite-app) in Release mode..."
cargo build --release --offline -p code-lite-app

APP_BINARY_SOURCE="$WORKSPACE_ROOT/target/release/code-lite-app"
if [ ! -f "$APP_BINARY_SOURCE" ]; then
  echo "❌ Error: Release binary not found at $APP_BINARY_SOURCE" >&2
  exit 1
fi
cp -f "$APP_BINARY_SOURCE" "$DIST_DIR/code-lite-app"
echo "  ✓ Compiled & Staged: $DIST_DIR/code-lite-app ($(du -h "$APP_BINARY_SOURCE" | cut -f1))"
echo ""

# Step 3: Check Xcode toolchain for Flutter macOS App bundle
echo "[3/4] Checking macOS build toolchain (xcodebuild)..."
HAS_XCODE=false
if command -v xcrun &>/dev/null && xcrun --find xcodebuild &>/dev/null; then
  HAS_XCODE=true
  echo "  ✓ Full Xcode toolchain detected."
else
  echo "  ⚠️ Note: 'xcodebuild' utility not found (CommandLineTools active without full Xcode.app)."
  echo "    To build the graphical .app bundle, install Xcode from Mac App Store and run:"
  echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi
echo ""

# Step 4: Build & package Flutter macOS Application (if Xcode available)
echo "[4/4] Finalizing packaging..."
if [ "$HAS_XCODE" = true ]; then
  echo "Building Flutter macOS Application bundle..."
  cd "$FLUTTER_APP_DIR"
  "$FLUTTER_BIN" build macos --release

  APP_PATH="$FLUTTER_APP_DIR/build/macos/Build/Products/Release/CodeLiteX.app"
  if [ ! -d "$APP_PATH" ]; then
    APP_PATH="$FLUTTER_APP_DIR/build/macos/Build/Products/Release/code_lite_ui.app"
  fi

  if [ -d "$APP_PATH" ]; then
    FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
    mkdir -p "$FRAMEWORKS_DIR"
    cp -f "$DYLIB_SOURCE" "$FRAMEWORKS_DIR/libcodelite.dylib"
    chmod 755 "$FRAMEWORKS_DIR/libcodelite.dylib"

    install_name_tool -id "@rpath/libcodelite.dylib" "$FRAMEWORKS_DIR/libcodelite.dylib"

    BINARY_NAME="$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleExecutable 2>/dev/null || echo "CodeLiteX")"
    EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$BINARY_NAME"
    if [ -f "$EXECUTABLE_PATH" ]; then
      if ! otool -l "$EXECUTABLE_PATH" | grep -q "@executable_path/../Frameworks"; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE_PATH" || true
      fi
    fi

    if command -v codesign &>/dev/null; then
      codesign --force --deep --sign - "$FRAMEWORKS_DIR/libcodelite.dylib"
      codesign --force --deep --sign - "$APP_PATH"
      echo "  ✓ Ad-hoc codesign applied"
    fi

    cp -R "$APP_PATH" "$DIST_DIR/"
    echo "  ✓ Bundled standalone application: $DIST_DIR/$(basename "$APP_PATH")"
  fi
else
  echo "  ✓ Standalone release artifacts packaged into: $DIST_DIR/"
  ls -lh "$DIST_DIR"
fi

echo ""
echo "================================================================================"
echo "🎉 CodeLiteX Release Packaging Completed Successfully!"
echo "Artifacts located in: $DIST_DIR"
echo "================================================================================"
