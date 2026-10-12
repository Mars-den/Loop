//
//  WindowRecords.swift
//  Loop
//
//  Created by Kai Azim on 2023-09-23.
//

import Scribe
import SwiftUI

@Loggable
actor WindowRecords {
    nonisolated static let shared = WindowRecords()

    private var recordsByWindowID: [CGWindowID: WindowRecords.Record] = [:]

    struct Record {
        let initialFrame: CGRect
        private(set) var actions: [WindowAction]
        var exactFrames: [UUID: CGRect] = [:]
        /// History entries have their own identities; shortcut IDs may recur.
        private var historyEntryIDs = [UUID()]

        init(initialFrame: CGRect) {
            self.initialFrame = initialFrame
            self.actions = [.init(.initialFrame)]
        }

        mutating func appendAction(_ action: WindowAction) {
            actions.insert(action, at: 0)
            historyEntryIDs.insert(UUID(), at: 0)
        }

        /// Keep a concrete action as well as the absolute frame. Screen-switching
        /// can still reuse the action, while Undo restores exact global geometry.
        mutating func appendExactFrame(_ frame: CGRect, action: WindowAction) {
            appendAction(action)
            exactFrames[historyEntryIDs[0]] = frame
        }

        var lastExactFrame: CGRect? {
            guard actions.count >= 2 else { return nil }
            return exactFrames[historyEntryIDs[1]]
        }

        var currentExactFrame: CGRect? {
            exactFrames[historyEntryIDs[0]]
        }

        /// A completed default is one transition. Preserve manual changes only
        /// when they are not already represented by the current history entry.
        mutating func commitAppDefaultTransition(
            before: CGRect, after: CGRect, representedFrame: CGRect?,
            beforeAction: WindowAction, afterAction: WindowAction
        ) {
            guard !Task.isCancelled, before.isFinite, after.isFinite,
                  before.width > 0, before.height > 0, after.width > 0, after.height > 0,
                  !before.approximatelyEqual(to: after, tolerance: 1) else { return }
            let currentFrame = currentExactFrame ?? representedFrame
            if currentFrame?.approximatelyEqual(to: before, tolerance: 1) == true {
                exactFrames[historyEntryIDs[0]] = before
            } else {
                appendExactFrame(before, action: beforeAction)
            }
            appendExactFrame(after, action: afterAction)
        }

        mutating func removeCurrentAction() {
            guard actions.count > 1 else { return }
            actions.removeFirst()
            exactFrames[historyEntryIDs.removeFirst()] = nil
        }
    }

    /// Pre-resolved snapshot of a window's records for synchronous access.
    struct ResolvedRecord {
        let initialFrame: CGRect?
        let lastAction: WindowAction?
        let currentAction: WindowAction?
        let lastExactFrame: CGRect?
        let currentExactFrame: CGRect?

        init(for window: Window) async {
            self.initialFrame = await WindowRecords.shared.getInitialFrame(for: window)
            self.lastAction = await WindowRecords.shared.getLastAction(for: window)
            self.currentAction = await WindowRecords.shared.getCurrentAction(for: window)
            self.lastExactFrame = await WindowRecords.shared.getLastExactFrame(for: window)
            self.currentExactFrame = await WindowRecords.shared.getCurrentExactFrame(for: window)
        }

        init(record: Record?) {
            self.initialFrame = record?.initialFrame
            self.lastAction = record.flatMap { $0.actions.count >= 2 ? $0.actions[1] : nil }
            self.currentAction = record?.actions.first
            self.lastExactFrame = record?.lastExactFrame
            self.currentExactFrame = record?.currentExactFrame
        }
    }

    private func getLastExactFrame(for window: Window) -> CGRect? {
        recordsByWindowID[window.cgWindowID]?.lastExactFrame
    }

    private func getCurrentExactFrame(for window: Window) -> CGRect? {
        recordsByWindowID[window.cgWindowID]?.currentExactFrame
    }

    /// Erase all previous records for a window
    /// - Parameter window: Window to erase
    func eraseRecords(for window: Window) {
        guard recordsByWindowID[window.cgWindowID] != nil else {
            // Records don't exist
            return
        }

        recordsByWindowID[window.cgWindowID] = nil
        log.success("Erased records for: \(window)")
    }

    /// Records the window's initial frame if no record exists yet.
    /// - Parameters:
    ///   - window: the window to record.
    ///   - resolvedProperties: pre-resolved properties to avoid redundant AX calls. Falls back to `window.frame` if nil.
    func recordFirstIfNeeded(for window: Window, resolvedProperties: Window.ResolvedProperties?) {
        guard recordsByWindowID[window.cgWindowID] == nil else { return }
        recordsByWindowID[window.cgWindowID] = Record(initialFrame: resolvedProperties?.frame ?? window.frame)
        log.info("Recorded first for: \(window)")
    }

    /// Determines if an action should be recorded using its frame instead of the action applied onto it.
    /// - Parameter action: the action to apply onto the window.
    /// - Returns: Whether this action should be recorded with its final frame instead of using the action.
    nonisolated func shouldStoreAsFinalFrame(_ action: WindowAction) -> Bool {
        // Actions that are stored as frames need to be recorded *after* resize.
        // These actions are context-dependent, and cannot simply be called as an action to restore the previous state.
        let storeAsFrame = action.direction.willChangeScreen || action.willManipulateExistingWindowFrame || action.direction == .useAppDefault
        return storeAsFrame
    }

    /// Record a window's action in the records array.
    /// - Parameters:
    ///   - window: Window to record.
    ///   - resolvedProperties: pre-resolved properties to avoid redundant AX calls. Falls back to `window.frame` if nil.
    ///   - action: WindowAction to record.
    func record(_ window: Window, resolvedProperties: Window.ResolvedProperties?, _ action: WindowAction) {
        // If the window has not been recorded, record it
        recordFirstIfNeeded(for: window, resolvedProperties: resolvedProperties)

        // There is no point in recording undo
        guard action.direction != .undo else {
            return
        }

        if shouldStoreAsFinalFrame(action), let screen = ScreenUtility.screenContaining(window) {
            let customActionName = "autogenerated_record_\(action.getName())"
            let windowFrame = resolvedProperties?.frame ?? window.frame
            let adjustedBounds = PaddingConfiguration
                .getConfiguredPadding(for: screen)
                .applyToBounds(screen.cgSafeScreenFrame, screen: screen)

            let proportionalSize = CGRect(
                x: (windowFrame.minX - adjustedBounds.minX) / adjustedBounds.width,
                y: (windowFrame.minY - adjustedBounds.minY) / adjustedBounds.height,
                width: windowFrame.width / adjustedBounds.width,
                height: windowFrame.height / adjustedBounds.height
            )

            let action = WindowAction(
                .custom,
                keybind: [],
                name: customActionName,
                unit: .percentage,
                anchor: nil,
                width: proportionalSize.width * 100,
                height: proportionalSize.height * 100,
                xPoint: proportionalSize.minX * 100,
                yPoint: proportionalSize.minY * 100,
                positionMode: .coordinates,
                sizeMode: .custom
            )

            recordsByWindowID[window.cgWindowID]?.appendAction(action)
        } else {
            recordsByWindowID[window.cgWindowID]?.appendAction(action)
        }

        log.info("Recorded: \(action) for: \(window)")
    }

    func recordAppDefaultTransition(
        for window: Window, before: CGRect, after: CGRect, representedFrame: CGRect?,
        beforeBounds: CGRect, afterBounds: CGRect
    ) {
        guard !Task.isCancelled,
              let beforeAction = AppWindowDefault.transferableAction(.init(.custom), frame: before, bounds: beforeBounds),
              let afterAction = AppWindowDefault.transferableAction(.init(.custom), frame: after, bounds: afterBounds) else { return }
        recordFirstIfNeeded(for: window, resolvedProperties: nil)
        recordsByWindowID[window.cgWindowID]?.commitAppDefaultTransition(
            before: before, after: after, representedFrame: representedFrame,
            beforeAction: beforeAction, afterAction: afterAction
        )
    }

    /// Removes the last action performed on the specified window. This will NOT remove the first action for the specified window.
    func removeLastAction(for window: Window) {
        guard let record = recordsByWindowID[window.cgWindowID],
              record.actions.count > 1
        else {
            log.info("Skipped removing last record for: \(window)")
            return
        }

        recordsByWindowID[window.cgWindowID]?.removeCurrentAction()

        log.info("Removed last record for: \(window)")
    }

    /// This window's last action
    /// - Parameters:
    ///   - window: Window to check
    /// - Returns: The window action
    func getLastAction(for window: Window) -> WindowAction? {
        guard let record = recordsByWindowID[window.cgWindowID],
              record.actions.count >= 2
        else {
            return nil
        }

        return record.actions[1]
    }

    /// This window's current recorded action
    /// - Parameters:
    ///   - window: Window to check
    /// - Returns: The window action
    func getCurrentAction(for window: Window) -> WindowAction? {
        guard let record = recordsByWindowID[window.cgWindowID],
              record.actions.count >= 1
        else {
            return nil
        }

        return record.actions[0]
    }

    func getInitialFrame(for window: Window) -> CGRect? {
        recordsByWindowID[window.cgWindowID]?.initialFrame
    }
}
