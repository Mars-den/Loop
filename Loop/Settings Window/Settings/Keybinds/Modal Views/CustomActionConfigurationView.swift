//
//  CustomActionConfigurationView.swift
//  Loop
//
//  Created by Kai Azim on 2024-04-27.
//

import Defaults
import Luminare
import SwiftUI

struct CustomActionConfigurationView: View {
    @Environment(\.luminareAnimation) private var luminareAnimation

    @Binding private var windowAction: WindowAction
    @Binding private var isPresented: Bool

    @State private var action: WindowAction
    @State private var currentTab: Tab = .position
    @State private var isDeferringExternalCommit = false
    @State private var screens = NSScreen.screens
    private let preferredDisplay: Binding<String?>?
    private let allowsDynamicSize: Bool

    private enum Tab: LocalizedStringKey, CaseIterable {
        case position = "Position", size = "Size"

        var image: Image {
            switch self {
            case .position:
                Image(systemName: "viewfinder")
            case .size:
                Image(systemName: "rectangle.expand.diagonal")
            }
        }
    }

    private let anchors: [CustomWindowActionAnchor] = [
        .topLeft, .top, .topRight, .left, .center, .right, .bottomLeft, .bottom, .bottomRight
    ]

    private var actionUnit: CustomWindowActionUnit {
        action.unit ?? .percentage
    }

    private var showMacOSCenterToggle: Bool {
        action.anchor ?? .center == .center || action.anchor == .macOSCenter
    }

    private let previewController = PreviewController()
    private var selectedScreen: NSScreen? {
        screens.first { $0.appDefaultDisplayUUID == preferredDisplay?.wrappedValue && preferredDisplay?.wrappedValue != nil }
            ?? NSScreen.main ?? screens.first
    }

    private var screenSize: CGSize { selectedScreen?.frame.size ?? .zero }

    init(
        action: Binding<WindowAction>, isPresented: Binding<Bool>,
        preferredDisplay: Binding<String?>? = nil, allowsDynamicSize: Bool = true
    ) {
        _windowAction = action
        _isPresented = isPresented
        _action = State(initialValue: action.wrappedValue)
        self.preferredDisplay = preferredDisplay
        self.allowsDynamicSize = allowsDynamicSize
    }

