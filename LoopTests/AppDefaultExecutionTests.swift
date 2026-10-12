//
//  AppDefaultExecutionTests.swift
//  LoopTests
//

import AppKit
@testable import Loop
import Testing

/// Exercise the same geometry, effective-context and history paths used by the
/// engines without constructing a live AX window or changing user preferences.
struct AppDefaultExecutionTests {
    private let left = CGRect(x: -1600, y: 24, width: 1600, height: 976)
    private let right = CGRect(x: 0, y: 24, width: 1920, height: 1056)
    private let padding = PaddingConfiguration(
        window: 20, externalBar: 0, top: 30, bottom: 30, right: 30, left: 30,
        configureScreenPadding: true
    )

    @Test func exactUndoResolvesOriginalDisplayAndAnimationBounds() throws {
        let before = CGRect(x: -1400, y: 100, width: 800, height: 600)
        let after = CGRect(x: 300, y: 150, width: 900, height: 700)
        var record = WindowRecords.Record(initialFrame: before)
        record.commitAppDefaultTransition(
            before: before, after: after, representedFrame: before,
            beforeAction: .init(.custom), afterAction: .init(.custom)
        )
        let target = try #require(AppWindowDefault.exactUndoTarget(frame: before, bounds: [right, left], fallbackIndex: 0))
        #expect(target.index == 1)
        let context = ResizeContext(bounds: [right, left][target.index], padding: .zero, action: .init(.undo))
        context.resolvedRecord = .init(record: record)
        context.exactUndoFrame = target.frame
        let resolved = context.getTargetFrame().padded
        #expect(resolved == before)
        // Animation's anchoring path must be able to leave the current display.
        #expect(WindowEngine.anchoredFrame(for: before.size, within: resolved, targetEdges: [], bounds: context.bounds) == before)
    }

