//
//  AppWindowDefaultManager.swift
//  Loop
//

import Defaults
import SwiftUI

/// Observes only apps with saved defaults, and only while automatic application
/// and Accessibility are enabled. No polling or focus notifications are needed.
@MainActor
final class AppWindowDefaultManager {
    static let shared = AppWindowDefaultManager()

    private struct Observation {
        let observer: AXObserver
        var tracker: AppDefaultWindowTracker
    }

    private var observations: [pid_t: Observation] = [:]
    private var tasks: [Task<(), Never>] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lifecycle = AppDefaultObserverLifecycle()
    private var retries: [pid_t: Task<(), Never>] = [:]
    private static let messagingTimeout: Float = 0.1

    /// Subscribe once; synchronize incrementally so saving a new frame does not
    /// forget windows already claimed for other apps.
    func start() {
        guard tasks.isEmpty else { return }
        tasks = [
            Task { for await _ in Defaults.updates(.applyAppDefaultsAutomatically) { synchronize() } },
            Task { for await _ in Defaults.updates(.appWindowDefaults) { synchronize() } },
            Task { for await _ in Defaults.updates(.excludedApps) { synchronize() } },
            Task { for await _ in AccessibilityManager.shared.stream() { synchronize() } }
        ]
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                let enabledAtLaunch = name == NSWorkspace.didLaunchApplicationNotification &&
                    Defaults[.applyAppDefaultsAutomatically] && AXIsProcessTrusted()
                Task { @MainActor [weak self] in
                    guard let self, !self.tasks.isEmpty else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification, let pid {
                        removeObservation(pid)
                    } else {
                        synchronize(newlyLaunchedPID: enabledAtLaunch ? pid : nil)
                    }
                }
            })
        }
    }

    func shutdown() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        for pid in Array(lifecycle.entries.keys) { removeObservation(pid) }
        lifecycle.reset()
    }

    private func removeObservation(_ pid: pid_t) {
        retries.removeValue(forKey: pid)?.cancel()
        lifecycle.remove(pid)
        guard let observation = observations.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    private func synchronize(newlyLaunchedPID: pid_t? = nil) {
        // Editing a default should do no app enumeration or Accessibility IPC
        // while automatic application is disabled (the default setting).
        guard !tasks.isEmpty, Defaults[.applyAppDefaultsAutomatically], AXIsProcessTrusted() else {
            for pid in Array(lifecycle.entries.keys) { removeObservation(pid) }
            return
        }
        let savedDefaults = Defaults[.appWindowDefaults]
        let excludedApps = Defaults[.excludedApps]
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                $0.bundleIdentifier.map { savedDefaults[$0] != nil } == true &&
                $0.bundleURL.map { !excludedApps.contains($0) } == true
        }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(lifecycle.entries.keys) where !pids.contains(pid) { removeObservation(pid) }
        lifecycle.reconcile(eligiblePIDs: pids, newlyLaunchedPID: newlyLaunchedPID)
        for app in apps where lifecycle.canAttempt(app.processIdentifier) {
            prepareObservation(app.processIdentifier)
        }
    }

    private func retry(_ pid: pid_t, after error: AXError) {
        guard let retry = lifecycle.failed(pid, error: error) else { return }
        retries[pid] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(retry.delay)) } catch { return }
            guard !Task.isCancelled, let self,
                  lifecycle.resume(pid, generation: retry.generation) else { return }
            retries.removeValue(forKey: pid)
            // Recheck preferences, trust, exclusions and running PIDs before IPC.
            synchronize()
        }
    }

    private func prepareObservation(_ pid: pid_t) {
        let element = AXUIElementCreateApplication(pid)
        let timeoutError = AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        guard timeoutError == .success else { retry(pid, after: timeoutError); return }
        var observer: AXObserver?
        let creationError = AXObserverCreate(pid, { observer, window, notification, _ in
            // AX observers are scheduled exclusively on the main run loop.
            MainActor.assumeIsolated {
                let manager = AppWindowDefaultManager.shared
                guard let pid = manager.observations.first(where: { CFEqual($0.value.observer, observer) })?.key else { return }
                if notification as String == kAXUIElementDestroyedNotification {
                    manager.observations[pid]?.tracker.forget(window)
                } else {
                    manager.windowCreated(window, pid: pid)
                }
            }
        }, &observer)
        guard creationError == .success, let observer else { retry(pid, after: creationError); return }
        let registrationError = AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, nil)
        guard registrationError == .success else { retry(pid, after: registrationError); return }
        // Seed after registering but before scheduling the callback source.
        var value: CFTypeRef?
        let enumerationError = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard enumerationError == .success, let windows = value as? [AXUIElement] else {
            AXObserverRemoveNotification(observer, element, kAXWindowCreatedNotification as CFString)
            retry(pid, after: enumerationError == .success ? .illegalArgument : enumerationError)
            return
        }
        let includesInitialWindows = lifecycle.entries[pid]?.includesInitialWindows == true
        var tracker = AppDefaultWindowTracker()
        // A process launched while observation is enabled has only new windows,
        // including windows discovered after a startup retry. Other subscriptions
        // must enumerate successfully and seed a baseline before any callbacks.
        if !includesInitialWindows { tracker.seed(windows) }
        observations[pid] = Observation(observer: observer, tracker: tracker)
        lifecycle.succeeded(pid)
        for window in windows where !includesInitialWindows {
            if AXUIElementSetMessagingTimeout(window, Self.messagingTimeout) == .success {
                AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        if includesInitialWindows {
            for window in windows { windowCreated(window, pid: pid) }
        }
    }

    private func windowCreated(_ element: AXUIElement, pid: pid_t) {
        guard observations[pid]?.tracker.claim(element) == true,
              AXUIElementSetMessagingTimeout(element, Self.messagingTimeout) == .success else { return }
        if let observer = observations[pid]?.observer {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
        }
        // Claim before any eligibility checks. A skipped window must not be reset
        // later when it becomes visible, leaves fullscreen, or is unexcluded.
        guard !tasks.isEmpty, Defaults[.applyAppDefaultsAutomatically], AXIsProcessTrusted(),
              let window = try? Window(element: element, pid: pid),
              !window.isAppExcluded, !window.isOwnWindow,
              window.subrole == .standardWindow, !window.fullscreen, !window.minimized,
              let target = Self.target(for: window, resolveProperties: false) else { return }
        let frame = window.frame
        guard frame.isFinite, frame.width > 0, frame.height > 0,
              !frame.approximatelyEqual(to: target.frame) else { return }
        let appElement = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(appElement, Self.messagingTimeout) == .success else { return }
        let enhancedUI: Bool = (try? appElement.getValue(.enhancedUserInterface)) ?? false
        let isResizable = window.isResizable
        guard Defaults[.applyAppDefaultsAutomatically], AXIsProcessTrusted(),
              !window.isAppExcluded, !window.fullscreen, !window.minimized,
              window.nsRunningApplication?.isTerminated == false,
              window.nsRunningApplication?.bundleIdentifier.map({ Defaults[.appWindowDefaults][$0] != nil }) == true else { return }
        // Synchronous AX writes avoid an async task surviving disable/revocation.
        // This path intentionally never raises a window, activates an app, warps
        // the pointer, exits fullscreen, or invokes the system window manager.
        // Use this bounded application element rather than Window's helpers,
        // which create fresh (unbounded) elements for enhanced UI reads/writes.
        if enhancedUI { try? appElement.setValue(.enhancedUserInterface, value: false) }
        if isResizable { window.setSize(target.frame.size) }
        window.setPosition(target.frame.origin)
        if isResizable { window.setSize(target.frame.size) }
        if enhancedUI { try? appElement.setValue(.enhancedUserInterface, value: true) }
        if Defaults[.applyAppDefaultsAutomatically], AXIsProcessTrusted(), !window.isAppExcluded,
           let corrected = AppWindowDefault.reachableFrame(window.frame, in: target.screen.cgSafeScreenFrame, fitSize: false) {
            window.setPosition(corrected.origin)
        }
    }

    /// Upgrade local development preferences without losing existing shortcuts
    /// or frames. New bindings never consult the former global fallback setting.
    nonisolated static func migratePreferences() {
        let legacyFallback = Defaults[.legacyAppDefaultFallback]
        let keybinds = Defaults[.keybinds].map { $0.migratingAppDefaults(legacyFallback: legacyFallback) }
        if keybinds != Defaults[.keybinds] { Defaults[.keybinds] = keybinds }
        let radialActions = Defaults[.radialMenuActions].map { item in
            var item = item
            if case let .custom(action) = item.type {
                item.type = .custom(action.migratingAppDefaults(legacyFallback: legacyFallback))
            }
            return item
        }
        if radialActions != Defaults[.radialMenuActions] { Defaults[.radialMenuActions] = radialActions }
        let gestures = Defaults[.gestures].map { gesture in
            var gesture = gesture
            if case let .singleAction(.custom(action)) = gesture.action {
                gesture.action = .singleAction(.custom(action.migratingAppDefaults(legacyFallback: legacyFallback)))
            }
            return gesture
        }
        if gestures != Defaults[.gestures] { Defaults[.gestures] = gestures }
    }

    /// Resolves display-local custom coordinates against the currently available
    /// displays. Geometry is recomputed on every invocation, not cached globally.
    nonisolated static func target(for window: Window, resolveProperties: Bool = true) -> (frame: CGRect, screen: NSScreen)? {
        guard let id = window.nsRunningApplication?.bundleIdentifier,
              let saved = Defaults[.appWindowDefaults][id] else { return nil }
        let screens = NSScreen.screens
        let current = ScreenUtility.screenContaining(window)
        guard let index = AppWindowDefault.targetDisplayIndex(
            savedUUID: saved.displayUUID, availableUUIDs: screens.map(\.appDefaultDisplayUUID),
            currentIndex: screens.firstIndex(where: { $0 == current }) ?? 0
        ) else { return nil }
        let screen = screens[index]
        let context = ResizeContext(window: window, screen: screen, padding: .zero, action: saved.action)
        // Automatic observation uses only the already-bounded window element.
        // ResolvedProperties also reads enhanced UI via a fresh application element.
        if resolveProperties { context.resolvedWindowProperties = Window.ResolvedProperties(from: window) }
        guard saved.action.direction == .custom,
              let frame = AppWindowDefault.reachableFrame(
                  WindowFrameResolver.getFrame(resizeContext: context).frame, in: screen.cgSafeScreenFrame
              ) else { return nil }
        return (frame, screen)
    }
}
