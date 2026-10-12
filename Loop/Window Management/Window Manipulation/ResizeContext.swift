//
//  ResizeContext.swift
//  Loop
//
//  Created by Kai Azim on 2026-01-19.
//

import Scribe
import SwiftUI

// MARK: - ResizeContext

/// Holds transient state for a window resize operation.
/// This context tracks the target frame and which edges to adjust during grow/shrink actions,
/// along with the window, screen, and bounds information needed to compute frames.
@Loggable
final class ResizeContext {
    struct PreparedWindowTarget {
        fileprivate let window: Window?
        fileprivate let resolvedWindowProperties: Window.ResolvedProperties?
        fileprivate let resolvedRecord: WindowRecords.ResolvedRecord?
        /// The frame grow/shrink/move should start from, using the revealed frame for stashed windows
        fileprivate let baseFrame: CGRect?
    }

    private(set) var window: Window?

    private(set) var screen: NSScreen?
    private(set) var bounds: CGRect

    private(set) var padding: PaddingConfiguration = .zero
    private(set) var paddedBounds: CGRect

    private(set) var action: WindowAction = .init(.noSelection)
    private(set) var parentAction: WindowAction?

    /// Used for larger/smaller actions where the sides to adjust need to persist across frame calculations
    var sidesToAdjust: Edge.Set?

    /// Used to open radial menu at the correct position.
    private(set) var initialMousePosition: CGPoint = .zero

    var resolvedWindowProperties: Window.ResolvedProperties?
    var resolvedRecord: WindowRecords.ResolvedRecord?

    private(set) var cachedTargetFrame: ComputedFrame = .zero
    private var needsRecompute: Bool = false
    private var cycleActionCoordinator = CycleActionCoordinator()
    var lastAppliedFrame: CGRect?

    /// A saved app frame bypasses padding: it already describes the actual window.
    var appDefaultFrame: CGRect?
    var exactUndoFrame: CGRect?
    private var appDefaultTransferActionID: UUID?
    private var appDefaultHasNoTargetFrame = false

    init(
        window: Window? = nil,
        initialFrame: CGRect? = nil,
        screen: NSScreen? = nil,
        bounds: CGRect? = nil,
        padding: PaddingConfiguration? = nil,
        action: WindowAction = .init(.noSelection),
        parentAction: WindowAction? = nil,
        initialMousePosition: CGPoint = .zero
    ) {
        let frame = initialFrame ?? window?.frame ?? .zero
        let bounds = bounds ?? screen?.cgSafeScreenFrame ?? .zero
        let padding = padding ?? PaddingConfiguration.getConfiguredPadding(for: screen)

        self.window = window
        self.cachedTargetFrame = ComputedFrame(raw: frame, normalized: .zero, padded: frame)
        self.screen = screen
        self.bounds = bounds
        self.padding = padding
        self.paddedBounds = padding.applyToBounds(bounds, screen: screen)
        self.action = action
        self.parentAction = parentAction
        self.initialMousePosition = initialMousePosition
        self.needsRecompute = !action.direction.isNoOp
    }

    func setScreen(to screen: NSScreen?, padding override: PaddingConfiguration? = nil) {
        self.screen = screen
        bounds = screen?.cgSafeScreenFrame ?? .zero
        padding = override ?? (action.id == appDefaultTransferActionID ? .zero : PaddingConfiguration.getConfiguredPadding(for: screen))
        paddedBounds = padding.applyToBounds(bounds, screen: screen)
        lastAppliedFrame = nil
        needsRecompute = true
    }

    /// Resolves the state needed before switching target windows
    @concurrent
    static func prepareWindowTarget(_ window: Window?) async -> PreparedWindowTarget {
        let resolvedWindowProperties = window.map(Window.ResolvedProperties.init(from:))
        let resolvedRecord: WindowRecords.ResolvedRecord? = if let window {
            await WindowRecords.ResolvedRecord(for: window)
        } else {
            nil
        }

        // Matches how Loop opens on a stashed window, so resizing doesn't start from the off-screen frame
        let baseFrame: CGRect? = if let window,
                                    let revealedFrame = await StashManager.shared.getRevealedFrameForStashedWindow(id: window.cgWindowID) {
            revealedFrame
        } else {
            resolvedWindowProperties?.frame
        }

        return PreparedWindowTarget(
            window: window,
            resolvedWindowProperties: resolvedWindowProperties,
            resolvedRecord: resolvedRecord,
            baseFrame: baseFrame
        )
    }

