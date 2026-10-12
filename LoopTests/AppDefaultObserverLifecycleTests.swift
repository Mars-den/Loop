//
//  AppDefaultObserverLifecycleTests.swift
//  LoopTests
//

import ApplicationServices
@testable import Loop
import Testing

struct AppDefaultObserverLifecycleTests {
    @Test func transientStartupFailuresHaveBoundedBackoff() throws {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100])
        for delay in AppDefaultObserverLifecycle.retryDelays {
            #expect(lifecycle.canAttempt(100))
            let scheduled = lifecycle.failed(100, error: .cannotComplete)
            let retry = try #require(scheduled)
            #expect(retry.delay == delay)
            #expect(!lifecycle.canAttempt(100))
            let duplicate = lifecycle.failed(100, error: .cannotComplete)
            #expect(duplicate == nil)
            let resumed = lifecycle.resume(100, generation: retry.generation)
            #expect(resumed)
        }
        let exhausted = lifecycle.failed(100, error: .cannotComplete)
        #expect(exhausted == nil)
        lifecycle.reconcile(eligiblePIDs: [100])
        #expect(!lifecycle.canAttempt(100)) // Preference edits cannot restart a retry storm.
    }

    @Test(arguments: [AXError.notificationUnsupported, .attributeUnsupported, .notImplemented, .illegalArgument, .apiDisabled])
    func unsupportedOrNonTransientFailuresDoNotRetry(error: AXError) {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100])
        let retry = lifecycle.failed(100, error: error)
        #expect(retry == nil)
        #expect(!lifecycle.canAttempt(100))
    }

    @Test(arguments: [AXError.failure, .cannotComplete, .invalidUIElement, .invalidUIElementObserver, .noValue])
    func transientObserverRegistrationAndEnumerationFailuresRetry(error: AXError) {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100])
        let retry = lifecycle.failed(100, error: error)
        #expect(retry != nil)
    }

    @Test func retryForRunningAppPreservesBaseline() throws {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100])
        let scheduled = lifecycle.failed(100, error: .cannotComplete)
        let retry = try #require(scheduled)
        lifecycle.reconcile(eligiblePIDs: [100], newlyLaunchedPID: 100)
        let resumed = lifecycle.resume(100, generation: retry.generation)
        #expect(resumed)
        #expect(lifecycle.entries[100]?.includesInitialWindows == false)
        let existingWindow = AXUIElementCreateApplication(100)
        var tracker = AppDefaultWindowTracker()
        if lifecycle.entries[100]?.includesInitialWindows == false { tracker.seed([existingWindow]) }
        let claimed = tracker.claim(existingWindow)
        #expect(!claimed)
    }

    @Test func launchedAppInitialWindowsRemainEligibleAfterRetry() throws {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100], newlyLaunchedPID: 100)
        let scheduled = lifecycle.failed(100, error: .cannotComplete)
        let retry = try #require(scheduled)
        lifecycle.reconcile(eligiblePIDs: [100])
        let resumed = lifecycle.resume(100, generation: retry.generation)
        #expect(resumed)
        #expect(lifecycle.entries[100]?.includesInitialWindows == true)
        var tracker = AppDefaultWindowTracker()
        let initialWindow = AXUIElementCreateApplication(100)
        let initialClaim = tracker.claim(initialWindow)
        let duplicateClaim = tracker.claim(initialWindow)
        #expect(initialClaim)
        #expect(!duplicateClaim)
        lifecycle.succeeded(100)
        #expect(!lifecycle.canAttempt(100))
        let retryAfterSuccess = lifecycle.failed(100, error: .cannotComplete)
        #expect(retryAfterSuccess == nil)
    }

    @Test func removalTerminationAndExclusionInvalidatePendingRetry() throws {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100, 101], newlyLaunchedPID: 100)
        let scheduled = lifecycle.failed(100, error: .cannotComplete)
        let retry = try #require(scheduled)
        lifecycle.reconcile(eligiblePIDs: [101])
        let resumedAfterRemoval = lifecycle.resume(100, generation: retry.generation)
        #expect(!resumedAfterRemoval)
        lifecycle.reconcile(eligiblePIDs: [100, 101])
        let resumedAfterReinsertion = lifecycle.resume(100, generation: retry.generation)
        #expect(!resumedAfterReinsertion)
        #expect(lifecycle.entries[100]?.includesInitialWindows == false)
        lifecycle.remove(100)
        #expect(!lifecycle.canAttempt(100))
        #expect(lifecycle.canAttempt(101))
    }

    @Test func disableRevocationAndShutdownResetLaunchEligibility() throws {
        var lifecycle = AppDefaultObserverLifecycle()
        lifecycle.reconcile(eligiblePIDs: [100], newlyLaunchedPID: 100)
        let scheduled = lifecycle.failed(100, error: .cannotComplete)
        let retry = try #require(scheduled)
        lifecycle.reset()
        let resumedAfterReset = lifecycle.resume(100, generation: retry.generation)
        #expect(!resumedAfterReset)
        lifecycle.reconcile(eligiblePIDs: [100])
        #expect(lifecycle.entries[100]?.includesInitialWindows == false)
        let resumedAfterRecovery = lifecycle.resume(100, generation: retry.generation)
        #expect(!resumedAfterRecovery)
    }
}
