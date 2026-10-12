//
//  AppDefaultAppResources.swift
//  Loop
//

import AppKit

/// Bundle reads and Launch Services/Icon Services calls can block on disk or IPC.
/// Explicit worker-executor functions keep them out of SwiftUI's main-actor tasks.
enum AppDefaultAppResources {
    struct Metadata: Sendable {
        let bundleID: String
        let name: String
    }

    @concurrent
    static func metadata(
        at url: URL,
        read: @Sendable (URL) -> Metadata? = readMetadata
    ) async -> Metadata? {
        read(url)
    }

    /// Keeping the reader injectable allows regression tests to simulate slow
    /// bundle I/O and verify its executor without relying on filesystem timing.
    private static func readMetadata(at url: URL) -> Metadata? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Metadata(bundleID: id, name: name)
    }

    @concurrent
    static func icon(bundleID: String, appURL: URL?) async -> NSImage? {
        let selectedURL = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier == bundleID ? $0 : nil }
        guard let url = selectedURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: url)?.bundleIdentifier == bundleID else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