    /// Switches to a prepared target window and its resolved state
    func commitWindowTarget(_ target: PreparedWindowTarget) {
        let window = target.window

        self.window = window
        resolvedWindowProperties = target.resolvedWindowProperties
        resolvedRecord = target.resolvedRecord
        lastAppliedFrame = nil

        // Reset the cached base frame to the new window's actual frame. Otherwise a sequence
        // like `focus to another window > grow` would resize the newly-focused window using
        // the *previous* window's cached frame — grow/shrink/move read `cachedTargetFrame.raw`
        // as their base until a frame has been applied.
        if let frame = target.baseFrame {
            cachedTargetFrame = ComputedFrame(raw: frame, normalized: .zero, padded: frame)
        }

        needsRecompute = true

        log.info("Set window to \(window?.description ?? "nil")")
    }

    func proposeCycleAction(
        in cycleAction: WindowAction,
        restartAtBeginningWhenInterrupted: Bool,
        mode: CycleActionCoordinator.SelectionMode
    ) -> CycleActionCoordinator.Proposal? {
        cycleActionCoordinator.proposeAction(
            for: window?.cgWindowID ?? 0,
            in: cycleAction,
            currentAction: action,
            currentParentAction: parentAction,
            recordedAction: resolvedRecord?.currentAction,
            restartAtBeginningWhenInterrupted: restartAtBeginningWhenInterrupted,
            mode: mode
        )
    }

    func commitCycleAction(
        _ proposal: CycleActionCoordinator.Proposal,
        in cycleAction: WindowAction
    ) -> WindowAction? {
        cycleActionCoordinator.commit(
            proposal,
            for: window?.cgWindowID ?? 0,
            in: cycleAction
        )
    }

    func setAction(
        to newAction: WindowAction,
        parent newParentAction: WindowAction?
    ) {
        cycleActionCoordinator.recordActionTransition(
            from: action,
            currentParentAction: parentAction,
            to: newAction,
            newParentAction: newParentAction
        )

        if action.direction == .undo, newAction.direction != .undo {
            padding = PaddingConfiguration.getConfiguredPadding(for: screen)
            paddedBounds = padding.applyToBounds(bounds, screen: screen)
        }
        if let transferID = appDefaultTransferActionID, newAction.id != transferID || newAction.direction != .custom {
            appDefaultTransferActionID = nil
            padding = PaddingConfiguration.getConfiguredPadding(for: screen)
            paddedBounds = padding.applyToBounds(bounds, screen: screen)
        }
        exactUndoFrame = nil
        appDefaultHasNoTargetFrame = false
        action = newAction
        parentAction = newParentAction
        needsRecompute = true
    }

    /// Re-fetches the window's AX properties and record snapshot from the actor.
    func refreshResolvedState() async {
        guard let window else {
            resolvedWindowProperties = nil
            resolvedRecord = nil
            return
        }

        resolvedWindowProperties = Window.ResolvedProperties(from: window)
        resolvedRecord = await WindowRecords.ResolvedRecord(for: window)
    }

    /// Creates a lightweight child context that shares this context's resolved state but uses a different action and bounds.
    /// Used for recursive frame resolution (e.g. undo) without additional AX calls.
    func derivedContext(action newAction: WindowAction, bounds newBounds: CGRect, padding newPadding: PaddingConfiguration = .zero) -> ResizeContext {
        // Pass window: nil to skip eager AX resolution in init; we overwrite with the parent's (the currently stored) snapshot.
        let context = ResizeContext(
            initialFrame: resolvedWindowProperties?.frame,
            screen: screen,
            bounds: newBounds,
            padding: newPadding,
            action: newAction,
            initialMousePosition: initialMousePosition
        )
        context.window = window
        context.resolvedWindowProperties = resolvedWindowProperties
        context.resolvedRecord = resolvedRecord
        context.sidesToAdjust = sidesToAdjust
        if newAction.id == appDefaultTransferActionID { context.appDefaultTransferActionID = appDefaultTransferActionID }
        return context
    }

    /// Shared effective context for both preview and execution. In particular,
    /// fallback padding belongs to the fallback, not to the App Default wrapper.
    func effectiveAppDefaultContext(savedFrame: CGRect?) -> ResizeContext? {
        let effectiveAction = savedFrame == nil ? action.appDefaultFallback : action
        guard !effectiveAction.direction.isNoOp else { return nil }
        let context = ResizeContext(
            initialFrame: cachedTargetFrame.raw, screen: screen, bounds: bounds,
            padding: savedFrame == nil ? padding : .zero, action: effectiveAction
        )
        context.window = window
        context.resolvedWindowProperties = resolvedWindowProperties
        context.resolvedRecord = resolvedRecord
        context.lastAppliedFrame = lastAppliedFrame
        context.sidesToAdjust = sidesToAdjust
        context.appDefaultFrame = savedFrame
        return context
    }

