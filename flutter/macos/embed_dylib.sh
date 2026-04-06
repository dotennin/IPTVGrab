#!/bin/bash
# Embed libmobile_ffi.dylib in the app bundle for macOS
# This script is called by Xcode's build system during build phases
# It's safe to fail gracefully if the dylib isn't available

set -e  # Exit on errors

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$(dirname "$PROJECT_DIR")")"

DYLIB_SRC="$REPO_ROOT/target/aarch64-apple-darwin/release/libmobile_ffi.dylib"

# If running from Xcode, use Xcode variables; otherwise assume dev build
if [ -z "$BUILT_PRODUCTS_DIR" ]; then
    # Development/debug - copy to a temporary location
    echo "⚠️  Development build detected - copying to /usr/local/lib"
    mkdir -p /usr/local/lib
    cp "$DYLIB_SRC" /usr/local/lib/libmobile_ffi.dylib 2>/dev/null || {
        echo "⚠️  Failed to copy to /usr/local/lib (may need sudo)"
        exit 0
    }
else
    # Xcode build - embed in app bundle
    DYLIB_DST="$BUILT_PRODUCTS_DIR/$EXECUTABLE_FOLDER_PATH/../Frameworks/libmobile_ffi.dylib"
    
    if [ ! -f "$DYLIB_SRC" ]; then
        echo "⚠️  Warning: libmobile_ffi.dylib not found at $DYLIB_SRC"
        echo "    Run: make flutter-rust-macos"
        exit 0
    fi
    
    # Create Frameworks directory if it doesn't exist
    mkdir -p "$(dirname "$DYLIB_DST")"
    
    # Copy dylib
    cp "$DYLIB_SRC" "$DYLIB_DST"
    chmod +x "$DYLIB_DST"
    
    echo "✅ Embedded libmobile_ffi.dylib in app bundle"
fi

