//
//  AppDefaultMigrationTests.swift
//  LoopTests
//

import Foundation
@testable import Loop
import Testing

struct AppDefaultMigrationTests {
    /// Exercise the representation used by Export Keybinds, not WindowAction's
    /// separate Defaults encoding. Keep the tests independent of user preferences.
    private func roundTrip(_ actions: [WindowAction]) throws -> [WindowAction] {
        let export = SavedKeybindsFormat(
            version: "test", triggerKey: [], actions: actions.map(SavedWindowActionFormat.init)
        )
        let data = try JSONEncoder().encode(export)
        return try JSONDecoder().decode(SavedKeybindsFormat.self, from: data).actions.map { $0.convertToWindowAction() }
    }

    @Test func exportedBindingsPreserveIndependentFallbacks() throws {
        var first = WindowAction(.useAppDefault, keybind: [1])
        var second = WindowAction(.useAppDefault, keybind: [2])
        first.appDefaultFallback = .init(.leftHalf)
        second.appDefaultFallback = .init(.rightHalf)

        let imported = try roundTrip([first, second])
        #expect(imported.count == 2)
        #expect(imported[0].direction == .useAppDefault)
        #expect(imported[0].keybind == first.keybind)
        #expect(imported[1].keybind == second.keybind)
        #expect(imported[0].appDefaultFallback.direction == .leftHalf)
        #expect(imported[1].appDefaultFallback.direction == .rightHalf)
    }

    @Test func customFallbackSurvivesExportInsideNestedCycles() throws {
        var action = WindowAction(.useAppDefault, keybind: [3])
        action.appDefaultFallback = .init(
            .custom, keybind: [], name: "Fallback", unit: .pixels, anchor: .topLeft,
            width: 900, height: 700, xPoint: 40, yPoint: 60,
            positionMode: .coordinates, sizeMode: .custom
        )
        let cycle = WindowAction("Outer", cycle: [WindowAction("Inner", cycle: [action])], keybind: [4])

        let imported = try #require(try roundTrip([cycle]).first)
        let nested = try #require(imported.cycle?.first?.cycle?.first)
        #expect(imported.keybind == cycle.keybind)
        #expect(nested.direction == .useAppDefault)
        #expect(nested.keybind == action.keybind)
        #expect(nested.appDefaultFallback.semanticKey == action.appDefaultFallback.semanticKey)
    }

    @Test func legacyExportWithoutFallbackDirectionStillImports() throws {
        // Literal historical schema: absent fields must not become required when
        // the new export format gains an optional fallbackDirection.
        let data = Data(#"{"version":"1.2.0","actions":[{"direction":"UseAppDefault","keybind":[1]},{"direction":"Cycle","keybind":[2],"cycle":[{"direction":"UseAppDefault","keybind":[]}]}]}"#.utf8)
        let saved = try JSONDecoder().decode(SavedKeybindsFormat.self, from: data)
        let imported = saved.actions.map { $0.convertToWindowAction() }
        #expect(saved.actions[0].fallbackDirection == nil)
        #expect(imported[0].keybind == [1])
        #expect(imported[0].appDefaultFallback.direction == .noAction)
        #expect(imported[1].cycle?.first?.appDefaultFallback.direction == .noAction)
        #expect(imported[1].cycle?.first?.fallbackDirection == nil)
    }

    @Test func unconfiguredBindingsKeepTheOptionalFieldAbsentOnExport() throws {
        let action = WindowAction(.useAppDefault, keybind: [1])
        let data = try JSONEncoder().encode(SavedWindowActionFormat(action))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["fallbackDirection"] == nil)
        #expect(try roundTrip([action])[0].fallbackDirection == nil)
    }
}
