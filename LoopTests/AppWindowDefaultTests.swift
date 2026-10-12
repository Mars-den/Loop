//
//  AppWindowDefaultTests.swift
//  LoopTests
//

import AppKit
@testable import Loop
import Testing

struct AppWindowDefaultTests {
    private let bounds = CGRect(x: -1920, y: 24, width: 1920, height: 1056)

    @Test func settingsStoreConfiguredPositionSizeAndDisplay() throws {
        let action = WindowAction(
            .custom, keybind: [], unit: .pixels, width: 800, height: 600,
            xPoint: 120, yPoint: 56, positionMode: .coordinates, sizeMode: .custom
        )
        let saved = AppWindowDefault(appName: "Finder", displayUUID: "display", action: action)
        #expect(saved.action.unit == .pixels)
        #expect(saved.action.xPoint == 120)
        #expect(saved.action.yPoint == 56)
        #expect(saved.action.width == 800)
        #expect(saved.action.height == 600)
        #expect(saved.action.positionMode == .coordinates)
        #expect(saved.action.sizeMode == .custom)
        let decoded = try JSONDecoder().decode(AppWindowDefault.self, from: JSONEncoder().encode(saved))
        #expect(decoded == saved)
    }

    @Test func displayIdentityWinsOverCurrentScreenAndArrayOrder() {
        #expect(AppWindowDefault.targetDisplayIndex(savedUUID: "saved", availableUUIDs: ["other", "saved"], currentIndex: 0) == 1)
        #expect(AppWindowDefault.targetDisplayIndex(savedUUID: "saved", availableUUIDs: ["saved", "other"], currentIndex: 1) == 0)
    }

    @Test func disconnectedDisplayFallsBackToWindowScreen() {
        #expect(AppWindowDefault.targetDisplayIndex(savedUUID: "missing", availableUUIDs: ["first", "current"], currentIndex: 1) == 1)
        #expect(AppWindowDefault.targetDisplayIndex(savedUUID: nil, availableUUIDs: [nil], currentIndex: 9) == 0)
        #expect(AppWindowDefault.targetDisplayIndex(savedUUID: "missing", availableUUIDs: [], currentIndex: 0) == nil)
    }

    @Test func offscreenFrameIsClampedOnNegativeOriginDisplay() {
        let frame = CGRect(x: 9000, y: -4000, width: 800, height: 600)
        #expect(AppWindowDefault.reachableFrame(frame, in: bounds) == CGRect(x: -800, y: 24, width: 800, height: 600))
    }

    @Test func smallerDisplayFitsSizeButAppMinimumKeepsTitleBarReachable() {
        let frame = CGRect(x: -500, y: 900, width: 2400, height: 1400)
        #expect(AppWindowDefault.reachableFrame(frame, in: bounds) == bounds)
        #expect(AppWindowDefault.reachableFrame(frame, in: bounds, fitSize: false) == CGRect(x: -1920, y: 24, width: 2400, height: 1400))
    }

    @Test func invalidAndEmptyFramesAreRejected() {
        #expect(AppWindowDefault.reachableFrame(.zero, in: bounds) == nil)
        #expect(AppWindowDefault.reachableFrame(CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10), in: bounds) == nil)
        #expect(AppWindowDefault.reachableFrame(bounds, in: .zero) == nil)
    }

    @Test func fallbackCannotRecurseOrPerformNonFrameActions() {
        for direction in [WindowDirection.useAppDefault, .saveAppDefault, .cycle, .hide, .nextScreen, .fullscreen, .stash] {
            #expect(AppWindowDefault.validatedFallback(.init(direction)).direction == .noAction)
        }
        for direction in [WindowDirection.custom, .center, .maximize, .initialFrame, .noAction] {
            #expect(AppWindowDefault.validatedFallback(.init(direction)).direction == direction)
        }
    }

    @Test func baselineAndDuplicateCreationNotificationsNeverReapply() {
        let existing = AXUIElementCreateApplication(100)
        let newWindow = AXUIElementCreateApplication(101)
        var tracker = AppDefaultWindowTracker()
        tracker.seed([existing])
        let existingClaim = tracker.claim(existing)
        let firstClaim = tracker.claim(newWindow)
        let duplicateClaim = tracker.claim(newWindow)
        #expect(!existingClaim)
        #expect(firstClaim)
        #expect(!duplicateClaim)
        // A preference update, focus change, or resize must not clear this state.
        tracker.seed([AXUIElementCreateApplication(102)])
        let claimAfterUpdate = tracker.claim(newWindow)
        #expect(!claimAfterUpdate)
    }

    @Test func appDefaultActionsHaveExpectedPipelineSemantics() {
        #expect(!WindowDirection.saveAppDefault.hasTargetFrame)
        #expect(WindowDirection.saveAppDefault.isNoOp)
        #expect(!WindowDirection.general.contains(.saveAppDefault))
        #expect(WindowDirection.useAppDefault.hasTargetFrame)
        #expect(WindowAction(.useAppDefault).allowsRepeatedSelection)
        #expect(!WindowAction(.useAppDefault).allowsRapidRepeat)
        #expect(WindowRecords.shared.shouldStoreAsFinalFrame(.init(.useAppDefault)))
        #expect(!WindowAction(.useAppDefault).isInnerPaddingApplicable)
    }

    @Test func addingAnAppDoesNotRequireCapturingARunningWindow() {
        let saved = AppWindowDefault(appName: "Finder")
        #expect(saved.displayUUID == nil)
        #expect(saved.action.direction == .custom)
        #expect(saved.action.sizeMode == .custom)
        #expect(saved.action.unit == .percentage)
        #expect(saved.action.width == 80)
        #expect(saved.action.height == 80)
        #expect(saved.action.anchor == .center)
    }