    var body: some View {
        LuminareForm {
            ScreenView(isBlurred: action.sizeMode != .custom) {
                ActionPreview(action: action)
            }

            configurationSections()
            actionButtons()
        }
        .onChange(of: action) { newValue in
            guard !isDeferringExternalCommit else { return }
            windowAction = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

    @ViewBuilder
    private func configurationSections() -> some View {
        if let preferredDisplay {
            LuminareSection {
                LuminarePickerMenu("Display", selection: displaySelection(preferredDisplay), items: displayChoices(preferredDisplay)) { uuid in
                    Text(displayName(uuid))
                }
            }
        } else {
            LuminareSection(outerPadding: 0) {
                LuminareTextField(
                    WindowDirection.custom.name,
                    text: Binding(
                        get: { action.name ?? "" },
                        set: { action.name = $0 }
                    )
                )
                .luminareFilledStates(.none)
                .luminareBorderedStates(.none)
            }
        }

        LuminareSection(outerPadding: 0) {
            tabPicker()
            unitToggle()
        }

        LuminareSection(outerPadding: 0) {
            if currentTab == .position {
                positionConfiguration()
            } else {
                sizeConfiguration()
            }
        }
        .animation(luminareAnimation, value: action.unit)
        .onAppear {
            if action.unit == nil {
                action.unit = .percentage
            }

            if action.sizeMode == nil || !allowsDynamicSize {
                action.sizeMode = .custom
            }

            if action.width == nil {
                action.width = 80
            }

            if action.height == nil {
                action.height = 80
            }

            if action.positionMode == nil {
                action.positionMode = .generic
            }

            if action.anchor == nil {
                action.anchor = .center
            }
        }
    }

    private func tabPicker() -> some View {
        LuminarePicker(
            elements: Tab.allCases,
            selection: $currentTab.animation(luminareAnimation),
            columns: 2
        ) { tab in
            HStack(spacing: 6) {
                tab.image
                Text(tab.rawValue)
            }
            .fixedSize()
        }
        .luminareContentSize(hasFixedHeight: true)
        .luminareRoundingBehavior(top: true)
    }

    private func unitToggle() -> some View {
        LuminareToggle("Use pixels", isOn: Binding(get: { action.unit == .pixels }, set: { action.unit = $0 ? .pixels : .percentage }))
            .onChange(of: actionUnit) { unit in
                if unit == .percentage {
                    if let xPoint = action.xPoint { action.xPoint = max(0, min(100, xPoint)) }
                    if let yPoint = action.yPoint { action.yPoint = max(0, min(100, yPoint)) }
                    if let width = action.width { action.width = max(0, min(100, width)) }
                    if let height = action.height { action.height = max(0, min(100, height)) }
                }
            }
    }

    private func actionButtons() -> some View {
        HStack(spacing: 8) {
            Button("Preview") {}
                .onLongPressGesture(
                    // Allows for a press-and-hold gesture to show the preview
                    minimumDuration: 100.0,
                    maximumDistance: .infinity,
                    pressing: { pressing in
                        if pressing {
                            guard let screen = selectedScreen else { return }
                            let context = ResizeContext(screen: screen, padding: preferredDisplay == nil ? nil : .zero)
                            context.setAction(to: action, parent: nil)
                            previewController.open(context: context)
                        } else {
                            previewController.close()
                        }
                    },
                    perform: {}
                )
                .disabled(action.sizeMode != .custom)

            Button {
                isPresented = false
            } label: {
                Text("Done", comment: "Label for a button that closes a modal window")
            }
        }
        .buttonStyle(.luminare(overrideUseMainStyle: true))
        .luminareCornerRadius(8)
    }

    @ViewBuilder
    private func positionConfiguration() -> some View {
        LuminareToggle(
            "Use coordinates",
            isOn: Binding(
                get: {
                    action.positionMode == .coordinates
                },
                set: { newValue in
                    withAnimation(luminareAnimation) {
                        action.positionMode = newValue ? .coordinates : .generic
                    }
                }
            )
        )

        if action.positionMode ?? .generic == .generic {
            LuminarePicker(
                elements: anchors,
                selection: Binding(
                    get: {
                        // since center/macOS center use the same icon on the picker
                        if action.anchor == .macOSCenter {
                            return .center
                        }

                        return action.anchor ?? .center
                    },
                    set: { newValue in
                        withAnimation(luminareAnimation) {
                            action.anchor = newValue
                        }
                    }
                ),
                columns: 3
            ) { anchor in
                if let action = anchor.iconAction {
                    IconView(action: action)
                }
            }
            .luminareRoundingBehavior(bottom: !showMacOSCenterToggle)

            if showMacOSCenterToggle {
                LuminareToggle(
                    isOn: Binding(
                        get: {
                            action.anchor == .macOSCenter
                        },
                        set: {
                            action.anchor = $0 ? .macOSCenter : .center
                        }
                    )
                ) {
                    if let infoText = action.direction.infoText {
                        Text("Use macOS center", comment: "Toggle to enable macOS-style centering in custom actions")
                            .padding(.trailing, 4)
                            .luminareToolTip(attachedTo: .topTrailing) {
                                Text(infoText)
                                    .padding(6)
                            }
                    } else {
                        Text("Use macOS center", comment: "Toggle to enable macOS-style centering in custom actions")
                    }
                }
            }
        } else {
            LuminareSlider(
                String(localized: "X", comment: "X axis label"),
                value: Binding(
                    get: {
                        action.xPoint ?? 0
                    },
                    set: {
                        action.xPoint = actionUnit.roundIfNeeded($0)
                    }
                ),
                in: actionUnit == .percentage ? 0...100 : 0...Double(screenSize.width),
                format: .number.precision(actionUnit.fractionLength),
                clampsUpper: false,
                suffix: Text(action.unit?.suffix ?? CustomWindowActionUnit.percentage.suffix),
                onEditingChanged: handleSliderEditingChanged,
                onEditingCommit: commitSliderChanges
            )

            LuminareSlider(
                String(localized: "Y", comment: "Y axis label"),
                value: Binding(
                    get: {
                        action.yPoint ?? 0
                    },
                    set: {
                        action.yPoint = actionUnit.roundIfNeeded($0)
                    }
                ),
                in: actionUnit == .percentage ? 0...100 : 0...Double(screenSize.height),
                format: .number.precision(actionUnit.fractionLength),
                clampsUpper: false,
                suffix: Text(action.unit?.suffix ?? CustomWindowActionUnit.percentage.suffix),
                onEditingChanged: handleSliderEditingChanged,
                onEditingCommit: commitSliderChanges
            )
        }
    }

    @ViewBuilder
    private func sizeConfiguration() -> some View {
        if allowsDynamicSize {
            LuminarePicker(
                elements: CustomWindowActionSizeMode.allCases,
                selection: Binding(
                    get: {
                        action.sizeMode ?? .custom
                    },
                    set: { newValue in
                        withAnimation(luminareAnimation) {
                            action.sizeMode = newValue
                        }
                    }
                ),
                columns: 3
            ) { mode in
                VStack(spacing: 4) {
                    mode.image
                    Text(mode.name)
                }
                .padding(.vertical, 15)
                .compositingGroup()
            }
            .luminareContentSize(hasFixedHeight: true)
            .luminareRoundingBehavior(
                top: true,
                bottom: action.sizeMode != .custom
            )
        }

        if action.sizeMode ?? .custom == .custom {
            LuminareSlider(
                "Width",
                value: Binding(
                    get: {
                        action.width ?? 100
                    },
                    set: {
                        action.width = actionUnit.roundIfNeeded($0)
                    }
                ),
                in: actionUnit == .percentage ? 0...100 : 0...Double(screenSize.width),
                format: .number.precision(actionUnit.fractionLength),
                clampsUpper: false,
                suffix: .init(action.unit?.suffix ?? CustomWindowActionUnit.percentage.suffix),
                onEditingChanged: handleSliderEditingChanged,
                onEditingCommit: commitSliderChanges
            )

            LuminareSlider(
                "Height",
                value: Binding(
                    get: {
                        action.height ?? 100
                    },
                    set: {
                        action.height = actionUnit.roundIfNeeded($0)
                    }
                ),
                in: actionUnit == .percentage ? 0...100 : 0...Double(screenSize.height),
                format: .number.precision(actionUnit.fractionLength),
                clampsUpper: false,
                suffix: .init(action.unit?.suffix ?? CustomWindowActionUnit.percentage.suffix),
                onEditingChanged: handleSliderEditingChanged,
                onEditingCommit: commitSliderChanges
            )
        }
    }

    private func handleSliderEditingChanged(_ isEditing: Bool) {
        isDeferringExternalCommit = isEditing
    }

    /// Keep disconnected display identities selectable, rather than silently
    /// overwriting them when opening the editor or reconnecting a monitor.
    private func displayChoices(_ binding: Binding<String?>) -> [String] {
        var choices = [""] + screens.compactMap(\.appDefaultDisplayUUID)
        if let saved = binding.wrappedValue, !choices.contains(saved) { choices.append(saved) }
        return choices
    }

    private func displayName(_ uuid: String) -> String {
        if uuid.isEmpty { return String(localized: "Current display") }
        return screens.first { $0.appDefaultDisplayUUID == uuid }?.localizedName ?? String(localized: "Disconnected display")
    }

    private func displaySelection(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func commitSliderChanges() {
        isDeferringExternalCommit = false
        windowAction = action
    }
}
