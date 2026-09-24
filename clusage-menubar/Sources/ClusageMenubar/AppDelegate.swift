/// AppDelegate.swift — status item, menu wiring, and refresh cadence.
///
/// Plain AppKit; no SwiftUI. The status item hosts a custom StatusBarView subview
/// so we get pixel-precise Stats-style layout. The NSMenu is rebuilt on every open
/// (menuNeedsUpdate delegate) so the dropdown always shows fresh data: one drawn
/// card per provider (MenuCardView, fed by ClusageCore.UsageCard), then actions.
///
/// Three refresh lanes share one cadence: the claude.ai limit fetch (UsageFetcher),
/// the Codex local session-log scan (CodexScanner), and the ChatGPT monthly
/// spend-control fetch (CodexPlanFetcher). The Codex lanes are no-ops on Macs
/// without a Codex install — the scanner degrades before touching the network,
/// and the plan fetcher stops at the missing ~/.codex/auth.json.

import AppKit
import ClusageCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // MARK: - Ivars

    private var statusItem: NSStatusItem!
    private var statusView: StatusBarView!
    private let fetcher = UsageFetcher()
    private let planFetcher = CodexPlanFetcher()
    private var latestState: FetchState?
    private var latestCodexState: CodexScanState?
    private var latestPlanState: CodexPlanState?
    private var refreshTimer: Timer?
    /// Minute tick that repaints the countdowns in the Remaining and Center Dash
    /// layouts; display only.
    private var countdownTimer: Timer?
    /// Guards against overlapping scans. A cold scan runs for tens of seconds
    /// while the timer, wake, ⌘R and every provider toggle all call refreshAll(),
    /// so without this two scans parse the same files, each occupy a utility
    /// thread in synchronous file I/O, and can land out of order — a slow older
    /// scan overwriting latestCodexState with staler data than is on screen.
    private var scanInFlight = false

    // MARK: - applicationDidFinishLaunching

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        setupFetcher()
        setupRefreshTimer()
        setupWakeObserver()

        // Initial fetch — menu bar shows "–" until the first response arrives.
        refreshAll()
        // First run: no cookie stored → open the paste dialog once, after launch settles.
        // WHY DispatchQueue.main.async: gives AppKit time to finish setting up the status
        // item before we show an alert; calling runModal() during launch can hang the app.
        if CookieStore.load() == nil && statusView.visibility.claude {
            DispatchQueue.main.async { self.promptForCookie() }
        }
    }

    // MARK: - Main menu

    private func setupMainMenu() {
        // WHY: LSUIElement apps have no main menu by default. Without one, key
        // equivalents like ⌘V have no NSMenuItem to route through, so paste is
        // silently swallowed even when an NSTextField has keyboard focus.
        // A minimal Edit menu with the standard text actions fixes this.
        let mainMenu = NSMenu()

        // macOS requires a first item whose submenu is the application menu.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut",        action: #selector(NSText.cut(_:)),       keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",       action: #selector(NSText.copy(_:)),      keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",      action: #selector(NSText.paste(_:)),     keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        // Custom view: draw inside the button's bounds. hitTest returns nil so
        // clicks fall through to the button → opens the menu.
        statusView = StatusBarView(frame: button.bounds)
        statusView.style = MenuBarStyleStore.load()
        setupCountdownTimer()
        statusView.visibility = ProviderVisibilityStore.load()
        statusView.codexShowsDollars = CodexDisplayStore.showsDollars()
        statusView.codexBudget = CodexBudgetStore.load()
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)

        // Menu opens on click (standard NSStatusItem behaviour).
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Fetcher wiring

    private func setupFetcher() {
        fetcher.onUpdate = { [weak self] state in
            // Called on main thread by UsageFetcher.fetchNow().
            guard let self else { return }
            self.latestState = state
            self.applyState(state)
        }
        planFetcher.onUpdate = { [weak self] state in
            guard let self else { return }
            self.latestPlanState = state
            if case .ok(let usage, _) = state {
                self.statusView.codexPlan = usage
            } else {
                self.statusView.codexPlan = nil
            }
            self.redraw()
        }
    }

    /// Kick the lanes for visible providers only. A hidden provider costs
    /// nothing: no claude.ai request, and no filesystem scan (the expensive one).
    /// Re-enabling a provider refreshes it immediately, so the pause is invisible.
    ///
    /// The Codex lanes also require an actual install. Without that gate, a Mac
    /// with ~/.codex/auth.json but no sessions (signed in, logs cleaned up) would
    /// send a Bearer-authenticated request to an undocumented endpoint on every
    /// refresh, forever, while the UI never shows the result.
    private func refreshAll() {
        let visibility = ProviderVisibilityStore.load()
        if visibility.claude {
            fetcher.fetchNow()
        }
        if visibility.codex && CodexScanner.isCodexInstalled() {
            planFetcher.fetchNow()
            scanCodexNow()
        }
    }

    /// Run the blocking filesystem scan off the main thread, then apply on main.
    /// WHY Task.detached: the first-ever scan reads hundreds of MB of session
    /// logs; inheriting the main actor would freeze the menu bar for seconds.
    private func scanCodexNow() {
        guard !scanInFlight else { return }
        scanInFlight = true
        Task.detached(priority: .utility) {
            let state = CodexScanner.shared.scan()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanInFlight = false
                self.latestCodexState = state
                self.applyCodexState(state)
            }
        }
    }

    private func applyState(_ state: FetchState) {
        switch state {
        case .ok(let snap, _):
            statusView.snapshot = snap
            statusView.resetDate = snap.session?.resetsAt
            statusView.isDegraded = false
        case .degraded:
            statusView.snapshot = nil
            statusView.isDegraded = true
        }
        redraw()
    }

    private func applyCodexState(_ state: CodexScanState) {
        switch state {
        case .ok(let summary, _):
            statusView.codexSummary = summary
        case .degraded:
            statusView.codexSummary = nil
        }
        redraw()
    }

    private func redraw() {
        // One reference date per repaint: preferredWidth() measures the countdown
        // text and draw() renders it, so two separate Date() reads could straddle
        // a minute boundary and clip "1h" into "59m".
        statusView.renderDate = Date()
        statusView.needsDisplay = true
        statusItem.length = statusView.preferredWidth()
    }

    // MARK: - Refresh cadence

    private func setupRefreshTimer() {
        // Cadence comes from RefreshIntervalStore (user-selectable via the
        // "Refresh Every" submenu); it defaults to the historical 5-min value.
        // WHY invalidate() first: this is also called from setRefreshInterval(_:)
        // when the user picks a new interval, so it must be safe to re-enter.
        refreshTimer?.invalidate()
        let seconds = TimeInterval(RefreshIntervalStore.load() * 60)
        // WHY Task { @MainActor in }: Timer callbacks are nonisolated from Swift 6's static
        // perspective even though scheduledTimer runs on the main run loop. The Task hop is
        // a no-op at runtime (already on main) but satisfies the type system without using
        // DispatchQueue.main.async (which is unstructured and harder to reason about).
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAll() }
        }
        // Proportional slack lets the OS batch with other timers (saves battery);
        // 10% preserves the previous 30s-at-5-min ratio at every interval.
        timer.tolerance = seconds * 0.1
        refreshTimer = timer
    }

    /// The Remaining and Center Dash layouts show "↻19m" countdowns, which go
    /// stale between data refreshes; repaint each minute while either is active.
    /// No I/O.
    private func setupCountdownTimer() {
        countdownTimer?.invalidate()
        guard statusView.style == .remaining || statusView.style == .centerDash else {
            countdownTimer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.redraw() }
        }
        timer.tolerance = 5
        countdownTimer = timer
    }

    private func setupWakeObserver() {
        // Re-fetch immediately after wake: usage data is likely stale post-sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func onWake() {
        refreshAll()
    }

    // MARK: - NSMenuDelegate

    /// Rebuild the menu every time the user opens it so everything is fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Cards mirror the menu bar: a hidden provider is absent here too.
        // Codex additionally needs an install to have anything to report, so a
        // Claude-only Mac sees a single Claude card and no Codex items.
        let visibility = ProviderVisibilityStore.load()
        let showCodexSection = visibility.codex && CodexScanner.isCodexInstalled()
        let showClaudeSection = visibility.claude || !showCodexSection
        let now = Date()

        if showClaudeSection {
            addView(MenuCardView(card: claudeCard(now: now)), to: menu)
            // Center Dash overlays two windows on one track, so it needs a key.
            if statusView.style == .centerDash { addView(MenuBarKeyView(), to: menu) }
        }
        if showCodexSection {
            if showClaudeSection { menu.addItem(.separator()) }
            addView(MenuCardView(card: codexCard(now: now)), to: menu)
        }

        menu.addItem(.separator())
        addRefreshItem(to: menu)
        if showClaudeSection { addOpenURLItem(to: menu, title: "Open Claude Usage", url: Self.claudeUsageURL) }
        if showCodexSection { addOpenURLItem(to: menu, title: "Open Codex Usage", url: Self.codexUsageURL) }
        // Settings shares this section rather than Quit's: macOS 26 gives Quit
        // an automatic icon, and an icon indents every item in its section.
        addSettingsItem(to: menu, showClaude: showClaudeSection, showCodex: showCodexSection)
        menu.addItem(.separator())
        addQuitItem(to: menu)
    }

    /// Preferences sit one level down so the top level is usage plus actions,
    /// the split dedicated trackers use: with the cards on top, six preference
    /// rows at the top level pushed the menu toward the height of a laptop
    /// screen. Each group keeps its own submenu, so every path is unchanged
    /// apart from the Settings prefix (Settings → Menu Bar Layout → …).
    private func addSettingsItem(to menu: NSMenu, showClaude: Bool, showCodex: Bool) {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        addRefreshIntervalItem(to: submenu)
        addMenuBarLayoutItem(to: submenu)
        addShowInMenuBarItem(to: submenu)
        if showCodex { addCodexColumnItem(to: submenu) }
        submenu.addItem(.separator())
        if showClaude { addSetCookieItem(to: submenu) }
        addLaunchAtLoginItem(to: submenu)
        parent.submenu = submenu
        menu.addItem(parent)
    }

    // MARK: - Menu helpers

    private static let claudeUsageURL = URL(string: "https://claude.ai/settings/usage")!
    private static let codexUsageURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    private func addDisabledRow(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    /// A drawn item (card or key). Disabled so arrow-key navigation skips
    /// straight to the actions; the view draws the same either way.
    private func addView(_ view: NSView, to menu: NSMenu) {
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        menu.addItem(item)
    }

    private func claudeCard(now: Date) -> UsageCard {
        switch latestState {
        case .ok(let snap, let updatedAt)?:
            return claudeUsageCard(snapshot: snap, failureReason: nil, updatedAt: updatedAt, now: now)
        case .degraded(let reason, let updatedAt)?:
            return claudeUsageCard(snapshot: nil, failureReason: reason, updatedAt: updatedAt, now: now)
        case nil:
            return claudeUsageCard(snapshot: nil, failureReason: nil, updatedAt: nil, now: now)
        }
    }

    /// Joins the two Codex lanes: the session-log scan owns the freshness line,
    /// since it is what the cost tiles and chart come from.
    private func codexCard(now: Date) -> UsageCard {
        var summary: CodexSummary?
        var scanFailed = false
        var updatedAt: Date?
        switch latestCodexState {
        case .ok(let s, let at)?:   summary = s; updatedAt = at
        case .degraded(_, let at)?: scanFailed = true; updatedAt = at
        case nil:                   break
        }
        var plan: CodexPlanUsage?
        var planFailure: String?
        switch latestPlanState {
        case .ok(let p, _)?:            plan = p
        case .degraded(let reason, _)?: planFailure = reason
        case nil:                       break
        }
        return codexUsageCard(summary: summary, scanFailed: scanFailed, plan: plan,
                              planFailureReason: planFailure, budget: CodexBudgetStore.load(),
                              updatedAt: updatedAt, now: now)
    }

    private func addOpenURLItem(to menu: NSMenu, title: String, url: URL) {
        let item = NSMenuItem(title: title, action: #selector(openURLItem(_:)), keyEquivalent: "")
        item.representedObject = url
        item.target = self
        menu.addItem(item)
    }

    @objc private func openURLItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func addRefreshItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        item.keyEquivalentModifierMask = .command
        item.target = self
        menu.addItem(item)
    }

    @objc private func refreshNow() {
        refreshAll()
    }

    private func addRefreshIntervalItem(to menu: NSMenu) {
        // Menu is rebuilt on every open (menuNeedsUpdate), so the checkmark
        // re-reads the stored value here and needs no separate state sync.
        let parent = NSMenuItem(title: "Refresh Every", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = RefreshIntervalStore.load()
        for minutes in RefreshInterval.allowedMinutes {
            let title = minutes == 1 ? "1 minute" : "\(minutes) minutes"
            let item = NSMenuItem(title: title, action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.tag = minutes   // carries the chosen value to the action
            item.state = minutes == current ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        RefreshIntervalStore.save(sender.tag)
        setupRefreshTimer()   // restart the cadence immediately at the new interval
    }

    // MARK: Menu bar layout

    private func addMenuBarLayoutItem(to menu: NSMenu) {
        // Menu is rebuilt on every open, so the checkmark re-reads the stored value.
        let parent = NSMenuItem(title: "Menu Bar Layout", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = MenuBarStyleStore.load()
        for (i, style) in MenuBarStyle.allCases.enumerated() {
            let item = NSMenuItem(title: style.displayName, action: #selector(setMenuBarStyle(_:)), keyEquivalent: "")
            item.tag = i   // index into MenuBarStyle.allCases
            item.state = style == current ? .on : .off
            item.target = self
            submenu.addItem(item)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setMenuBarStyle(_ sender: NSMenuItem) {
        let styles = MenuBarStyle.allCases
        guard styles.indices.contains(sender.tag) else { return }
        MenuBarStyleStore.save(styles[sender.tag])
        statusView.style = styles[sender.tag]
        setupCountdownTimer()
        redraw()
    }

    // MARK: Codex column settings

    /// Per-provider visibility. Either can be hidden, never both: the last
    /// visible provider's item is drawn checked but disabled (action nil) so the
    /// rule is visible in the menu rather than a click that silently does
    /// nothing. Hiding Claude is also blocked when Codex has no install to
    /// report on, which would otherwise leave a menu bar of dashes.
    private func addShowInMenuBarItem(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let visibility = ProviderVisibilityStore.load()
        let codexUsable = CodexScanner.isCodexInstalled()

        for (i, provider) in Provider.allCases.enumerated() {
            let shown = visibility.isVisible(provider)
            var allowed = visibility.canToggle(provider)
            // Claude can't be hidden when Codex has nothing to show, and the
            // Codex row itself is inert on a Mac without Codex — leaving it
            // checked and clickable would promise a column that never appears.
            if !codexUsable { allowed = false }
            let item = NSMenuItem(title: provider.displayName,
                                  action: allowed ? #selector(toggleProvider(_:)) : nil,
                                  keyEquivalent: "")
            item.tag = i   // index into Provider.allCases
            item.state = shown ? .on : .off
            if allowed { item.target = self }
            submenu.addItem(item)
        }
        if !codexUsable {
            addDisabledRow(to: submenu, title: "No Codex install detected (~/.codex/sessions or archived_sessions)")
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        let providers = Provider.allCases
        guard providers.indices.contains(sender.tag),
              let next = ProviderVisibilityStore.load().toggling(providers[sender.tag])
        else { return }
        ProviderVisibilityStore.save(next)
        statusView.visibility = next
        // A provider just turned back on has stale (or no) data — refresh now so
        // it doesn't sit on dashes until the next tick.
        refreshAll()
        redraw()
    }

    /// One "Codex Column" submenu holds the remaining Codex preferences:
    /// $ vs tokens, and the fallback budget.
    private func addCodexColumnItem(to menu: NSMenu) {
        let parent = NSMenuItem(title: "Codex Column", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let dollars = CodexDisplayStore.showsDollars()
        let dollarItem = NSMenuItem(title: "Estimated Cost ($)", action: #selector(setCodexDisplay(_:)), keyEquivalent: "")
        dollarItem.tag = 1
        dollarItem.state = dollars ? .on : .off
        dollarItem.target = self
        submenu.addItem(dollarItem)
        let tokenItem = NSMenuItem(title: "Token Counts", action: #selector(setCodexDisplay(_:)), keyEquivalent: "")
        tokenItem.tag = 0
        tokenItem.state = dollars ? .off : .on
        tokenItem.target = self
        submenu.addItem(tokenItem)

        submenu.addItem(.separator())
        let budgetParent = NSMenuItem(title: "Monthly Budget", action: nil, keyEquivalent: "")
        let budgetMenu = NSMenu()
        let current = CodexBudgetStore.load()
        for amount in CodexBudgetStore.options {
            let item = NSMenuItem(title: String(format: "$%.0f / month", amount),
                                  action: #selector(setCodexBudget(_:)), keyEquivalent: "")
            item.tag = Int(amount)
            item.state = amount == current ? .on : .off
            item.target = self
            budgetMenu.addItem(item)
        }
        budgetParent.submenu = budgetMenu
        submenu.addItem(budgetParent)

        parent.submenu = submenu
        menu.addItem(parent)
    }

    @objc private func setCodexDisplay(_ sender: NSMenuItem) {
        CodexDisplayStore.save(showsDollars: sender.tag == 1)
        statusView.codexShowsDollars = sender.tag == 1
        redraw()
    }

    @objc private func setCodexBudget(_ sender: NSMenuItem) {
        CodexBudgetStore.save(Double(sender.tag))
        statusView.codexBudget = Double(sender.tag)
        redraw()
    }

    // MARK: Cookie

    private func addSetCookieItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Set Session Cookie…", action: #selector(promptForCookie as () -> Void), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc func promptForCookie() { promptForCookie(prefill: "") }

    private func promptForCookie(prefill: String) {
        // LSUIElement app: the app has no Dock icon, so NSAlert won't front without this.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set Claude session cookie"
        alert.informativeText = """
            1. Open claude.ai/settings/usage in your browser
            2. Open DevTools (⌘⌥I) → Network tab
            3. Refresh the page, click the "usage" request
            4. In Request Headers, copy the full "Cookie" value
            5. Paste it below
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "anthropic-device-id=…; lastActiveOrg=…; sessionKey=…"
        field.stringValue = prefill
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")                           // .alertFirstButtonReturn
        alert.addButton(withTitle: "Open claude.ai/settings/usage") // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                        // .alertThirdButtonReturn
        // WHY layout() + makeFirstResponder: initialFirstResponder alone is not enough
        // for NSAlert accessoryViews in LSUIElement apps — AppKit won't focus the field
        // until the window is laid out, so ⌘V paste is swallowed. layout() finalises
        // the view hierarchy; makeFirstResponder() then gives the field keyboard focus.
        alert.layout()
        alert.window.makeFirstResponder(field)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let cookie = sanitizeCookie(field.stringValue)
            guard !cookie.isEmpty else { return }  // empty Save == Cancel; never clears
            CookieStore.save(cookie)
            fetcher.fetchNow()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Self.claudeUsageURL)
            promptForCookie(prefill: field.stringValue)  // reopen; keep typed text
        default:
            break
        }
    }

    // MARK: Launch at login / quit

    private func addLaunchAtLoginItem(to menu: NSMenu) {
        // WHY: SMAppService.mainApp only works when the app is installed as a proper
        // .app bundle (not via `swift run`). We wrap in try/catch and show an error
        // item if the service call fails, which it will during development.
        let service = SMAppService.mainApp
        let isEnabled: Bool
        do {
            isEnabled = service.status == .enabled
        }

        let item = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        item.state = isEnabled ? .on : .off
        item.target = self
        menu.addItem(item)
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Show one-line error item on next menu open; state hasn't changed.
            let errItem = NSMenuItem(title: "Login item error: \(error.localizedDescription)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            statusItem.menu?.insertItem(errItem, at: 0)
        }
    }

    private func addQuitItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Quit Clusage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.keyEquivalentModifierMask = .command
        menu.addItem(item)
    }
}