    @Test func selectedAppLocationPersistsWithoutChangingItsPreset() throws {
        let url = URL(fileURLWithPath: "/Users/example/Applications/Example.app")
        var saved = AppWindowDefault(appName: "Example", appURL: url, displayUUID: "display")
        let originalPreset = saved.action
        saved.appURL = URL(fileURLWithPath: "/Applications/Example.app")
        let decoded = try JSONDecoder().decode(AppWindowDefault.self, from: JSONEncoder().encode(saved))
        #expect(decoded.appURL == saved.appURL)
        #expect(decoded.action == originalPreset)
        #expect(decoded.displayUUID == "display")
    }

    @Test func defaultsWithoutStoredAppLocationsRemainCompatible() throws {
        let saved = AppWindowDefault(appName: "Finder", displayUUID: "display")
        let data = try JSONEncoder().encode(saved)
        #expect(!String(decoding: data, as: UTF8.self).contains("appURL"))
        let decoded = try JSONDecoder().decode(AppWindowDefault.self, from: data)
        #expect(decoded.appURL == nil)
        #expect(decoded.action == saved.action)
        #expect(decoded.displayUUID == "display")
    }

    @Test func fallbackIsIndependentForEachKeybindAndRetainsShortcutIdentity() throws {
        var first = WindowAction(.useAppDefault, keybind: [1])
        var second = WindowAction(.useAppDefault, keybind: [2])
        let originalID = first.id
        first.appDefaultFallback = .init(.leftHalf)
        second.appDefaultFallback = .init(.rightHalf)
        #expect(first.appDefaultFallback.direction == .leftHalf)
        #expect(second.appDefaultFallback.direction == .rightHalf)
        #expect(first.direction == .useAppDefault)
        #expect(first.id == originalID)
        #expect(first.keybind == [1])
        #expect(first.semanticKey != second.semanticKey)
        let decoded = try JSONDecoder().decode(WindowAction.self, from: JSONEncoder().encode(first))
        #expect(decoded == first)
        #expect(decoded.appDefaultFallback.direction == .leftHalf)
    }

    @Test func customFallbackPersistsItsOwnFrameParameters() throws {
        var action = WindowAction(.useAppDefault, keybind: [1])
        action.bypassTriggerKey = true
        action.appDefaultFallback = .init(
            .custom, keybind: [], unit: .pixels, width: 900, height: 700,
            xPoint: 40, yPoint: 60, positionMode: .coordinates, sizeMode: .custom
        )
        let decoded = try JSONDecoder().decode(WindowAction.self, from: JSONEncoder().encode(action))
        #expect(decoded.direction == .useAppDefault)
        #expect(decoded.appDefaultFallback.direction == .custom)
        #expect(decoded.appDefaultFallback.width == 900)
        #expect(decoded.appDefaultFallback.height == 700)
        #expect(decoded.appDefaultFallback.xPoint == 40)
        #expect(decoded.appDefaultFallback.yPoint == 60)
        #expect(decoded.keybind == [1])
        #expect(decoded.bypassTriggerKey == true)
        #expect(decoded.appDefaultFallback.keybind.isEmpty)
    }

    @Test func existingDevelopmentPreferencesMigrateWithoutLosingBindings() {
        let save = WindowAction(.saveAppDefault, keybind: [1])
        let use = WindowAction(.useAppDefault, keybind: [2])
        let cycle = WindowAction([save, use])
        let migrated = cycle.migratingAppDefaults(legacyFallback: .init(.maximize))
        #expect(migrated.id == cycle.id)
        #expect(migrated.cycle?[0].direction == .noAction)
        #expect(migrated.cycle?[0].id == save.id)
        #expect(migrated.cycle?[0].keybind == save.keybind)
        #expect(migrated.cycle?[1].appDefaultFallback.direction == .maximize)
        var configured = use
        configured.appDefaultFallback = .init(.center)
        #expect(configured.migratingAppDefaults(legacyFallback: .init(.maximize)) == configured)
    }

    @Test func olderSerializedActionsStillDecodeWithoutAFallbackField() throws {
        let action = WindowAction(.useAppDefault, keybind: [1])
        let data = try JSONEncoder().encode(action)
        #expect(!String(decoding: data, as: UTF8.self).contains("fallbackDirection"))
        let decoded = try JSONDecoder().decode(WindowAction.self, from: data)
        #expect(decoded.id == action.id)
        #expect(decoded.appDefaultFallback.direction == .noAction)
    }

    @Test func differentFallbacksParticipateInSemanticActionIdentity() {
        var first = WindowAction(.useAppDefault, keybind: [1])
        var second = first
        first.appDefaultFallback = .init(.leftHalf)
        second.appDefaultFallback = .init(.rightHalf)
        #expect(first.semanticKey != second.semanticKey)
        second.appDefaultFallback = .init(.leftHalf)
        #expect(first.semanticKey == second.semanticKey)
    }

    @Test func undoSnapshotsPreserveManualChangesAcrossDisplays() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        let manuallyMoved = CGRect(x: -1800, y: 90, width: 800, height: 600)
        let restored = CGRect(x: 2400, y: 140, width: 900, height: 700)
        var record = WindowRecords.Record(initialFrame: initial)
        record.appendExactFrame(manuallyMoved, action: .init(.custom))
        record.appendExactFrame(restored, action: .init(.custom))
        #expect(record.lastExactFrame == manuallyMoved)
        // Editing a preferred frame later cannot change history snapshots.
        record.removeCurrentAction()
        #expect(record.actions.count == 2)
        #expect(record.lastExactFrame == nil)
        #expect(record.initialFrame == initial)
    }
}
