// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Guilherme Prokisch

import AppKit
import ServiceManagement
import UserNotifications
import MyWordsCore

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let newAppCategory = "mywords.newapp"
    private var statusItem: NSStatusItem!
    private var recorder: Recorder?
    private var database: Database?
    private var redactor: Redactor?
    private let appFilter = AppFilter()
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.mywords.logger"
    private var permissionTimer: Timer?

    private struct AppRef { let bundleID: String; let name: String }

    private lazy var appSupport: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyWords")
    }()
    private lazy var dbURL: URL = appSupport.appendingPathComponent("keystrokes.db")
    private lazy var legacyDBURL: URL = appSupport.appendingPathComponent("keystrokes.sqlite")
    private lazy var redactURL: URL = appSupport.appendingPathComponent("redact.txt")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenuBar()

        do {
            let passphrase = try KeyManager.loadOrCreatePassphrase()
            let db = try Database(path: dbURL, passphrase: passphrase)
            // One-time import of any pre-SQLCipher data (idempotent: the old
            // file is renamed afterwards so this never runs twice).
            let migrated = try Migrator.migrateIfNeeded(
                legacyPath: legacyDBURL,
                legacyKey: try KeyManager.legacyKey(),
                newDB: db
            )
            if migrated > 0 { NSLog("MyWords: migrated \(migrated) records into SQLCipher") }
            self.database = db
            let redactor = Redactor()
            self.redactor = redactor
            migrateLegacyRedactFileIfPresent(into: db)   // move any old redact.txt into the DB
            redactor.setPatterns((try? db.redactionPatterns()) ?? [])
            reloadAppFilter()
            let recorder = Recorder(db: db, redactor: redactor, appFilter: appFilter)
            recorder.onFlush = { [weak self] in self?.refreshMenu() }
            self.recorder = recorder
        } catch {
            presentError("Could not open the encrypted database:\n\(error)")
        }

        // Prompt for Accessibility on first launch, then start once granted.
        Permissions.requestIfNeeded()
        startIfPermitted()
        syncLoginItem()
        refreshMenu()

        // Poll until permission is granted (the user may flip it in Settings
        // while the app is already running).
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.startIfPermitted()
        }

        setUpNewAppNotifications()
        // Track every app you switch to (not only ones you type in), so the
        // picker knows about new apps and the new-app policy can act on them.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil,
        )
    }

    // MARK: - New-app detection

    private func setUpNewAppNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let record = UNNotificationAction(identifier: "record", title: "Record this app")
        let ignore = UNNotificationAction(identifier: "ignore", title: "Keep ignored")
        let category = UNNotificationCategory(identifier: newAppCategory, actions: [record, ignore], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier, bundleID != ownBundleID,
              let database else { return }
        let name = app.localizedName ?? bundleID

        let isNew = database.noteSeenApp(bundleID: bundleID, appName: name)
        if isNew, database.newAppPolicy() == "ask",
           (try? database.appRules())?.contains(where: { $0.bundleID == bundleID }) != true {
            // Block it until the user decides, and let them decide via a balloon.
            try? database.setAppRule(bundleID: bundleID, appName: name, rule: "deny")
            reloadAppFilter()
            postNewAppNotification(bundleID: bundleID, name: name)
        }
        refreshMenu()
    }

    private func postNewAppNotification(bundleID: String, name: String) {
        let content = UNMutableNotificationContent()
        content.title = "New app detected"
        content.body = "MyWords is not recording “\(name)”. Record it?"
        content.categoryIdentifier = newAppCategory
        content.userInfo = ["bundleID": bundleID, "name": name]
        let request = UNNotificationRequest(identifier: "newapp-\(bundleID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Show the balloon even when MyWords happens to be active.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let bundleID = info["bundleID"] as? String, let name = info["name"] as? String, let database {
            if response.actionIdentifier == "record" {
                try? database.setAppRule(bundleID: bundleID, appName: name, rule: "allow")
            }
            // "ignore" (and default dismiss) leave the deny rule in place.
            DispatchQueue.main.async { [weak self] in
                self?.reloadAppFilter()
                self?.refreshMenu()
            }
        }
        completionHandler()
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
    }

    // MARK: - Menu bar

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
    }

    /// Shows a keyboard glyph in the menu bar whose state is obvious at a glance:
    /// filled = recording, outline = paused, warning triangle = needs permission.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if !Permissions.isTrusted {
            symbol = "exclamationmark.triangle.fill"
        } else if recorder?.isPaused ?? false {
            symbol = "keyboard"
        } else {
            symbol = "keyboard.fill"
        }
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MyWords") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            // Fallback if the symbol is unavailable.
            button.image = nil
            button.title = (recorder?.isPaused ?? false) || !Permissions.isTrusted ? "⌨︎…" : "⌨︎"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let db = database {
            let count = NSMenuItem(title: "Segments stored: \(db.count())", action: nil, keyEquivalent: "")
            count.isEnabled = false
            menu.addItem(count)
        }

        menu.addItem(.separator())

        if Permissions.isTrusted {
            let paused = recorder?.isPaused ?? false
            let toggle = NSMenuItem(
                title: paused ? "Resume Recording" : "Pause Recording",
                action: #selector(togglePause),
                keyEquivalent: "p"
            )
            toggle.target = self
            menu.addItem(toggle)
        } else {
            let grant = NSMenuItem(
                title: "Grant Accessibility Permission…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            grant.target = self
            menu.addItem(grant)
        }

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)

        let passphrase = NSMenuItem(title: "Set Passphrase…", action: #selector(setPassphrase), keyEquivalent: "")
        passphrase.target = self
        passphrase.isEnabled = database != nil
        menu.addItem(passphrase)

        // Redaction submenu (pattern count shown in the title).
        let redactCount: Int = {
            guard let database else { return 0 }
            return (try? database.redactionPatterns().count) ?? 0
        }()
        let redactionItem = NSMenuItem(title: "Redaction (\(redactCount))", action: nil, keyEquivalent: "")
        let redactionMenu = NSMenu()

        let addRedact = NSMenuItem(title: "Add Pattern…", action: #selector(addRedactionPattern), keyEquivalent: "")
        addRedact.target = self
        addRedact.isEnabled = database != nil
        redactionMenu.addItem(addRedact)

        let clearRedact = NSMenuItem(title: "Clear Patterns", action: #selector(clearRedactionPatterns), keyEquivalent: "")
        clearRedact.target = self
        clearRedact.isEnabled = database != nil && redactCount > 0
        redactionMenu.addItem(clearRedact)

        redactionMenu.addItem(.separator())

        let scrub = NSMenuItem(title: "Apply to Existing Log", action: #selector(scrubExistingLog), keyEquivalent: "")
        scrub.target = self
        scrub.isEnabled = database != nil && redactor != nil
        redactionMenu.addItem(scrub)

        redactionItem.submenu = redactionMenu
        menu.addItem(redactionItem)

        buildAppsSubmenu(into: menu)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "Reveal Database in Finder", action: #selector(revealDatabase), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About MyWords", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit MyWords", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "MyWords \(version)"
        alert.informativeText = """
        © 2026 Guilherme Prokisch

        A local, encrypted, on-device keystroke logger for your own typing.

        This program comes with ABSOLUTELY NO WARRANTY. It is free software, and \
        you are welcome to redistribute it under the terms of the GNU Affero \
        General Public License, version 3 or later.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "View License")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html") {
            NSWorkspace.shared.open(url)
        }
    }

    private func statusLine() -> String {
        if !Permissions.isTrusted { return "⚠︎ Needs Accessibility permission" }
        if recorder?.isPaused ?? false { return "Paused" }
        return recorder != nil ? "Recording" : "Not running"
    }

    private func refreshMenu() {
        updateStatusIcon()
        rebuildMenu()
    }

    private func startIfPermitted() {
        guard Permissions.isTrusted, let recorder else { return }
        if recorder.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            refreshMenu()
        }
    }

    // MARK: - Launch at login

    private let loginPrefKey = "startAtLoginEnabled"

    /// The user's preference. Defaults to on for the very first launch (the app
    /// was asked to start at login), then follows whatever they last chose.
    private var wantsLoginItem: Bool {
        if UserDefaults.standard.object(forKey: loginPrefKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: loginPrefKey)
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Brings the actual login-item registration in line with the preference.
    /// Registering always targets the *currently running* bundle, so the login
    /// item follows the app if it's moved (e.g. build/ → ~/Applications).
    private func syncLoginItem() {
        do {
            if wantsLoginItem {
                // register() is idempotent and updates the recorded path.
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MyWords: login item sync failed: \(error.localizedDescription)")
        }
    }

    @objc private func toggleLoginItem() {
        UserDefaults.standard.set(!wantsLoginItem, forKey: loginPrefKey)
        syncLoginItem()
        // Some macOS versions park new login items in an "awaiting approval"
        // state; send the user to the settings pane to flip it on.
        if wantsLoginItem, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        refreshMenu()
    }

    // MARK: - Actions

    @objc private func togglePause() {
        guard let recorder else { return }
        recorder.setPaused(!recorder.isPaused)
        refreshMenu()
    }

    @objc private func setPassphrase() {
        guard let database else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Set Database Passphrase"
        alert.informativeText = """
        Choose a passphrase to encrypt your keystroke database. It's saved to \
        your Keychain so recording keeps working automatically, and you can use \
        it to open the database in a SQLCipher tool.

        If you lose it, the data can't be recovered.
        """
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "New passphrase (min 6 characters)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newPass = field.stringValue
        guard newPass.count >= 6 else {
            presentError("Passphrase must be at least 6 characters.")
            return
        }
        do {
            // Re-encrypt in place, then persist the new secret. Order matters:
            // if the Keychain write failed after a successful rekey, the app
            // would lock itself out, so rekey first and only save on success.
            try database.rekey(to: newPass)
            try KeyManager.setPassphrase(newPass)
            let ok = NSAlert()
            ok.messageText = "Passphrase updated"
            ok.informativeText = "The database was re-encrypted with your new passphrase."
            ok.runModal()
        } catch {
            presentError("Could not change the passphrase:\n\(error)")
        }
    }

    private func reloadRedactor() {
        guard let database, let redactor else { return }
        redactor.setPatterns((try? database.redactionPatterns()) ?? [])
    }

    // MARK: - App filtering

    private func reloadAppFilter() {
        guard let database else { return }
        let rules = (try? database.appRules()) ?? []
        appFilter.configure(
            mode: database.captureMode(),
            deny: rules.filter { $0.rule == "deny" }.map(\.bundleID),
            allow: rules.filter { $0.rule == "allow" }.map(\.bundleID),
        )
    }

    private func buildAppsSubmenu(into menu: NSMenu) {
        let appsItem = NSMenuItem(title: "Apps", action: nil, keyEquivalent: "")
        let appsMenu = NSMenu()

        guard let database else {
            appsItem.isEnabled = false
            menu.addItem(appsItem)
            return
        }

        let allowlist = database.captureMode() == "allowlist"
        let modeItem = NSMenuItem(title: "Record only allowed apps", action: #selector(toggleCaptureMode), keyEquivalent: "")
        modeItem.target = self
        modeItem.state = allowlist ? .on : .off
        appsMenu.addItem(modeItem)

        let askItem = NSMenuItem(title: "Ask before recording new apps", action: #selector(toggleNewAppPolicy), keyEquivalent: "")
        askItem.target = self
        askItem.state = database.newAppPolicy() == "ask" ? .on : .off
        appsMenu.addItem(askItem)

        appsMenu.addItem(.separator())
        let header = NSMenuItem(title: allowlist ? "Allowed apps (✓ = recorded)" : "Blocked apps (✓ = recorded)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        appsMenu.addItem(header)

        let rules = (try? database.appRules()) ?? []
        let ruleByBundle = Dictionary(rules.map { ($0.bundleID, $0.rule) }, uniquingKeysWith: { first, _ in first })

        // Apps seen recently, plus any ruled apps not seen lately.
        var refs: [AppRef] = ((try? database.seenApps(limit: 20)) ?? []).map { AppRef(bundleID: $0.bundleID, name: $0.appName) }
        let seen = Set(refs.map(\.bundleID))
        for rule in rules where !seen.contains(rule.bundleID) {
            refs.append(AppRef(bundleID: rule.bundleID, name: rule.appName))
        }
        refs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if refs.isEmpty {
            let empty = NSMenuItem(title: "No apps recorded yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            appsMenu.addItem(empty)
        }
        for ref in refs {
            let item = NSMenuItem(title: ref.name, action: #selector(toggleAppRule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ref
            let rule = ruleByBundle[ref.bundleID]
            item.state = allowlist ? (rule == "allow" ? .on : .off) : (rule == "deny" ? .off : .on)
            appsMenu.addItem(item)
        }

        appsItem.submenu = appsMenu
        menu.addItem(appsItem)
    }

    @objc private func toggleCaptureMode() {
        guard let database else { return }
        do {
            try database.setCaptureMode(database.captureMode() == "allowlist" ? "all" : "allowlist")
            reloadAppFilter()
            refreshMenu()
        } catch {
            presentError("Could not change capture mode:\n\(error)")
        }
    }

    @objc private func toggleNewAppPolicy() {
        guard let database else { return }
        do {
            try database.setNewAppPolicy(database.newAppPolicy() == "ask" ? "record" : "ask")
            refreshMenu()
        } catch {
            presentError("Could not change the new-app policy:\n\(error)")
        }
    }

    @objc private func toggleAppRule(_ sender: NSMenuItem) {
        guard let database, let ref = sender.representedObject as? AppRef else { return }
        let allowlist = database.captureMode() == "allowlist"
        let current = (try? database.appRules())?.first { $0.bundleID == ref.bundleID }?.rule
        // In allowlist mode a click toggles "allow"; otherwise it toggles "deny".
        let target = allowlist ? "allow" : "deny"
        let newRule: String? = current == target ? nil : target
        do {
            try database.setAppRule(bundleID: ref.bundleID, appName: ref.name, rule: newRule)
            reloadAppFilter()
            refreshMenu()
        } catch {
            presentError("Could not change the app rule:\n\(error)")
        }
    }

    /// One-time move of a legacy plaintext redact.txt into the encrypted DB.
    private func migrateLegacyRedactFileIfPresent(into db: Database) {
        guard let content = try? String(contentsOf: redactURL, encoding: .utf8) else { return }
        for line in content.split(separator: "\n") {
            let p = line.trimmingCharacters(in: .whitespaces)
            if p.isEmpty || p.hasPrefix("#") { continue }
            try? db.addRedactionPattern(p)
        }
        try? FileManager.default.removeItem(at: redactURL)
    }

    @objc private func addRedactionPattern() {
        guard let database else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Add Redaction Pattern"
        alert.informativeText = """
        Text matching this is replaced with [REDACTED] before it's stored. The \
        pattern is saved inside the encrypted database, not on disk.

        The field is hidden (a secure field, so these keystrokes aren't captured \
        by macOS). Case-insensitive; a plain word matches literally, or use a \
        regex like \\b\\d{6}\\b. For long regexes you can also edit the \
        `redaction_patterns` table with mywords-sql.
        """
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        // Secure field: masks the secret AND triggers macOS Secure Event Input,
        // so the tap never sees these keystrokes even ignoring the self-check.
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "word or regular expression"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pattern = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return }
        do {
            try database.addRedactionPattern(pattern)
            reloadRedactor()
            refreshMenu()
        } catch {
            presentError("Could not add the pattern:\n\(error)")
        }
    }

    @objc private func clearRedactionPatterns() {
        guard let database else { return }
        NSApp.activate(ignoringOtherApps: true)

        let confirm = NSAlert()
        confirm.messageText = "Clear all redaction patterns?"
        confirm.informativeText = "This removes every pattern. Already-stored data is not affected."
        confirm.addButton(withTitle: "Clear")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try database.clearRedactionPatterns()
            reloadRedactor()
            refreshMenu()
        } catch {
            presentError("Could not clear patterns:\n\(error)")
        }
    }

    @objc private func scrubExistingLog() {
        guard let database, let redactor else { return }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let changed = try database.redactExisting(using: redactor)
            let alert = NSAlert()
            alert.messageText = "Redaction applied"
            alert.informativeText = changed == 0
                ? "No stored segments matched the redaction list."
                : "Scrubbed \(changed) stored segment\(changed == 1 ? "" : "s")."
            alert.runModal()
            refreshMenu()
        } catch {
            presentError("Could not scrub the existing log:\n\(error)")
        }
    }

    @objc private func openAccessibilitySettings() {
        Permissions.requestIfNeeded()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func revealDatabase() {
        NSWorkspace.shared.activateFileViewerSelecting([dbURL])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MyWords"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
