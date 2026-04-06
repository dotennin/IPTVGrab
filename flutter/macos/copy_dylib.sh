#!/bin/bash
# Script to copy the Rust dylib to the app bundle for macOS development

PROJECT_ROOT="/Users/dotennin-mac14/projects/m3u8-downloader-rs"
DYLIB_SRC="$PROJECT_ROOT/target/aarch64-apple-darwin/release/libmobile_ffi.dylib"
DYLIB_DEST="$PROJECT_ROOT/flutter/macos"

# Create destination directory if it doesn't exist
mkdir -p "$DYLIB_DEST"

# Copy the dylib
if [ -f "$DYLIB_SRC" ]; then
  cp "$DYLIB_SRC" "$DYLIB_DEST/libmobile_ffi.dylib"
  echo "✅ Copied libmobile_ffi.dylib to macOS project"
else
  echo "⚠️  Warning: libmobile_ffi.dylib not found at $DYLIB_SRC"
  exit 1
fi
