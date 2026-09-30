import AppKit
import BetterSettings
import BetterShortcuts
import BetterUpdater
import Combine

/// The menu bar extra's menu. Rebuilt from live state on every open and observes
/// only the updater, only while open, so it costs nothing while closed.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    /// Reopens the menu after a manual update check so its progress and result show live.
    weak var statusButton: NSStatusBarButton?

    private let updateItem = NSMenuItem()
    private var updaterObserver: AnyCancellable?
    private var showsCheckResult = false

    private static let layoutModes: [SwitcherLayoutMode] = [.gridView, .list, .windowPreview]
    private static let spaceScopes = SpaceScope.allCases

    override init() {
        super.init()
        menu.delegate = self
        // The update row toggles its own enabled state while the menu is open.
        menu.autoenablesItems = false
        updateItem.target = self
        updateItem.action = #selector(pressUpdateItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared

        if !AccessibilityCheck.isTrusted {
            addItem(to: menu, String(localized: "Open Accessibility Settings"), #selector(openAccessibilitySettings))
            menu.addItem(.separator())
        }

        menu.addItem(profilesItem())
        menu.addItem(choiceItem(
            String(localized: "Layout"), Self.layoutModes, selected: prefs.switcherLayoutMode,
            label: \.displayName, action: #selector(selectLayout(_:))
        ))
        menu.addItem(choiceItem(
            String(localized: "Spaces"), Self.spaceScopes, selected: prefs.spaceScope,
            label: \.displayName, action: #selector(selectSpaceScope(_:))
        ))
        addToggle(to: menu, String(localized: "Applications only"), isOn: prefs.applicationsOnly, #selector(toggleApplicationsOnly))
        addToggle(to: menu, String(localized: "Show minimized windows"), isOn: prefs.showMinimizedWindows, #selector(toggleShowMinimized))
        menu.addItem(.separator())

        let hideAll = addItem(to: menu, String(localized: "Hide all windows"), #selector(hideAllApps))
        hideAll.setShortcut(BetterShortcuts.Name.hideAllWindows.shortcut)
        let showAll = addItem(to: menu, String(localized: "Show all windows"), #selector(showAllApps))
        showAll.setShortcut(BetterShortcuts.Name.showAllWindows.shortcut)
        menu.addItem(.separator())

        // A finished check's result shows only in the menu reopened by the press that ran it.
        switch GitHubUpdater.shared.state {
        case .upToDate where !showsCheckResult, .error where !showsCheckResult: renderUpdateItem(.idle)
        case let state: renderUpdateItem(state)
        }
        showsCheckResult = false
        menu.addItem(updateItem)
        LaunchAtLogin.shared.refresh()
        addToggle(to: menu, String(localized: "Launch at login"), isOn: LaunchAtLogin.shared.isEnabled, #selector(toggleLaunchAtLogin))
        menu.addItem(settingsItem())
        addItem(to: menu, String(localized: "Quit BetterCmdTab"), #selector(quit), keyEquivalent: "q")
    }

    func menuWillOpen(_ menu: NSMenu) {
        updaterObserver = GitHubUpdater.shared.$state.dropFirst().sink { [weak self] state in
            self?.renderUpdateItem(state)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        updaterObserver = nil
    }

    private func renderUpdateItem(_ state: UpdateState) {
        func show(_ title: String, isEnabled: Bool = true) {
            updateItem.title = title
            updateItem.isEnabled = isEnabled
        }
        switch state {
        case .idle:
            show(String(localized: "Check for Updates"))
        case .checking:
            show(String(localized: "Checking…"), isEnabled: false)
        case .upToDate:
            show(String(localized: "Up to date (\(AppInfo.appVersion))"), isEnabled: false)
        case .error(let message):
            show(message)
        case .available(let version, _):
            show(String(localized: "Update to \(version)…"))
        case .downloading(let progress):
            show(String(format: String(localized: "Downloading %d%%"), Int(progress * 100)))
        case .installing(let progress, _):
            show(String(format: String(localized: "Installing %d%%"), Int(progress * 100)))
        case .readyToInstall:
            show(String(localized: "Restart to Update"))
        }
    }

    /// Mirrors the Settings › Profiles list rows; a click opens that pane.
    private func profilesItem() -> NSMenuItem {
        let submenu = NSMenu()
        for row in ShortcutsEditorView.listItems(for: ShortcutsEditorView.profileTargets) {
            let title = row.detail.isEmpty ? row.title : "\(row.title)  \(row.detail)"
            addItem(to: submenu, title, #selector(openProfiles))
        }
        return parentItem(String(localized: "Profiles"), submenu)
    }

    /// Radio submenu over `options`; the clicked item's `tag` is its index.
    private func choiceItem<Option: Equatable>(
        _ title: String,
        _ options: [Option],
        selected: Option,
        label: (Option) -> String,
        action: Selector
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = addItem(to: submenu, label(option), action)
            item.tag = index
            item.state = option == selected ? .on : .off
        }
        return parentItem(title, submenu)
    }

    private func settingsItem() -> NSMenuItem {
        let submenu = NSMenu()
        for (index, tab) in SettingsCatalog.tabs.enumerated() {
            let item = addItem(
                to: submenu, tab.title, #selector(openSettingsTab(_:)),
                keyEquivalent: tab.id == SettingsTabID.general ? "," : ""
            )
            item.tag = index
        }
        return parentItem(String(localized: "Settings"), submenu)
    }

    private func addToggle(to menu: NSMenu, _ title: String, isOn: Bool, _ action: Selector) {
        let item = addItem(to: menu, title, action)
        item.state = isOn ? .on : .off
    }

    private func parentItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityCheck.openSystemSettings()
    }

    @objc private func pressUpdateItem() {
        let updater = GitHubUpdater.shared
        switch updater.state {
        case .idle, .upToDate, .error:
            Task { await updater.checkForUpdates(force: true) }
            showsCheckResult = true
            // A view-backed row would keep the menu open, but it never fires from Return or VoiceOver.
            // A timer, not the main queue: tracking inside a main-queue block starves the MainActor check.
            perform(#selector(reopenMenu), with: nil, afterDelay: 0)
        case .available, .downloading, .installing, .readyToInstall:
            UpdateWindowPresenter.shared.show()
        case .checking:
            break
        }
    }

    @objc private func reopenMenu() {
        statusButton?.performClick(nil)
    }

    @objc private func openProfiles() {
        SettingsWindowPresenter.shared.show(selecting: SettingsTabID.profiles)
    }

    @objc private func selectLayout(_ sender: NSMenuItem) {
        Preferences.shared.switcherLayoutMode = Self.layoutModes[sender.tag]
    }

    @objc private func selectSpaceScope(_ sender: NSMenuItem) {
        Preferences.shared.spaceScope = Self.spaceScopes[sender.tag]
    }

    @objc private func toggleApplicationsOnly() {
        Preferences.shared.applicationsOnly.toggle()
    }

    @objc private func toggleShowMinimized() {
        Preferences.shared.showMinimizedWindows.toggle()
    }

    @objc private func hideAllApps() {
        Activator.hideAllApps()
    }

    @objc private func showAllApps() {
        Activator.showAllApps()
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.shared.setEnabled(!LaunchAtLogin.shared.isEnabled)
    }

    @objc private func openSettingsTab(_ sender: NSMenuItem) {
        SettingsWindowPresenter.shared.show(selecting: SettingsCatalog.tabs[sender.tag].id)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

