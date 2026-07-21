import Foundation
import Testing
@testable import VoiceInk

@MainActor
private final class ManualHaloCaretTrackingTimer: HaloCaretTrackingTimer {
    let interval: TimeInterval
    private let action: @MainActor () -> Void
    private(set) var isCancelled = false
    private(set) var didFire = false

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled, !didFire else { return }
        didFire = true
        action()
    }
}

@MainActor
private final class ManualHaloCaretTrackingScheduler: HaloCaretTrackingScheduling {
    private(set) var timers: [ManualHaloCaretTrackingTimer] = []

    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloCaretTrackingTimer {
        let timer = ManualHaloCaretTrackingTimer(interval: interval, action: action)
        timers.append(timer)
        return timer
    }

    func activeTimers(after interval: TimeInterval) -> [ManualHaloCaretTrackingTimer] {
        timers.filter {
            $0.interval == interval && !$0.isCancelled && !$0.didFire
        }
    }

    func fireNext(after interval: TimeInterval) {
        activeTimers(after: interval).first?.fire()
    }
}

@MainActor
private final class FakeHaloCaretTrackingNotifier: HaloCaretTrackingNotifying {
    private var onChange: (@MainActor () -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var destinations: [HaloFocusedDestinationSnapshot] = []

    func start(
        expectedDestination: HaloFocusedDestinationSnapshot,
        onChange: @escaping @MainActor () -> Void
    ) -> Bool {
        startCount += 1
        destinations.append(expectedDestination)
        self.onChange = onChange
        return true
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    func sendChange() {
        onChange?()
    }
}

@MainActor
private final class FakeHaloCaretTrackingResolver: HaloCaretTrackingResolving {
    var results: [HaloCaretTrackingLookupResult]
    private(set) var expectedDestinations: [HaloFocusedDestinationSnapshot] = []

    init(results: [HaloCaretTrackingLookupResult]) {
        self.results = results
    }

    func resolve(
        expectedDestination: HaloFocusedDestinationSnapshot
    ) async -> HaloCaretTrackingLookupResult {
        expectedDestinations.append(expectedDestination)
        if results.count > 1 {
            return results.removeFirst()
        }
        return results[0]
    }
}

@MainActor
private final class SuspendedHaloCaretTrackingResolver: HaloCaretTrackingResolving {
    private(set) var callCount = 0
    private var continuations: [CheckedContinuation<HaloCaretTrackingLookupResult, Never>] = []

    func resolve(
        expectedDestination: HaloFocusedDestinationSnapshot
    ) async -> HaloCaretTrackingLookupResult {
        callCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(with result: HaloCaretTrackingLookupResult) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: result)
    }
}

@MainActor
struct HaloContinuousCaretTrackerTests {
    private let debounce: TimeInterval = 0.08
    private let watchdog: TimeInterval = 1.25

