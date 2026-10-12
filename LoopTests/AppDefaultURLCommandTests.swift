//
//  AppDefaultURLCommandTests.swift
//  LoopTests
//

@testable import Loop
import Testing

struct AppDefaultURLCommandTests {
    @Test func directAppDefaultCommandsUseFocusedApplication() throws {
        for name in ["UseAppDefault", "useappdefault", "USEAPPDEFAULT"] {
            let direction = try #require(URLCommandHandler.commandDirection(named: name))
            #expect(direction == .useAppDefault)
            #expect(URLCommandHandler.usesFocusedApplication(for: .init(direction)))
        }
    }

    @Test func namedAppDefaultKeybindUsesFocusedApplication() {
        let keybind = WindowAction(.useAppDefault, keybind: [], name: "My app default")
        #expect(URLCommandHandler.usesFocusedApplication(for: keybind))
    }

    @Test func otherActionsKeepUserDefinedWindowTargeting() {
        for direction in URLCommandHandler.availableDirections where direction != .useAppDefault {
            #expect(!URLCommandHandler.usesFocusedApplication(for: .init(direction)))
        }
    }

    @Test func legacySaveActionIsNotAdvertisedOrParsed() {
        #expect(!URLCommandHandler.availableDirections.contains(.saveAppDefault))
        #expect(URLCommandHandler.availableDirections.contains(.useAppDefault))
        #expect(URLCommandHandler.commandDirection(named: "SaveAppDefault") == nil)
        #expect(URLCommandHandler.commandDirection(named: "saveappdefault") == nil)
        #expect(URLCommandHandler.commandDirection(named: "leftHalf") == .leftHalf)
    }
}
