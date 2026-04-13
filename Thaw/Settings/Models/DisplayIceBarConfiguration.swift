//
//  DisplayIceBarConfiguration.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

/// Per-display configuration for the Ice Bar.
struct DisplayIceBarConfiguration: Codable, Equatable {
    /// Whether the Ice Bar is enabled on this display.
    let useIceBar: Bool

    /// The location where the Ice Bar appears on this display.
    let iceBarLocation: IceBarLocation

    /// Whether to always show hidden menu bar items on this display.
    ///
    /// This setting is only applicable when ``useIceBar`` is `false`.
    let alwaysShowHiddenItems: Bool

    /// Whether overflowed visible menu bar items should appear in the Ice Bar.
    let showOverflowedVisibleItemsInIceBar: Bool

    /// Coding keys for backward-compatible persistence.
    private enum CodingKeys: String, CodingKey {
        case useIceBar
        case iceBarLocation
        case alwaysShowHiddenItems
        case showOverflowedVisibleItemsInIceBar
    }

    init(
        useIceBar: Bool,
        iceBarLocation: IceBarLocation,
        alwaysShowHiddenItems: Bool,
        showOverflowedVisibleItemsInIceBar: Bool
    ) {
        self.useIceBar = useIceBar
        self.iceBarLocation = iceBarLocation
        self.alwaysShowHiddenItems = alwaysShowHiddenItems
        self.showOverflowedVisibleItemsInIceBar = showOverflowedVisibleItemsInIceBar
    }

    /// Default configuration (disabled, dynamic location).
    static let defaultConfiguration = DisplayIceBarConfiguration(
        useIceBar: false,
        iceBarLocation: .dynamic,
        alwaysShowHiddenItems: false,
        showOverflowedVisibleItemsInIceBar: false
    )

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useIceBar = try container.decode(Bool.self, forKey: .useIceBar)
        iceBarLocation = try container.decode(IceBarLocation.self, forKey: .iceBarLocation)
        alwaysShowHiddenItems = try container.decode(Bool.self, forKey: .alwaysShowHiddenItems)
        showOverflowedVisibleItemsInIceBar = try container.decodeIfPresent(
            Bool.self,
            forKey: .showOverflowedVisibleItemsInIceBar
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(useIceBar, forKey: .useIceBar)
        try container.encode(iceBarLocation, forKey: .iceBarLocation)
        try container.encode(alwaysShowHiddenItems, forKey: .alwaysShowHiddenItems)
        try container.encode(showOverflowedVisibleItemsInIceBar, forKey: .showOverflowedVisibleItemsInIceBar)
    }

    /// Returns a new configuration with the `useIceBar` flag replaced.
    func withUseIceBar(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: value,
            iceBarLocation: iceBarLocation,
            alwaysShowHiddenItems: alwaysShowHiddenItems,
            showOverflowedVisibleItemsInIceBar: showOverflowedVisibleItemsInIceBar
        )
    }

    /// Returns a new configuration with the `iceBarLocation` replaced.
    func withIceBarLocation(_ value: IceBarLocation) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: useIceBar,
            iceBarLocation: value,
            alwaysShowHiddenItems: alwaysShowHiddenItems,
            showOverflowedVisibleItemsInIceBar: showOverflowedVisibleItemsInIceBar
        )
    }

    /// Returns a new configuration with the `alwaysShowHiddenItems` flag replaced.
    func withAlwaysShowHiddenItems(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: useIceBar,
            iceBarLocation: iceBarLocation,
            alwaysShowHiddenItems: value,
            showOverflowedVisibleItemsInIceBar: showOverflowedVisibleItemsInIceBar
        )
    }

    /// Returns a new configuration with the `showOverflowedVisibleItemsInIceBar` flag replaced.
    func withShowOverflowedVisibleItemsInIceBar(_ value: Bool) -> DisplayIceBarConfiguration {
        DisplayIceBarConfiguration(
            useIceBar: useIceBar,
            iceBarLocation: iceBarLocation,
            alwaysShowHiddenItems: alwaysShowHiddenItems,
            showOverflowedVisibleItemsInIceBar: value
        )
    }

    /// Builds per-display configurations for all connected screens.
    @MainActor
    static func buildConfigurations(
        onlyOnNotched: Bool,
        location: IceBarLocation
    ) -> [String: DisplayIceBarConfiguration] {
        var configs = [String: DisplayIceBarConfiguration]()
        for screen in NSScreen.screens {
            guard let uuid = Bridging.getDisplayUUIDString(for: screen.displayID) else {
                continue
            }
            let enabled = onlyOnNotched ? screen.hasNotch : true
            configs[uuid] = DisplayIceBarConfiguration(
                useIceBar: enabled,
                iceBarLocation: location,
                alwaysShowHiddenItems: false,
                showOverflowedVisibleItemsInIceBar: false
            )
        }
        return configs
    }
}
