//
//  MenuBarManager.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Combine
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Visible-section items currently masked by the active app's menus and
    /// eligible for temporary presentation in the Thaw Bar.
    @Published private(set) var overflowedVisibleItemTags = Set<MenuBarItemTag>()

    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Timestamp of the last time a section was shown.
    private(set) var lastShowTimestamp: ContinuousClock.Instant?

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Diagnostic logger for the menu bar manager.
    private let diagLog = DiagLog(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Cancellable for the periodic average-color refresh, active only while settings is visible.
    private var averageColorRefreshCancellable: AnyCancellable?

    /// Task that retries visible-overflow refreshes while the frontmost app's
    /// menu bar is settling after an app switch.
    private var visibleOverflowRefreshTask: Task<Void, Never>?

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// A Boolean value that indicates whether the application menus were hidden
    /// by a manual toggle (URL/hotkey), rather than automatically by section state.
    private var isManuallyHidingApplicationMenus = false

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The popover that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// The gap that macOS leaves to either side of the notch.
    private static let notchGap: CGFloat = 24

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
        updateVisibleOverflowState()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        averageColorRefreshCancellable?.cancel()
        averageColorRefreshCancellable = nil
        visibleOverflowRefreshTask?.cancel()
        visibleOverflowRefreshTask = nil
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
                updateVisibleOverflowState()
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` and `smart` rehide strategies.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                defer {
                    self?.scheduleVisibleOverflowRefresh()
                }
                if
                    let self,
                    let appState,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.hidEventManager.bestScreen(appState: appState),
                    !appState.hidEventManager.isMouseInsideMenuBar(appState: appState, screen: screen),
                    !appState.hidEventManager.isMouseInsideIceBar(appState: appState),
                    appState.settings.general.autoRehide
                {
                    // Handle both focusedApp and smart strategies for focus changes
                    switch appState.settings.general.rehideStrategy {
                    case .focusedApp, .smart:
                        Task {
                            // Add delay for smart strategy to allow app focus to settle
                            let delay: TimeInterval = appState.settings.general.rehideStrategy == .smart ? 0.25 : 0.1
                            try await Task.sleep(for: .seconds(delay))

                            // Ignore rehide requests for a short grace period after showing.
                            if let lastShow = self.lastShowTimestamp,
                               lastShow.duration(to: .now) < .milliseconds(500)
                            {
                                self.diagLog.debug("Skipping rehide due to grace period")
                                return
                            }

                            // Check if any menu bar item has a menu open (for smart strategy)
                            if appState.settings.general.rehideStrategy == .smart {
                                if await appState.itemManager.isAnyMenuBarItemMenuOpen() {
                                    return
                                }
                            }

                            hiddenSection.hide()
                        }
                    default:
                        break
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        if let appState {
            appState.settings.displaySettings.$configurations
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateControlItemStates()
                    self?.updateVisibleOverflowState(bypassMenuFrameCache: true)
                }
                .store(in: &c)

            appState.itemManager.$itemCache
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateVisibleOverflowState(bypassMenuFrameCache: true)
                }
                .store(in: &c)

            appState.navigationState.$isSettingsPresented
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateVisibleOverflowState()
                }
                .store(in: &c)
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibleOverflowState()
            }
            .store(in: &c)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateVisibleOverflowState()
            }
            .store(in: &c)

        $settingsWindow
            .removeNil()
            .map { $0.publisher(for: \.isVisible) }
            .switchToLatest()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self else { return }
                if isVisible {
                    updateAverageColorInfo()
                    // Start a visibility-gated 60s refresh to catch wallpaper changes
                    // (macOS no longer posts a wallpaper change notification).
                    averageColorRefreshCancellable = Timer.publish(every: 60, tolerance: 10, on: .main, in: .default)
                        .autoconnect()
                        .sink { [weak self] _ in
                            self?.updateAverageColorInfo()
                        }
                } else {
                    averageColorRefreshCancellable?.cancel()
                    averageColorRefreshCancellable = nil
                }
            }
            .store(in: &c)

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, let appState else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !appState.settings.displaySettings.configurationForActiveDisplay().useIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                // Check if hidden or alwaysHidden section is being shown
                let hiddenSection = self.section(withName: .hidden)
                let alwaysHiddenSection = self.section(withName: .alwaysHidden)

                // Use isHidden property - when section is shown, isHidden is false
                let isShowingHiddenSection = hiddenSection.map { !$0.isHidden } ?? false
                let isShowingAlwaysHiddenSection = alwaysHiddenSection.map { !$0.isHidden } ?? false

                if isShowingHiddenSection || isShowingAlwaysHiddenSection {
                    // Use the screen with the active menu bar
                    guard let screen = NSScreen.screenWithActiveMenuBar ?? NSScreen.main else {
                        return
                    }

                    Task {
                        // The window server needs time to update window positions after expansion.
                        try? await Task.sleep(for: .milliseconds(50))

                        // Get the app menu frame for this screen
                        guard let appMenuFrame = screen.getApplicationMenuFrame() else {
                            return
                        }

                        // Get ALL menu bar items
                        let allItems = await MenuBarItem.getMenuBarItems(option: .activeSpace)

                        // Filter to items on THIS screen by comparing Y coordinate with app menu's Y
                        let menuBarY = appMenuFrame.origin.y
                        let screenItems = allItems.filter { item in
                            abs(item.bounds.origin.y - menuBarY) < 50
                        }

                        // Get the control items for this screen
                        let hiddenControlItem = screenItems.first { $0.tag == .hiddenControlItem }
                        let alwaysHiddenControlItem = screenItems.first { $0.tag == .alwaysHiddenControlItem }

                        // TODO: This section needs to be improved but is okay for now.

                        // Get control item bounds and hidden items width
                        var controlBounds: CGRect = .zero
                        var hiddenItemsWidth: CGFloat = 0

                        if isShowingAlwaysHiddenSection, let ahControl = alwaysHiddenControlItem {
                            controlBounds = ahControl.bounds
                            if let appState = self.appState {
                                hiddenItemsWidth = appState.itemManager.itemCache[.alwaysHidden].reduce(0) { $0 + $1.bounds.width }
                            }
                        } else if isShowingHiddenSection, let hControl = hiddenControlItem {
                            controlBounds = hControl.bounds
                            if let appState = self.appState {
                                hiddenItemsWidth = appState.itemManager.itemCache[.hidden].reduce(0) { $0 + $1.bounds.width }
                            }
                        }

                        // The hidden section expands by replacing control item with hidden items
                        // New rightmost = where hidden items end = control.minX + hiddenItemsWidth
                        let newRightmostPos = controlBounds.minX + hiddenItemsWidth

                        // Use the actual app menu frame for needed space
                        let appMenuRightStart = appMenuFrame.maxX

                        // Available space: if app menu extends into notch, add notch width; otherwise use visible frame
                        let spaceAvailableFromAppMenuEnd: CGFloat
                        if let notch = screen.frameOfNotch {
                            if appMenuRightStart > notch.minX {
                                // App menu extends into notch, items get moved past notch
                                spaceAvailableFromAppMenuEnd = (notch.minX - appMenuRightStart) + (screen.visibleFrame.maxX - notch.maxX)
                            } else {
                                // App menu doesn't extend into notch
                                spaceAvailableFromAppMenuEnd = screen.visibleFrame.maxX - appMenuRightStart
                            }
                        } else {
                            spaceAvailableFromAppMenuEnd = screen.visibleFrame.maxX - appMenuRightStart
                        }

                        let spaceNeededFromAppMenuEnd = newRightmostPos - appMenuRightStart

                        // If items would extend past screen edge, hide the app menu
                        if spaceNeededFromAppMenuEnd > spaceAvailableFromAppMenuEnd {
                            self.hideApplicationMenus()
                        }
                    }
                } else if isHidingApplicationMenus, !isManuallyHidingApplicationMenus {
                    showApplicationMenus()
                }

                updateVisibleOverflowState()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard let appState else { return }

        // Only update if we really need the color info
        let isSettingsVisible = settingsWindow?.isVisible == true
        let isIceBarVisible = appState.navigationState.isIceBarPresented
        let isSearchVisible = appState.navigationState.isSearchPresented
        let anyIceBarEnabled = appState.settings.displaySettings.isIceBarEnabledOnAnyDisplay

        guard isSettingsVisible || isIceBarVisible || isSearchVisible || anyIceBarEnabled else {
            return
        }

        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "\(Constants.displayName)")

        let editAppearanceItem = NSMenuItem(
            title: String(localized: "Edit Menu Bar Appearance…"),
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.image = NSImage(systemSymbolName: "paintbrush", accessibilityDescription: "Edit Appearance")
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: String(localized: "\(Constants.displayName) Settings…"),
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    ///
    /// - Important: Uses `.regular` activation policy to hide menus, which briefly shows the app in the Dock.
    func hideApplicationMenus(manual: Bool = false) {
        guard let appState else {
            diagLog.error("Error hiding application menus: Missing app state")
            return
        }

        if isHidingApplicationMenus {
            return
        }

        diagLog.info("Hiding application menus")
        isHidingApplicationMenus = true
        if manual {
            isManuallyHidingApplicationMenus = true
        }

        // Ensure this happens on the main thread
        Task { @MainActor in
            guard isHidingApplicationMenus else { return }

            appState.activate(withPolicy: .regular)

            // Force activation again after a micro-delay.
            // The first activation after policy change can sometimes be ignored by the system.
            try? await Task.sleep(for: .milliseconds(25))
            guard isHidingApplicationMenus else { return }
            appState.activate()
        }
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            diagLog.error("Error showing application menus: Missing app state")
            return
        }
        diagLog.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
        isManuallyHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus(manual: true)
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen) {
            self.dismissAppearanceEditorPanel()
        }
    }

    /// Dismisses the appearance editor panel if it is shown.
    func dismissAppearanceEditorPanel() {
        appearanceEditorPanel.close()
    }

    /// Updates the ``lastShowTimestamp`` property.
    func updateLastShowTimestamp() {
        lastShowTimestamp = .now
    }

    /// Recomputes which visible items are currently masked by the active app's
    /// menus and refreshes the Thaw Bar overflow presentation if needed.
    func updateVisibleOverflowState(
        for screen: NSScreen? = nil,
        bypassMenuFrameCache: Bool = false
    ) {
        let activeScreen = screen ?? NSScreen.screenWithActiveMenuBar ?? NSScreen.main
        let overflowTags = computeOverflowedVisibleItemTags(
            on: activeScreen,
            bypassMenuFrameCache: bypassMenuFrameCache
        )

        if overflowedVisibleItemTags != overflowTags {
            let displayDescription = activeScreen.map { "\($0.displayID)" } ?? "nil"
            diagLog.info(
                """
                Visible overflow changed on display \(displayDescription): \
                \(overflowedVisibleItemTags.count) -> \(overflowTags.count)
                """
            )
            overflowedVisibleItemTags = overflowTags
        }

        refreshVisibleOverflowPresentation(on: activeScreen)
    }

    /// Retries visible-overflow detection for a short period after the
    /// frontmost app changes, because AppKit/AX can briefly report a stale
    /// menu frame during the handoff.
    private func scheduleVisibleOverflowRefresh(for screen: NSScreen? = nil) {
        visibleOverflowRefreshTask?.cancel()
        updateVisibleOverflowState(for: screen, bypassMenuFrameCache: true)

        visibleOverflowRefreshTask = Task { @MainActor [weak self] in
            for _ in 0 ..< 8 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else {
                    return
                }
                self.updateVisibleOverflowState(
                    for: screen,
                    bypassMenuFrameCache: true
                )
            }
        }
    }

    /// Computes the set of visible-section items that are no longer usable
    /// because the active app's menu titles extend into their space.
    private func computeOverflowedVisibleItemTags(
        on screen: NSScreen?,
        bypassMenuFrameCache: Bool = false
    ) -> Set<MenuBarItemTag> {
        guard
            let appState,
            let screen
        else {
            return []
        }

        guard
            !appState.activeSpace.isFullscreen,
            !isMenuBarHiddenBySystem,
            !isMenuBarHiddenBySystemUserDefaults,
            !appState.navigationState.isSettingsPresented,
            appState.settings.displaySettings.showOverflowedVisibleItemsInIceBar(for: screen.displayID),
            let appMenuFrame = screen.getApplicationMenuFrame(
                bypassCache: bypassMenuFrameCache
            )
        else {
            return []
        }

        var unavailableBoundaryX = appMenuFrame.maxX
        if let notch = screen.frameOfNotch,
           unavailableBoundaryX > (notch.minX - Self.notchGap)
        {
            unavailableBoundaryX = notch.maxX + Self.notchGap
        }

        let visibleItems = appState.itemManager.itemCache.managedItems.filter { item in
            !item.isControlItem &&
                item.canBeHidden &&
                !item.isSystemClone &&
                appState.itemManager.logicalSection(for: item) == .visible
        }

        let onScreenWindowIDs = Set(
            Bridging.getMenuBarWindowList(option: [.onScreen, .activeSpace, .itemsOnly])
        )

        let candidates = visibleItems.filter { item in
            let currentBounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
            let isOnActiveScreen =
                currentBounds.midY >= screen.frame.minY &&
                currentBounds.midY <= screen.frame.maxY
            let isOffScreenPlaceholder = currentBounds.origin.x == -1
            let isCurrentlyOnScreen = onScreenWindowIDs.contains(item.windowID)

            return isOnActiveScreen &&
                (
                    isOffScreenPlaceholder ||
                        !isCurrentlyOnScreen ||
                        !item.isOnScreen ||
                        currentBounds.minX < unavailableBoundaryX
                )
        }

        diagLog.debug(
            """
            computeOverflowedVisibleItemTags: display=\(screen.displayID) \
            visibleManaged=\(visibleItems.count) \
            managed=\(appState.itemManager.itemCache.managedItems.count) \
            appMenuFrame=\(NSStringFromRect(appMenuFrame)) \
            boundaryX=\(unavailableBoundaryX) \
            onScreenItems=\(onScreenWindowIDs.count) \
            candidates=\(candidates.count) \
            titles=\(candidates.prefix(8).map(\.displayName).joined(separator: ", "))
            """
        )

        if candidates.isEmpty, !visibleItems.isEmpty {
            let visibleDebugSummary = visibleItems.prefix(12).map { item in
                let currentBounds = Bridging.getWindowBounds(for: item.windowID) ?? item.bounds
                let isOffScreenPlaceholder = currentBounds.origin.x == -1
                let isCurrentlyOnScreen = onScreenWindowIDs.contains(item.windowID)
                return "\(item.displayName)@\(NSStringFromRect(currentBounds)) onScreen=\(item.isOnScreen) currentOnScreen=\(isCurrentlyOnScreen) offPlaceholder=\(isOffScreenPlaceholder)"
            }.joined(separator: " | ")

            diagLog.debug(
                """
                computeOverflowedVisibleItemTags details: \
                display=\(screen.displayID) boundaryX=\(unavailableBoundaryX) \
                items=\(visibleDebugSummary)
                """
            )
        }

        return Set(candidates.map(\.tag))
    }

    /// Keeps overflowed visible items embedded in the existing Thaw Bar
    /// content, and never opens a standalone overflow presentation.
    private func refreshVisibleOverflowPresentation(on screen: NSScreen?) {
        guard
            let appState,
            let screen
        else {
            return
        }

        let hasEmbeddedOverflow = !overflowedVisibleItemTags.isEmpty &&
            appState.settings.displaySettings.showOverflowedVisibleItemsInIceBar(for: screen.displayID)

        diagLog.debug(
            """
            refreshVisibleOverflowPresentation: display=\(screen.displayID) \
            embeddedOverflow=\(hasEmbeddedOverflow) \
            overflowCount=\(overflowedVisibleItemTags.count) \
            iceBarExplicit=\(iceBarPanel.isShowingExplicitSection)
            """
        )
    }

    /// Updates the control item states for all sections.
    ///
    /// - Parameter screen: The screen to use for the update. If `nil`, the
    ///   best screen is determined automatically.
    func updateControlItemStates(for screen: NSScreen? = nil) {
        for section in sections {
            section.updateControlItemState(for: screen)
        }
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat {
        color.brightness ?? 0
    }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool {
        brightness > 0.67
    }
}
