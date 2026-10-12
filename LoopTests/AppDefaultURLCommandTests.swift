//
//  AppDefaultURLCommandTests.swift
//  LoopTests
//

import AppKit
@testable import Loop
import Testing

struct AppDefaultURLCommandTests {
    @Test func focusedAppDefaultScreenRespectsCursorPreference() throws {
        let screen = try #require(NSScreen.screens.first)
        #expect(URLCommandHandler.focusedAppDefaultScreen(useScreenWithCursor: true, cursorScreen: screen, mainScreen: nil) == screen)
        #expect(URLCommandHandler.focusedAppDefaultScreen(useScreenWithCursor: false, cursorScreen: nil, mainScreen: screen) == screen)
        #expect(URLCommandHandler.focusedAppDefaultScreen(useScreenWithCursor: true, cursorScreen: nil, mainScreen: screen) == nil)
        #expect(URLCommandHandler.focusedAppDefaultScreen(useScreenWithCursor: false, cursorScreen: screen, mainScreen: nil) == nil)
    }

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