    /// Live resizing must retain the actual frame, including an app's size constraints,
    /// without overwriting a newer selection or a different target window.
    func adoptAppDefaultResult(from executed: ResizeContext, expectedAction: WindowAction) {
        guard action.direction == .useAppDefault, action == expectedAction,
              window?.cgWindowID == executed.window?.cgWindowID,
              let frame = executed.lastAppliedFrame else { return }
        if screen != executed.screen { setScreen(to: executed.screen) }
        resolvedWindowProperties = executed.resolvedWindowProperties
        resolvedRecord = executed.resolvedRecord
        lastAppliedFrame = frame
    }

    func materializeAppDefaultForScreenChange(cycleChild: WindowAction? = nil) -> WindowAction? {
        guard action.direction == .useAppDefault else { return nil }
        let target = getTargetFrame().padded
        let frame = appDefaultHasNoTargetFrame ? cachedTargetFrame.raw : target
        // The cycle cursor has already committed its screen child. Retain that
        // child's ID so the following invocation advances past it, not into it.
        guard let transfer = AppWindowDefault.transferableAction(cycleChild ?? action, frame: frame, bounds: bounds) else { return nil }
        appDefaultTransferActionID = transfer.id
        padding = .zero
        paddedBounds = bounds
        return transfer
    }

    func resolveExactUndoScreen() {
        guard action.direction == .undo, let frame = resolvedRecord?.lastExactFrame else { return }
        let screens = NSScreen.screens
        guard let target = AppWindowDefault.exactUndoTarget(
            frame: frame, bounds: screens.map(\.cgSafeScreenFrame),
            fallbackIndex: screens.firstIndex(where: { $0 == screen }) ?? 0
        ) else { return }
        setScreen(to: screens[target.index], padding: .zero)
        exactUndoFrame = target.frame
    }

    func getTargetFrame() -> ComputedFrame {
        if needsRecompute {
            recomputeTargetFrame()
        }

        return appDefaultHasNoTargetFrame ? .zero : cachedTargetFrame
    }

    private func recomputeTargetFrame() {
        // Clear the recompute guard *before* resolving so this method is re-entrancy safe:
        // if `WindowFrameResolver.getFrame` ever reads `getTargetFrame()` on this same
        // context while it is still being computed, the guard is already clear and the
        // re-entrant call returns the cached frame instead of recomputing and recursing
        // until the stack overflows.
        needsRecompute = false

        if action.direction == .useAppDefault, appDefaultFrame == nil {
            let savedFrame = window.flatMap { AppWindowDefaultManager.target(for: $0)?.frame }
            if let effective = effectiveAppDefaultContext(savedFrame: savedFrame) {
                appDefaultHasNoTargetFrame = false
                cachedTargetFrame = effective.getTargetFrame()
            } else {
                // Hide the preview without destroying the base used by a later
                // grow/shrink/move selection in the same Loop interaction.
                appDefaultHasNoTargetFrame = true
            }
            return
        }

        // Actions with no target frame return a zero-size sentinel from `getFrame`; caching it
        // would clobber the base frame that a later grow/shrink/move reads. Keep the real cached
        // frame. (Uses `WindowDirection.hasTargetFrame`, shared with `WindowFrameResolver`.)
        guard action.direction.hasTargetFrame else {
            return
        }

        let result = WindowFrameResolver.getFrame(resizeContext: self)

        let normalized = CGRect(
            x: (result.frame.minX - bounds.minX) / bounds.width,
            y: (result.frame.minY - bounds.minY) / bounds.height,
            width: result.frame.width / bounds.width,
            height: result.frame.height / bounds.height
        )

        let paddedFrame = padding.applyToWindow(
            frame: result.frame,
            paddedBounds: paddedBounds,
            action: action,
            resolvedWindowProperties: resolvedWindowProperties
        )

        cachedTargetFrame = ComputedFrame(
            raw: result.frame,
            normalized: normalized,
            padded: paddedFrame
        )

        log.info("Computed target frame - raw: \(cachedTargetFrame.raw), normalized: \(cachedTargetFrame.normalized) padded: \(cachedTargetFrame.padded), for action: \(action)")
    }
}

// MARK: - ComputedFrame

extension ResizeContext {
    /// Holds both the raw (non-padded) and padded target frames for a resize operation.
    struct ComputedFrame: Equatable {
        /// The frame calculated without any padding applied.
        let raw: CGRect

        /// The frame inside a 1x1 frame, used for radial menu angle calculations.
        let normalized: CGRect

        /// The frame with padding applied (outer bounds padding + inner window padding).
        /// When no padding is configured, this equals `raw`.
        var padded: CGRect

        static let zero = ComputedFrame(raw: .zero, normalized: .zero, padded: .zero)

        init(raw: CGRect, normalized: CGRect, padded: CGRect) {
            self.raw = raw
            self.normalized = normalized
            self.padded = padded
        }
    }
}
