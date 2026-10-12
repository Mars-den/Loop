//
//  AppDefaultActionConfigurationView.swift
//  Loop
//

import Luminare
import SwiftUI

/// Fallback belongs to the selected keybind, just like a custom frame or cycle.
struct AppDefaultActionConfigurationView: View {
    @Binding var action: WindowAction
    @Binding var isPresented: Bool
    @State private var isConfiguringFrame = false

    var body: some View {
        LuminareForm {
            LuminareSection {
                LuminarePickerMenu("When no default is saved", selection: fallbackDirection, items: AppWindowDefault.fallbackDirections) {
                    Text($0.name)
                }
                if action.appDefaultFallback.direction == .custom {
                    LuminareButton("Fallback frame", "Configure…") { isConfiguringFrame = true }
                        .luminareModal(isPresented: $isConfiguringFrame) {
                            CustomActionConfigurationView(action: fallbackAction, isPresented: $isConfiguringFrame)
                                .frame(width: 400)
                        }
                        .luminareModalCornerRadius(24)
                }
            }
            Button("Done") { isPresented = false }
                .buttonStyle(.luminare(overrideUseMainStyle: true))
        }
    }

    private var fallbackDirection: Binding<WindowDirection> {
        Binding(get: { action.appDefaultFallback.direction }, set: { action.appDefaultFallback = .init($0) })
    }

    private var fallbackAction: Binding<WindowAction> {
        Binding(get: { action.appDefaultFallback }, set: { action.appDefaultFallback = $0 })
    }
}