    @Test func exactDestinationMatchingRejectsPIDReuseAndFieldChanges() {
        let expected = destination(pid: 41, bundle: "com.example.Editor", element: 7, stable: 9001)

        #expect(HaloCaretTrackingDestinationMatcher.matches(
            expected: expected,
            current: destination(pid: 41, bundle: "COM.EXAMPLE.EDITOR", element: 8, stable: 9001)
        ))
        #expect(!HaloCaretTrackingDestinationMatcher.matches(
            expected: expected,
            current: destination(pid: 42, bundle: "com.example.Editor", element: 7, stable: 9001)
        ))
        #expect(!HaloCaretTrackingDestinationMatcher.matches(
            expected: expected,
            current: destination(pid: 41, bundle: "com.example.Replacement", element: 7, stable: 9001)
        ))
        #expect(!HaloCaretTrackingDestinationMatcher.matches(
            expected: expected,
            current: destination(pid: 41, bundle: "com.example.Editor", element: 7, stable: 9002)
        ))
        #expect(!HaloCaretTrackingDestinationMatcher.matches(
            expected: destination(pid: nil, bundle: nil, element: nil, stable: nil),
            current: destination(pid: 41, bundle: "com.example.Editor", element: nil, stable: nil)
        ))
    }

    @Test func notificationsAreDebouncedAndUseImmutableDestination() async {
        let expected = destination()
        let moved = anchor(x: 40)
        let resolver = FakeHaloCaretTrackingResolver(results: [result(anchor: moved)])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        var published: [HaloCaretAnchor] = []
        let tracker = makeTracker(
            expected: expected,
            initial: anchor(x: 10),
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler,
            published: { published.append($0) }
        )

        tracker.start()
        await waitUntil { resolver.expectedDestinations.count == 1 }
        await waitUntil { tracker.isLookupInFlight == false }
        #expect(resolver.expectedDestinations == [expected])
        #expect(published.map { $0.appKitRect?.minX } == [40])

        notifier.sendChange()
        notifier.sendChange()
        notifier.sendChange()
        #expect(scheduler.activeTimers(after: debounce).count == 1)

        scheduler.fireNext(after: debounce)
        await waitUntil { resolver.expectedDestinations.count == 2 }
        #expect(resolver.expectedDestinations.allSatisfy { $0 == expected })
    }

    @Test func watchdogRefreshesWhenNotificationsAreUnavailable() async {
        let resolver = FakeHaloCaretTrackingResolver(results: [result(anchor: anchor(x: 30))])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        let tracker = makeTracker(
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler
        )

        tracker.start()
        await waitUntil { resolver.expectedDestinations.count == 1 }
        await waitUntil { tracker.isLookupInFlight == false }

        scheduler.fireNext(after: watchdog)
        await waitUntil { resolver.expectedDestinations.count == 2 }
        #expect(scheduler.activeTimers(after: watchdog).count == 1)
    }

    @Test func permitsAtMostOneLookupAndCoalescesPendingRefresh() async {
        let resolver = SuspendedHaloCaretTrackingResolver()
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        let tracker = makeTracker(
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler
        )

        tracker.start()
        await waitUntil { resolver.callCount == 1 }
        #expect(tracker.isLookupInFlight)

        notifier.sendChange()
        scheduler.fireNext(after: debounce)
        scheduler.fireNext(after: watchdog)
        #expect(resolver.callCount == 1)

        resolver.resumeNext(with: result(anchor: anchor(x: 30)))
        await waitUntil { tracker.isLookupInFlight == false }
        #expect(scheduler.activeTimers(after: debounce).count == 1)
        scheduler.fireNext(after: debounce)
        await waitUntil { resolver.callCount == 2 }
        #expect(tracker.isLookupInFlight)

        resolver.resumeNext(with: result(anchor: anchor(x: 60)))
        await waitUntil { tracker.isLookupInFlight == false }
    }

    @Test func focusMismatchFreezesAndValidOriginalFieldRecovers() async {
        let initial = anchor(x: 10)
        let validMove = anchor(x: 80)
        let resolver = FakeHaloCaretTrackingResolver(results: [
            HaloCaretTrackingLookupResult(
                destination: destination(pid: 99),
                anchor: anchor(x: 50, pid: 99)
            ),
            result(anchor: validMove),
        ])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        var states: [HaloCaretTrackingState] = []
        var published: [HaloCaretAnchor] = []
        let tracker = makeTracker(
            initial: initial,
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler,
            published: { published.append($0) },
            stateChanges: { states.append($0) }
        )

        tracker.start()
        await waitUntil { tracker.state == .frozenForFocusMismatch }
        #expect(tracker.lastSafeVisualAnchor == initial)
        #expect(published.isEmpty)

        notifier.sendChange()
        scheduler.fireNext(after: debounce)
        await waitUntil { tracker.lastSafeVisualAnchor == validMove }
        #expect(tracker.state == .tracking)
        #expect(states.contains(.frozenForFocusMismatch))
        #expect(published == [validMove])
    }

    @Test func missingGeometryDoesNotMisreportAValidatedFieldAsFocusMismatch() async {
        let initial = anchor(x: 10)
        let resolver = FakeHaloCaretTrackingResolver(results: [result(anchor: nil)])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        let tracker = makeTracker(
            initial: initial,
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler
        )

        tracker.start()
        await waitUntil { resolver.expectedDestinations.count == 1 }
        await waitUntil { tracker.isLookupInFlight == false }

        #expect(tracker.state == .tracking)
        #expect(tracker.lastSafeVisualAnchor == initial)
    }

    @Test func ignoresJitterAndQualityDowngradesButAcceptsMeaningfulOrBetterAnchors() async {
        let initial = anchor(x: 10, source: .nearestGlyph)
        let jitter = anchor(x: 11.5, source: .nearestGlyph)
        let lowerQuality = anchor(x: 50, source: .focusedTextElement)
        let meaningful = anchor(x: 35, source: .nearestGlyph)
        let higherQuality = anchor(x: 35.5, source: .collapsedSelection)
        let resolver = FakeHaloCaretTrackingResolver(results: [
            result(anchor: jitter),
            result(anchor: lowerQuality),
            result(anchor: meaningful),
            result(anchor: higherQuality),
        ])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        var published: [HaloCaretAnchor] = []
        let tracker = makeTracker(
            initial: initial,
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler,
            published: { published.append($0) }
        )

        tracker.start()
        await waitUntil { resolver.expectedDestinations.count == 1 }
        await waitUntil { tracker.isLookupInFlight == false }
        #expect(published.isEmpty)

        for expectedCount in 2...4 {
            notifier.sendChange()
            scheduler.fireNext(after: debounce)
            await waitUntil { resolver.expectedDestinations.count == expectedCount }
            await waitUntil { tracker.isLookupInFlight == false }
        }

        #expect(published == [meaningful, higherQuality])
        #expect(tracker.lastSafeVisualAnchor == higherQuality)
    }

    @Test func allPauseReasonsFreezeTrackingUntilEveryReasonResumes() async {
        let resolver = FakeHaloCaretTrackingResolver(results: [result(anchor: anchor(x: 40))])
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        let tracker = makeTracker(
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler
        )

        tracker.start()
        await waitUntil { resolver.expectedDestinations.count == 1 }
        await waitUntil { tracker.isLookupInFlight == false }

        for reason in HaloCaretTrackingPauseReason.allCases {
            tracker.pause(for: reason)
        }
        #expect(tracker.state == .paused(Set(HaloCaretTrackingPauseReason.allCases)))

        notifier.sendChange()
        scheduler.fireNext(after: watchdog)
        await Task.yield()
        #expect(resolver.expectedDestinations.count == 1)

        for reason in HaloCaretTrackingPauseReason.allCases.dropLast() {
            tracker.resume(after: reason)
        }
        #expect(notifier.startCount == 1)

        tracker.resume(after: .termination)
        await waitUntil { resolver.expectedDestinations.count == 2 }
        #expect(notifier.startCount == 2)
        #expect(tracker.state == .tracking)
    }

    @Test func stopIsTerminalAndRejectsAStaleInFlightResult() async {
        let initial = anchor(x: 10)
        let resolver = SuspendedHaloCaretTrackingResolver()
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        var published: [HaloCaretAnchor] = []
        let tracker = makeTracker(
            initial: initial,
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler,
            published: { published.append($0) }
        )

        tracker.start()
        await waitUntil { resolver.callCount == 1 }
        tracker.stop()
        resolver.resumeNext(with: result(anchor: anchor(x: 100)))
        await waitUntil { tracker.isLookupInFlight == false }

        tracker.start()
        notifier.sendChange()
        scheduler.fireNext(after: watchdog)
        await Task.yield()

        #expect(tracker.state == .stopped)
        #expect(tracker.lastSafeVisualAnchor == initial)
        #expect(published.isEmpty)
        #expect(resolver.callCount == 1)
    }

    @Test func pauseAndResumeCanStartFreshLookupBeforeCancelledResolverReturns() async {
        let resolver = SuspendedHaloCaretTrackingResolver()
        let notifier = FakeHaloCaretTrackingNotifier()
        let scheduler = ManualHaloCaretTrackingScheduler()
        let tracker = makeTracker(
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler
        )

        tracker.start()
        await waitUntil { resolver.callCount == 1 }
        #expect(tracker.isLookupInFlight)

        tracker.pause(for: .textEditing)
        #expect(!tracker.isLookupInFlight)
        tracker.resume(after: .textEditing)
        await waitUntil { resolver.callCount == 2 }
        #expect(tracker.isLookupInFlight)

        resolver.resumeNext(with: result(anchor: anchor(x: 99)))
        await Task.yield()
        #expect(tracker.isLookupInFlight)

        resolver.resumeNext(with: result(anchor: anchor(x: 40)))
        await waitUntil { !tracker.isLookupInFlight }
        #expect(tracker.lastSafeVisualAnchor?.appKitRect?.minX == 40)
    }

    private func makeTracker(
        expected: HaloFocusedDestinationSnapshot? = nil,
        initial: HaloCaretAnchor? = nil,
        resolver: any HaloCaretTrackingResolving,
        notifier: any HaloCaretTrackingNotifying,
        scheduler: any HaloCaretTrackingScheduling,
        published: @escaping @MainActor (HaloCaretAnchor) -> Void = { _ in },
        stateChanges: @escaping @MainActor (HaloCaretTrackingState) -> Void = { _ in }
    ) -> HaloContinuousCaretTracker {
        HaloContinuousCaretTracker(
            expectedDestination: expected ?? destination(),
            initialAnchor: initial,
            resolver: resolver,
            notifier: notifier,
            scheduler: scheduler,
            notificationDebounce: debounce,
            watchdogInterval: watchdog,
            jitterTolerance: 2,
            onAnchorChange: published,
            onStateChange: stateChanges
        )
    }

    private func result(anchor: HaloCaretAnchor?) -> HaloCaretTrackingLookupResult {
        HaloCaretTrackingLookupResult(
            destination: destination(),
            anchor: anchor
        )
    }

    private func destination(
        pid: pid_t? = 41,
        bundle: String? = "com.example.Editor",
        element: UInt? = 7,
        stable: UInt64? = 9_001
    ) -> HaloFocusedDestinationSnapshot {
        HaloFocusedDestinationSnapshot(
            processID: pid,
            applicationName: "Editor",
            bundleIdentifier: bundle,
            focusedElementIdentity: element,
            focusedElementStableIdentity: stable
        )
    }

    private func anchor(
        x: CGFloat,
        pid: pid_t? = 41,
        source: HaloCaretAnchorSource = .collapsedSelection,
        screenID: String = "main"
    ) -> HaloCaretAnchor {
        let rect = CGRect(x: x, y: 100, width: 0, height: 18)
        return HaloCaretAnchor(
            destinationPID: pid,
            applicationName: "Editor",
            bundleIdentifier: "com.example.Editor",
            focusedElementIdentity: 7,
            focusedElementStableIdentity: 9_001,
            source: source,
            accessibilityRect: rect,
            appKitRect: rect,
            screenID: screenID
        )
    }

    private func waitUntil(
        attempts: Int = 100,
        condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<attempts {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}
