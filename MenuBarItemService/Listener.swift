//
//  Listener.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Security
import XPC

@available(macOS 26.0, *)
private enum XPCSigningIdentity {
    static let hasTeamIdentifier: Bool = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any],
              let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        else {
            return false
        }

        return !teamIdentifier.isEmpty
    }()
}

/// A wrapper around an XPC listener object.
final class Listener {
    private let diagLog = DiagLog(category: "Listener")
    /// The shared listener.
    static let shared = Listener()

    /// The service name.
    private let name = MenuBarItemService.name

    /// The underlying XPC listener object.
    private var listener: XPCListener?

    /// Creates the shared listener.
    private init() {}

    deinit {
        cancel()
    }

    /// Handles a received message.
    private func handleMessage(_ message: XPCReceivedMessage) -> MenuBarItemService.Response? {
        do {
            let request = try message.decode(as: MenuBarItemService.Request.self)
            switch request {
            case .start:
                diagLog.debug("Listener received start request")
                return .start
            case let .sourcePID(window):
                diagLog.debug("Listener: sourcePID request for windowID=\(window.windowID) title=\(window.title ?? "nil")")
                let pid = SourcePIDCache.shared.pid(for: window)
                diagLog.debug("Listener: sourcePID response for windowID=\(window.windowID) -> pid=\(pid.map { "\($0)" } ?? "nil")")
                return .sourcePID(pid)
            }
        } catch {
            diagLog.error("Listener failed to handle message with error \(error)")
            return nil
        }
    }

    /// Activates the listener without checking if it is already active,
    /// with the requirement that session peers must be signed with the
    /// same team identifier as the service process.
    @available(macOS 26.0, *)
    private func uncheckedActivateWithSameTeamRequirement() throws {
        listener = try XPCListener(service: name, requirement: .isFromSameTeam()) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener without checking if it is already active.
    private func uncheckedActivate() throws {
        listener = try XPCListener(service: name) { [weak self] request in
            request.accept { message in
                self?.handleMessage(message)
            }
        }
    }

    /// Activates the listener.
    func activate() {
        guard listener == nil else {
            diagLog.notice("Listener is already active")
            return
        }

        diagLog.debug("Activating listener")

        do {
            if #available(macOS 26.0, *), XPCSigningIdentity.hasTeamIdentifier {
                try uncheckedActivateWithSameTeamRequirement()
            } else if #available(macOS 26.0, *) {
                diagLog.notice("Activating listener without same-team requirement because the current process has no Team ID")
                try uncheckedActivate()
            } else {
                try uncheckedActivate()
            }
        } catch {
            diagLog.error("Failed to activate listener with error \(error)")
        }
    }

    /// Cancels the listener.
    func cancel() {
        diagLog.debug("Canceling listener")
        listener.take()?.cancel()
    }
}
