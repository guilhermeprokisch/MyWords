// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

/* Binds SQLCipher's sqlite3.h (from Homebrew) instead of the system SQLite.
 * SQLCipher exposes the same sqlite3_* API plus encryption (PRAGMA key,
 * sqlite3_key, …). The include path is supplied by the build settings in
 * Package.swift. */
#include <sqlite3.h>
