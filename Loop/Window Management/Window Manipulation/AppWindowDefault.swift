//
//  AppWindowDefault.swift
//  Loop
//

import Defaults
import SwiftUI

/// A preferred custom frame, relative to a display's usable bounds.
/// Reusing WindowAction lets settings edit it with Loop's existing custom-frame editor.
struct AppWindowDefault: Codable, Defaults.Serializable, Equatable {
    var appName: String
    /// Optional for compatibility with preferences saved before app icons were
    /// added. The chosen bundle also supports apps outside /Applications.
    var appURL: URL?
    var displayUUID: String?
    var action: WindowAction

    /// Adding an app requires neither a running instance nor Accessibility access.
    /// Start with an editable centered frame, not a snapshot of a live window.
    init(appName: String, appURL: URL? = nil, displayUUID: String? = nil, action: WindowAction = AppWindowDefault.defaultFrame) {
        self.appName = appName
        self.appURL = appURL
        self.displayUUID = displayUUID
        self.action = action
    }

    static var defaultFrame: WindowAction {
        .init(
            .custom, keybind: [], unit: .percentage, anchor: .center,
            width: 80, height: 80, positionMode: .generic, sizeMode: .custom
        )
    }

    /// Reject invalid edited/imported frames, then keep the title bar reachable even
    /// when an app's minimum size is larger than the available display.
    static func reachableFrame(_ frame: CGRect, in bounds: CGRect, fitSize: Bool = true) -> CGRect? {
        guard frame.isFinite, bounds.isFinite,
              frame.width > 0, frame.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        var result = frame
        if fitSize {
            result.size.width = min(frame.width, bounds.width)
            result.size.height = min(frame.height, bounds.height)
        }
        result.origin.x = max(bounds.minX, min(result.minX, bounds.maxX - result.width))
        result.origin.y = max(bounds.minY, min(result.minY, bounds.maxY - result.height))
        return result
    }

    /// Manual Current display presets follow the normal action's screen selection.
    /// A disconnected named display still falls back to the window's display.
    static func targetDisplayIndex(savedUUID: String?, availableUUIDs: [String?], currentIndex: Int, actionScreenIndex: Int? = nil) -> Int? {
        guard !availableUUIDs.isEmpty else { return nil }
        if let savedUUID, let index = availableUUIDs.firstIndex(of: savedUUID) { return index }
        if savedUUID == nil, let actionScreenIndex, availableUUIDs.indices.contains(actionScreenIndex) {
            return actionScreenIndex
        }
        return availableUUIDs.indices.contains(currentIndex) ? currentIndex : 0
    }

    /// Retry only the unfinished resize, never a window edited after creation.
    static func shouldRetryAutomaticResize(observedFrame: CGRect, currentFrame: CGRect, targetSize: CGSize) -> Bool {
        currentFrame.isFinite && currentFrame.width > 0 && currentFrame.height > 0 &&
            currentFrame.approximatelyEqual(to: observedFrame, tolerance: 1) &&
            (abs(currentFrame.width - targetSize.width) > 1 || abs(currentFrame.height - targetSize.height) > 1)
    }

    /// An early clamp may shift a large window inward; restore the preset origin
    /// after resizing, accounting for the application's actual minimum size.
    static func automaticResizeCompletionFrame(targetFrame: CGRect, actualSize: CGSize, bounds: CGRect) -> CGRect? {
        reachableFrame(CGRect(origin: targetFrame.origin, size: actualSize), in: bounds, fitSize: false)
    }

    /// Only frame-producing actions are fallback choices. In particular, rejecting
    /// App Default itself prevents recursive resolution of malformed settings.
    static var fallbackDirections: [WindowDirection] {
        [.noAction] + WindowDirection.allCases.filter {
            $0.hasTargetFrame && ![.useAppDefault, .fullscreen, .stash, .unstash].contains($0)
        }
    }

    static func validatedFallback(_ action: WindowAction) -> WindowAction {
        fallbackDirections.contains(action.direction) ? action : .init(.noAction)
    }

    /// Materialize global geometry before leaving the default's saved display.
    /// Preserve identity so a cycle still recognizes its selected child.
    static func transferableAction(_ action: WindowAction, frame: CGRect, bounds: CGRect) -> WindowAction? {
        guard frame.isFinite, bounds.isFinite, bounds.width > 0, bounds.height > 0,
              frame.width > 0, frame.height > 0 else { return nil }
        var result = action
        result.direction = .custom
        result.unit = .percentage
        result.anchor = nil
        result.width = frame.width / bounds.width * 100
        result.height = frame.height / bounds.height * 100
        result.xPoint = (frame.minX - bounds.minX) / bounds.width * 100
        result.yPoint = (frame.minY - bounds.minY) / bounds.height * 100
        result.positionMode = .coordinates
        result.sizeMode = .custom
        result.fallbackDirection = nil
        return result
    }

    /// Exact Undo uses the display occupied by its global snapshot, not the
    /// window's current display. If disconnected, keep the title bar reachable.
    static func exactUndoTarget(frame: CGRect, bounds: [CGRect], fallbackIndex: Int) -> (frame: CGRect, index: Int)? {
        guard frame.isFinite, frame.width > 0, frame.height > 0, !bounds.isEmpty else { return nil }
        let areas = bounds.map { frame.intersects($0) ? frame.intersection($0).size.area : 0 }
        if let index = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[index] > 0 {
            return (frame, index)
        }
        let index = bounds.indices.contains(fallbackIndex) ? fallbackIndex : 0
        guard let reachable = reachableFrame(frame, in: bounds[index], fitSize: false) else { return nil }
        return (reachable, index)
    }
}

extension NSScreen {
    /// Unlike CGDirectDisplayID, the display UUID survives reconnection and reboot.
    var appDefaultDisplayUUID: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Tracks creation notifications once per AX element, never focus/move/resize events.
/// Baselines are seeded whenever observation starts, so enabling the feature or
/// restoring Accessibility permission cannot resize existing windows.
struct AppDefaultWindowTracker {
    private var seen: Set<AXUIElement> = []

    mutating func seed(_ windows: [AXUIElement]) {
        seen.formUnion(windows)
    }

    mutating func claim(_ window: AXUIElement) -> Bool {
        seen.insert(window).inserted
    }

    /// Release closed AX elements so long-running apps do not accumulate history.
    mutating func forget(_ window: AXUIElement) {
        seen.remove(window)
    }
}
