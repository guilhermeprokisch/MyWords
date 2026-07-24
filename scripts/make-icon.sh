#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Guilherme Prokisch
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

( cd "$work" && swift "$root/scripts/make-icon.swift" )
iconutil -c icns "$work/AppIcon.iconset" -o "$root/Resources/AppIcon.icns"
echo "✓ wrote Resources/AppIcon.icns"
