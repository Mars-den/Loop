//
//  AppDefaultObserverLifecycle.swift
//  Loop
//

import ApplicationServices
import Foundation

/// Pure subscription bookkeeping. A failed subscription keeps its launch/baseline
/// policy across retries, but never across removal or permission/setting changes.
struct AppDefaultObserverLifecycle {
    struct Entry {
        let generation = UUID()
        let includesInitialWindows: Bool
        var failures = 0
        var waiting = false
        var finished = false
    }

    private(set) var entries: [pid_t: Entry] = [:]
    static let retryDelays: [Double] = [0.25, 0.5, 1, 2, 4]

    mutating func reconcile(eligiblePIDs: Set<pid_t>, newlyLaunchedPID: pid_t? = nil) {
        entries = entries.filter { eligiblePIDs.contains($0.key) }
        for pid in eligiblePIDs where entries[pid] == nil {
            entries[pid] = Entry(includesInitialWindows: pid == newlyLaunchedPID)
        }
    }

    mutating func remove(_ pid: pid_t) { entries.removeValue(forKey: pid) }
    mutating func reset() { entries.removeAll() }

    func canAttempt(_ pid: pid_t) -> Bool {
        entries[pid].map { !$0.waiting && !$0.finished } ?? false
    }

    mutating func succeeded(_ pid: pid_t) { entries[pid]?.finished = true }

    mutating func failed(_ pid: pid_t, error: AXError) -> (generation: UUID, delay: Double)? {
        guard var entry = entries[pid], !entry.finished, !entry.waiting else { return nil }
        // Unsupported notifications/attributes are permanent capabilities, not
        // startup races. Only transport/startup failures deserve another attempt.
        guard [.cannotComplete, .failure, .invalidUIElement, .invalidUIElementObserver, .noValue].contains(error),
              entry.failures < Self.retryDelays.count else {
            entry.finished = true
            entries[pid] = entry
            return nil
        }
        let delay = Self.retryDelays[entry.failures]
        entry.failures += 1
        entry.waiting = true
        entries[pid] = entry
        return (entry.generation, delay)
    }

    /// Generation matching rejects a cancelled timer even if the PID is reused.
    mutating func resume(_ pid: pid_t, generation: UUID) -> Bool {
        guard entries[pid]?.generation == generation, entries[pid]?.waiting == true else { return false }
        entries[pid]?.waiting = false
        return true
    }
}
