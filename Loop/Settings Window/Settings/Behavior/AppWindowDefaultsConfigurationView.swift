//
//  AppWindowDefaultsConfigurationView.swift
//  Loop
//

import Defaults
import Luminare
import SwiftUI

/// Apps are selected and configured here, without capturing a focused window.
/// The restore action and its fallback are configured separately in Keybinds.
struct AppWindowDefaultsConfigurationView: View {
    @Default(.appWindowDefaults) private var savedDefaults
    @Default(.applyAppDefaultsAutomatically) private var automaticallyApply
    @State private var editingApp: String?
    @State private var pendingEditor: String?
    @State private var selectedApps: Set<String> = []
    private let suppliedDefaults: Binding<[String: AppWindowDefault]>?
    private let suppliedSelection: Binding<String?>?

    /// An optional binding lets native presentation tests use isolated data,
    /// without changing the user's saved apps in the running Loop instance.
    init(appDefaults: Binding<[String: AppWindowDefault]>? = nil, selection: Binding<String?>? = nil) {
        self.suppliedDefaults = appDefaults
        self.suppliedSelection = selection
    }

    private var selectedApp: Binding<String?> { suppliedSelection ?? $editingApp }

    /// Selection is the single source of truth. A separate presentation Boolean
    /// can open an empty modal before its lazily read app ID has been refreshed.
    private func isEditingApp(_ id: String) -> Binding<Bool> {
        Binding(get: { selectedApp.wrappedValue == id }, set: {
            if !$0, selectedApp.wrappedValue == id { selectedApp.wrappedValue = nil }
        })
    }

    private var apps: [String: AppWindowDefault] {
        get { suppliedDefaults?.wrappedValue ?? savedDefaults }
        nonmutating set {
            if let suppliedDefaults { suppliedDefaults.wrappedValue = newValue }
            else { savedDefaults = newValue }
        }
    }

    var body: some View {
        let entries = apps
        LuminareSection(String(localized: "App Defaults")) {
            LuminareToggle("Apply to new windows automatically", isOn: $automaticallyApply)
            LuminareButtonRow {
                Button(String(localized: "Add", comment: "Used to add items to a list")) {
                    showAppChooser()
                }
                Button(String(localized: "Remove", comment: "Used to remove items from a list"), role: .destructive) {
                    // Commit all selected removals together, as Keybinds does.
                    apps = apps.filter { !selectedApps.contains($0.key) }
                    selectedApps.removeAll()
                }
                .disabled(selectedApps.isEmpty)
                .keyboardShortcut(.delete)
            }
            // This row sits below the toggle, not at the section's outer edge.
            .luminareRoundingBehavior(top: false, bottom: false)

            // App IDs are immutable and sorted; dragging cannot rename an app
            // or change its persisted identity.
            LuminareList(items: .constant(entries.keys.sorted()), selection: $selectedApps, id: \.self) { appID in
                let id = appID.wrappedValue
                HStack(spacing: 8) {
                    AppDefaultAppIcon(bundleID: id, appURL: entries[id]?.appURL)
                    Text(entries[id]?.appName ?? id)
                        .fontWeight(.regular)
                        .lineLimit(1)
                        .help(id)
                    Button {
                        selectedApp.wrappedValue = id
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .help("Customize this app’s default frame.")
                    .accessibilityLabel(Text("Customize app default for \(entries[id]?.appName ?? id)", comment: "Accessible name of a button configuring the named app's default frame"))
                    .accessibilityIdentifier("app-default-customize-\(id)")
                    // Match the custom-keybind editor: the control owns its modal
                    // and captures a stable app ID, never an optional lazy ID.
                    .luminareModal(isPresented: isEditingApp(id)) {
                        CustomActionConfigurationView(
                            action: appAction(id), isPresented: isEditingApp(id),
                            preferredDisplay: appDisplay(id), allowsDynamicSize: false
                        )
                        .frame(width: 400)
                    }
                    .luminareModalCornerRadius(24)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .onAppear {
                    // A new row must mount with presentation false first:
                    // Luminare's modal observes changes, not an initial true value.
                    if pendingEditor == id {
                        pendingEditor = nil
                        selectedApp.wrappedValue = id
                    }
                }
            } emptyView: {
                VStack {
                    Text("No app defaults")
                        .font(.title3)
                    Text("Click “Add” to add an app")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding()
            }
            .luminareRoundingBehavior(bottom: true)
            .luminareListFixedHeight(until: 300)
            .onChange(of: entries.keys.sorted()) { ids in
                selectedApps.formIntersection(ids)
            }
        }
    }

    /// Match the native app chooser used by Excluded Apps. Selecting an existing
    /// app reopens its editor without replacing its size, position, or display.
    private func showAppChooser() {
        Task { @MainActor in
            // Present the chooser on the active manager modal, not the settings
            // window behind it. Retain the settings window as a fallback.
            guard let window = NSApp.keyWindow ?? SettingsWindowManager.shared.window else { return }
            let panel = NSOpenPanel()
            panel.worksWhenModal = true
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.allowedContentTypes = [.application]
            panel.allowsOtherFileTypes = false
            panel.resolvesAliases = true
            panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
            guard await panel.beginSheetModal(for: window) == .OK,
                  let url = panel.url,
                  let selected = await AppDefaultAppResources.metadata(at: url) else { return }
            var updated = apps
            let isNew = updated[selected.bundleID] == nil
            if isNew {
                updated[selected.bundleID] = AppWindowDefault(appName: selected.name, appURL: url)
            }
            // Commit once: two Defaults writes trigger redundant UI and observer
            // work. Re-selecting an app must preserve its frame and display.
            updated[selected.bundleID]?.appURL = url
            if isNew { pendingEditor = selected.bundleID }
            apps = updated
            if !isNew { selectedApp.wrappedValue = selected.bundleID }
        }
    }

    private func appAction(_ id: String) -> Binding<WindowAction> {
        Binding(get: { apps[id]?.action ?? .init(.custom) }, set: {
            apps[id]?.action = $0
        })
    }

    private func appDisplay(_ id: String) -> Binding<String?> {
        Binding(get: { apps[id]?.displayUUID }, set: { apps[id]?.displayUUID = $0 })
    }
}

/// Resolve the selected bundle first, then Launch Services for older preferences
/// or relocated apps. Icons are loaded once per row/location, not on each render.
private struct AppDefaultAppIcon: View {
    let bundleID: String
    let appURL: URL?
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .task(id: appURL) {
            let loaded = await AppDefaultAppResources.icon(bundleID: bundleID, appURL: appURL)
            guard !Task.isCancelled else { return }
            icon = loaded
        }
    }
}
