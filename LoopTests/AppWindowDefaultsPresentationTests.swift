//
//  AppWindowDefaultsPresentationTests.swift
//  LoopTests
//

import AppKit
import Combine
@testable import Loop
import Luminare
import SwiftUI
import Testing

/// Render the real native form and change the same selection binding used by the
/// customize button. Pure model tests cannot catch misplaced modal modifiers.
@Suite(.serialized)
@MainActor
struct AppWindowDefaultsPresentationTests {
    @Test func selectingAppPresentsAnEditorAndReopensAfterClosing() async throws {
        try await checkPresentation(layout: .stacked)
        if #available(macOS 15, *) { try await checkPresentation(layout: .form) }
    }

    private func checkPresentation(layout: LuminareFormLayout) async throws {
        let id = "com.example.LoopPresentationTest"
        let store = Store(apps: [id: AppWindowDefault(appName: "Presentation Test")])
        let original = store.apps
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let root = TestForm(store: store, layout: layout)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(x: -10000, y: -10000, width: 480, height: 620),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            for added in NSApp.windows where !originalWindows.contains(ObjectIdentifier(added)) {
                added.close()
            }
        }

        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        store.selection = id
        let editor = try #require(await waitForEditor(excluding: originalWindows))
        // The full custom editor is substantially taller than an empty modal;
        // ensure this isn't merely an invisible/empty panel with a stale app ID.
        #expect(editor.frame.width >= 400)
        #expect(editor.frame.height > 300)
        // Dismissing the native panel must reset presentation, so the same app's
        // customize control works on a subsequent click as well.
        editor.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.selection == nil)
        store.selection = id
        let reopened = try #require(await waitForEditor(excluding: originalWindows))
        #expect(reopened !== editor)
        #expect(store.apps == original)
        reopened.close()
        try await Task.sleep(for: .milliseconds(100))
        // A row added after the form was mounted must get its own correctly
        // identified editor, rather than reusing the previous app's content.
        let secondID = "com.example.LoopPresentationTest.Second"
        var second = AppWindowDefault(appName: "Second App")
        second.action.width = 50
        second.action.height = 45
        store.apps[secondID] = second
        try await Task.sleep(for: .milliseconds(100))
        store.selection = secondID
        let secondEditor = try #require(await waitForEditor(excluding: originalWindows))
        #expect(secondEditor !== reopened)
        #expect(store.apps[secondID] == second)
        #expect(store.apps[id] == original[id])
    }

    private func waitForEditor(excluding originalWindows: Set<ObjectIdentifier>) async -> NSWindow? {
        for _ in 0 ..< 100 {
            if let window = NSApp.windows.first(where: {
                $0 is LuminareWindow && $0.isVisible &&
                    $0.frame.width >= 400 && $0.frame.height > 300 &&
                    !originalWindows.contains(ObjectIdentifier($0))
            }) { return window }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private struct TestForm: View {
        @ObservedObject var store: Store
        let layout: LuminareFormLayout

        var body: some View {
            LuminareForm {
                AppWindowDefaultsConfigurationView(appDefaults: $store.apps, selection: $store.selection)
            }
            .luminareFormLayout(layout)
            .luminareSectionLayout(layout == .stacked ? .stacked : .section)
            .luminareModalPresentation(.screenCenter.offset(x: -10000, y: -10000))
            .luminareModalClosesOnDefocus(false)
        }
    }

    private final class Store: ObservableObject {
        @Published var apps: [String: AppWindowDefault]
        @Published var selection: String?
        init(apps: [String: AppWindowDefault]) { self.apps = apps }
    }
}
