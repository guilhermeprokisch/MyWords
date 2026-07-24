#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Guilherme Prokisch
# Builds MyWords and assembles a signed .app bundle in ./build/MyWords.app
#
# Usage:
#   ./build.sh [debug|release]   Build the app bundle (default: release)
#   ./build.sh install           Release-build, then install to ~/Applications
set -euo pipefail

cd "$(dirname "$0")"

INSTALL=0
CONFIG="release"
if [ "${1:-}" = "install" ]; then
    INSTALL=1
elif [ -n "${1:-}" ]; then
    CONFIG="$1"
fi
APP="build/MyWords.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINDIR/MyWords" "$APP/Contents/MacOS/MyWords"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ship the core CLI next to the app for convenience. (mywords-stats is an
# optional language-learning tool under examples/ and is intentionally not
# shipped here — build it with `swift build --product mywords-stats`.)
cp "$BINDIR/mywords-export" build/mywords-export

# --- Make the app self-contained -----------------------------------------
# Bundle SQLCipher and its OpenSSL dependency INTO the app so it runs without
# Homebrew. Copy the real dylibs, repoint every load path to @rpath, and add an
# rpath into Contents/Frameworks. They're re-signed with our identity below.
echo "▸ Bundling SQLCipher libraries…"
FRAMEWORKS="$APP/Contents/Frameworks"
BIN="$APP/Contents/MacOS/MyWords"
mkdir -p "$FRAMEWORKS"

SQL_REF="$(otool -L "$BIN" | awk '/libsqlcipher/{print $1; exit}')"
cp -L "$SQL_REF" "$FRAMEWORKS/libsqlcipher.dylib"
chmod u+w "$FRAMEWORKS/libsqlcipher.dylib"

CRY_REF="$(otool -L "$FRAMEWORKS/libsqlcipher.dylib" | awk '/libcrypto/{print $1; exit}')"
cp -L "$CRY_REF" "$FRAMEWORKS/libcrypto.dylib"
chmod u+w "$FRAMEWORKS/libcrypto.dylib"

install_name_tool -id @rpath/libsqlcipher.dylib "$FRAMEWORKS/libsqlcipher.dylib"
install_name_tool -id @rpath/libcrypto.dylib "$FRAMEWORKS/libcrypto.dylib"
install_name_tool -change "$CRY_REF" @rpath/libcrypto.dylib "$FRAMEWORKS/libsqlcipher.dylib"
install_name_tool -change "$SQL_REF" @rpath/libsqlcipher.dylib "$BIN"
install_name_tool -add_rpath @executable_path/../Frameworks "$BIN"

# Sanity check: no Homebrew paths should remain in the executable or libs.
if otool -L "$BIN" "$FRAMEWORKS"/*.dylib | grep -q "/opt/homebrew"; then
    echo "✗ A Homebrew path is still referenced — bundling incomplete:" >&2
    otool -L "$BIN" "$FRAMEWORKS"/*.dylib | grep "/opt/homebrew" >&2
    exit 1
fi

# Pick a STABLE signing identity so the Accessibility permission survives
# rebuilds. macOS keys the grant to the code-signing identity; ad-hoc signing
# changes on every build and resets the grant, so we prefer a real identity.
# Priority: explicit override (MYWORDS_SIGN_ID) → Developer ID → Apple
# Development → ad-hoc fallback.
SIGN_ID="${MYWORDS_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    IDENTITIES="$(security find-identity -v -p codesigning)"
    # Prefer the longer-lived Developer ID cert, then fall back to Apple Development.
    for prefix in "Developer ID Application" "Apple Development"; do
        SIGN_ID="$(printf '%s\n' "$IDENTITIES" \
            | grep -Eo "\"${prefix}[^\"]*\"" | head -1 | tr -d '"')"
        [ -n "$SIGN_ID" ] && break
    done
fi

# Sign inside-out: nested dylibs first, then the app bundle.
if [ -z "$SIGN_ID" ]; then
    echo "▸ No stable identity found — ad-hoc signing (grant resets each rebuild)."
    codesign --force --sign - "$FRAMEWORKS"/*.dylib
    codesign --force --sign - --identifier com.mywords.logger "$APP"
else
    echo "▸ Code signing with: $SIGN_ID"
    # Re-signing the bundled dylibs with our identity gives them the same Team
    # ID as the app, so hardened-runtime library validation is satisfied.
    codesign --force --sign "$SIGN_ID" --options runtime "$FRAMEWORKS"/*.dylib
    codesign --force --sign "$SIGN_ID" --identifier com.mywords.logger \
        --options runtime --entitlements Resources/MyWords.entitlements "$APP"

    # Stably sign the CLI tools too, so their macOS Keychain access grant
    # ("Always Allow") survives rebuilds instead of re-prompting each time.
    # No hardened runtime here on purpose: these link Homebrew's libsqlcipher
    # directly, and library validation would reject its different Team ID.
    codesign --force --sign "$SIGN_ID" build/mywords-export
fi

echo "✓ Built $APP"

if [ "$INSTALL" -eq 1 ]; then
    DEST="$HOME/Applications/MyWords.app"
    echo "▸ Installing to $DEST…"
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    # Verify the copied bundle's signature survived the copy.
    codesign --verify --strict "$DEST" && echo "✓ Installed and signature valid"
    echo
    echo "Run it from its permanent home with:"
    echo "  open \"$DEST\""
    echo
    echo "Because it's signed with the same identity, your Accessibility grant"
    echo "carries over automatically — no need to re-approve."
else
    echo
    echo "Run it with:  open \"$APP\""
    echo "On first launch, grant Accessibility permission when prompted."
    echo "For a permanent install:  ./build.sh install"
fi