    @Test func disconnectedUndoDisplayUsesReachableFallback() throws {
        let target = try #require(AppWindowDefault.exactUndoTarget(
            frame: CGRect(x: -1400, y: 100, width: 800, height: 600), bounds: [right], fallbackIndex: 0
        ))
        #expect(target.index == 0)
        #expect(target.frame == CGRect(x: 0, y: 100, width: 800, height: 600))
        #expect(AppWindowDefault.exactUndoTarget(frame: .zero, bounds: [right], fallbackIndex: 0) == nil)
    }

    @Test func screenTransferMaterializesDefaultAndPreservesCycleChild() throws {
        let action = WindowAction(.useAppDefault)
        let savedFrame = CGRect(x: -1440, y: 121.6, width: 1280, height: 780.8)
        let context = ResizeContext(bounds: left, padding: padding, action: action)
        context.appDefaultFrame = savedFrame
        let transfer = try #require(context.materializeAppDefaultForScreenChange())
        context.setAction(to: transfer, parent: nil)
        #expect(transfer.direction == .custom)
        #expect(transfer.id == action.id)
        #expect(context.getTargetFrame().padded.approximatelyEqual(to: savedFrame, tolerance: 0.01))
        let moved = context.derivedContext(action: transfer, bounds: right)
        #expect(moved.getTargetFrame().padded.approximatelyEqual(
            to: CGRect(x: 192, y: 129.6, width: 1536, height: 844.8), tolerance: 0.01
        ))
        // A transferred default remains a cycle member, so the next invocation
        // advances rather than treating its concrete custom action as external.
        let screenAction = WindowAction(.nextScreen)
        let cycle = WindowAction([action, screenAction, .init(.rightHalf)])
        let cycleContext = ResizeContext(bounds: left, padding: padding, action: action)
        cycleContext.appDefaultFrame = savedFrame
        let cycleTransfer = try #require(cycleContext.materializeAppDefaultForScreenChange(cycleChild: screenAction))
        #expect(cycleTransfer.id == screenAction.id)
        var coordinator = CycleActionCoordinator()
        let firstProposal = coordinator.proposeAction(
            for: 1, in: cycle, currentAction: .init(.noSelection), currentParentAction: nil,
            recordedAction: nil, restartAtBeginningWhenInterrupted: false, mode: .advance(.forward)
        )
        let first = try #require(firstProposal)
        _ = coordinator.commit(first, for: 1, in: cycle)
        let screenProposal = coordinator.proposeAction(
            for: 1, in: cycle, currentAction: action, currentParentAction: cycle,
            recordedAction: nil, restartAtBeginningWhenInterrupted: false, mode: .advance(.forward)
        )
        let screen = try #require(screenProposal)
        _ = coordinator.commit(screen, for: 1, in: cycle)
        let nextProposal = coordinator.proposeAction(
            for: 1, in: cycle, currentAction: cycleTransfer, currentParentAction: cycle,
            recordedAction: nil, restartAtBeginningWhenInterrupted: true, mode: .advance(.forward)
        )
        let next = try #require(nextProposal)
        #expect(next.action.direction == .rightHalf)
    }

    @Test func fallbackPreviewMatchesEffectiveExecutionPadding() throws {
        for fallback in [WindowAction(.leftHalf), WindowAction(
            .custom, keybind: [], unit: .percentage, width: 60, height: 70,
            xPoint: 10, yPoint: 15, positionMode: .coordinates, sizeMode: .custom
        )] {
            var action = WindowAction(.useAppDefault)
            action.appDefaultFallback = fallback
            let preview = ResizeContext(bounds: right, padding: padding, action: action)
            let execution = try #require(preview.effectiveAppDefaultContext(savedFrame: nil))
            let direct = ResizeContext(bounds: right, padding: padding, action: fallback)
            #expect(preview.getTargetFrame() == execution.getTargetFrame())
            #expect(preview.getTargetFrame() == direct.getTargetFrame())
            #expect(preview.getTargetFrame().raw != preview.getTargetFrame().padded)
        }
    }

    @Test func savedDefaultBypassesPaddingAndNoActionFallbackHasNoPreview() throws {
        let action = WindowAction(.useAppDefault)
        let context = ResizeContext(bounds: right, padding: padding, action: action)
        #expect(context.getTargetFrame() == .zero)
        #expect(WindowFrameResolver.getFrame(resizeContext: context).frame == .zero)
        #expect(context.effectiveAppDefaultContext(savedFrame: nil) == nil)
        let saved = CGRect(x: 100, y: 100, width: 800, height: 600)
        let execution = try #require(context.effectiveAppDefaultContext(savedFrame: saved))
        #expect(execution.getTargetFrame().padded == saved)
        let noOp = ResizeContext(initialFrame: saved, bounds: right, padding: padding, action: action)
        #expect(noOp.getTargetFrame() == .zero)
        #expect(noOp.cachedTargetFrame.raw == saved)
        let unchangedTransfer = try #require(noOp.materializeAppDefaultForScreenChange())
        #expect(unchangedTransfer.direction == .custom)
        #expect(abs((unchangedTransfer.width ?? 0) - Double(saved.width / right.width * 100)) < 0.00001)
        noOp.setAction(to: .init(.noAction), parent: nil)
        #expect(noOp.getTargetFrame().raw == saved)
    }

    @Test func completedDefaultAddsOneUndoStepAndUnchangedDefaultAddsNone() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        let before = CGRect(x: 0, y: 24, width: 960, height: 1056)
        let after = CGRect(x: 300, y: 150, width: 900, height: 700)
        var record = WindowRecords.Record(initialFrame: initial)
        record.actions.insert(.init(.leftHalf), at: 0)
        let context = ResizeContext(bounds: right, padding: .zero, action: .init(.useAppDefault))
        context.resolvedRecord = .init(record: record)
        let represented = WindowFrameResolver.currentRecordedFrame(context: context, bounds: right, padding: .zero)
        #expect(represented == before)
        record.commitAppDefaultTransition(
            before: before, after: after, representedFrame: represented,
            beforeAction: .init(.custom), afterAction: .init(.custom)
        )
        #expect(record.actions.count == 3)
        #expect(record.lastExactFrame == before)
        context.resolvedRecord = .init(record: record)
        #expect(WindowFrameResolver.currentRecordedFrame(context: context, bounds: right, padding: .zero) == after)
        record.commitAppDefaultTransition(
            before: after, after: after, representedFrame: after,
            beforeAction: .init(.custom), afterAction: .init(.custom)
        )
        #expect(record.actions.count == 3)
        record.removeCurrentAction()
        #expect(record.actions.count == 2)
        #expect(record.actions[1].direction == .initialFrame)
        #expect(record.initialFrame == initial)
        record.removeCurrentAction()
        #expect(record.actions.count == 1)
    }

    @Test func manualChangesArePreservedAsSeparateHistoryState() {
        let initial = CGRect(x: 100, y: 100, width: 600, height: 400)
        let manual = CGRect(x: -1400, y: 100, width: 800, height: 600)
        let after = CGRect(x: 300, y: 150, width: 900, height: 700)
        var record = WindowRecords.Record(initialFrame: initial)
        record.commitAppDefaultTransition(
            before: manual, after: after, representedFrame: initial,
            beforeAction: .init(.custom), afterAction: .init(.custom)
        )
        #expect(record.actions.count == 3)
        #expect(record.lastExactFrame == manual)
        record.removeCurrentAction()
        #expect(record.actions.first.flatMap { record.exactFrames[$0.id] } == manual)
        record.removeCurrentAction()
        #expect(record.actions.count == 1)
    }

    @Test func recurringBindingIDsDoNotAliasExactSnapshots() {
        let binding = WindowAction(.leftHalf)
        var record = WindowRecords.Record(initialFrame: left)
        record.actions.insert(binding, at: 0)
        record.actions.insert(binding, at: 0)
        record.commitAppDefaultTransition(
            before: right, after: left, representedFrame: right,
            beforeAction: .init(.custom), afterAction: .init(.custom)
        )
        #expect(record.lastExactFrame == right)
        #expect(record.exactFrames[binding.id] == nil)
        record.removeCurrentAction()
        record.removeCurrentAction()
        #expect(record.actions.first?.id == binding.id)
    }

    @Test func completedDefaultUpdatesLiveStateWithoutOverwritingANewerSelection() {
        let action = WindowAction(.useAppDefault)
        let originating = ResizeContext(bounds: right, padding: .zero, action: action)
        let executed = ResizeContext(bounds: right, padding: .zero, action: action)
        let constrainedFrame = CGRect(x: 100, y: 100, width: 1100, height: 800)
        executed.lastAppliedFrame = constrainedFrame
        let record = WindowRecords.Record(initialFrame: constrainedFrame)
        executed.resolvedRecord = .init(record: record)
        originating.adoptAppDefaultResult(from: executed, expectedAction: action)
        #expect(originating.lastAppliedFrame == constrainedFrame)
        #expect(originating.resolvedRecord?.initialFrame == constrainedFrame)

        originating.setAction(to: .init(.rightHalf), parent: nil)
        executed.lastAppliedFrame = left
        originating.adoptAppDefaultResult(from: executed, expectedAction: action)
        #expect(originating.lastAppliedFrame == constrainedFrame)
        #expect(originating.action.direction == .rightHalf)
    }

    @Test func cancelledCompletionCannotCorrectPositionOrCommitHistory() async {
        let prevented = await Task {
            var wrotePosition = false
            var record = WindowRecords.Record(initialFrame: right)
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try WindowEngine.correctAppDefaultFrame(left, bounds: right) { _ in wrotePosition = true }
                return false
            } catch is CancellationError {
                record.commitAppDefaultTransition(
                    before: right, after: left, representedFrame: right,
                    beforeAction: .init(.custom), afterAction: .init(.custom)
                )
                return !wrotePosition && record.actions.count == 1 && record.exactFrames.isEmpty
            } catch {
                return false
            }
        }.value
        #expect(prevented)
    }
}
