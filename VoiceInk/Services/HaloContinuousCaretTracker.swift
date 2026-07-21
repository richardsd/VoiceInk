import AppKit
import ApplicationServices
import Foundation

enum HaloCaretTrackingPauseReason: String, CaseIterable, Hashable, Sendable {
    case textEditing
    case delivery
    case reset
    case styleChange
    case termination
}

enum HaloCaretTrackingState: Equatable, Sendable {
    case idle
    case tracking
    case frozenForFocusMismatch
    case paused(Set<HaloCaretTrackingPauseReason>)
    case stopped
}

/// One fresh Accessibility sample. The destination and anchor are kept
/// separate so the coordinator can validate focus before considering geometry.
struct HaloCaretTrackingLookupResult: Equatable, Sendable {
    let destination: HaloFocusedDestinationSnapshot
    let anchor: HaloCaretAnchor?
}

@MainActor
protocol HaloCaretTrackingResolving: AnyObject {
    func resolve(
        expectedDestination: HaloFocusedDestinationSnapshot
    ) async -> HaloCaretTrackingLookupResult
}

/// Boundary for AX selection/focus/value notifications. Implementations may
/// coalesce the platform's notifications, but the coordinator still debounces
/// them because editors often emit several notifications for one caret move.
@MainActor
protocol HaloCaretTrackingNotifying: AnyObject {
    @discardableResult
    func start(
        expectedDestination: HaloFocusedDestinationSnapshot,
        onChange: @escaping @MainActor () -> Void
    ) -> Bool

    func stop()
}

private let haloCaretTrackingAXCallback: AXObserverCallback = {
    _, _, notification, refcon in
    guard let refcon else { return }
    let notifier = Unmanaged<SystemHaloCaretTrackingNotifier>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        notifier.receive(notification: notification as String)
    }
}

/// Production AX notification source. The low-rate tracker watchdog remains
/// authoritative when an editor does not publish one or more notifications.
@MainActor
final class SystemHaloCaretTrackingNotifier: HaloCaretTrackingNotifying {
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var onChange: (@MainActor () -> Void)?

    @discardableResult
    func start(
        expectedDestination: HaloFocusedDestinationSnapshot,
        onChange: @escaping @MainActor () -> Void
    ) -> Bool {
        stop()
        guard let processID = expectedDestination.processID else { return false }

        var observer: AXObserver?
        guard AXObserverCreate(
            processID,
            haloCaretTrackingAXCallback,
            &observer
        ) == .success, let observer else {
            return false
        }

        self.observer = observer
        self.onChange = onChange
        let application = AXUIElementCreateApplication(processID)
        applicationElement = application

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var installed = addNotification(
            kAXFocusedUIElementChangedNotification as String,
            element: application,
            refcon: refcon
        )
        installed = refreshFocusedElementObservation(refcon: refcon) || installed

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return installed
    }

    func stop() {
        guard let observer else {
            onChange = nil
            applicationElement = nil
            focusedElement = nil
            return
        }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        if let applicationElement {
            AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
        }
        removeFocusedElementNotifications(observer: observer)
        self.observer = nil
        applicationElement = nil
        focusedElement = nil
        onChange = nil
    }

    fileprivate func receive(notification: String) {
        if notification == kAXFocusedUIElementChangedNotification as String {
            _ = refreshFocusedElementObservation(
                refcon: Unmanaged.passUnretained(self).toOpaque()
            )
        }
        onChange?()
    }

    private func refreshFocusedElementObservation(
        refcon: UnsafeMutableRawPointer
    ) -> Bool {
        guard let observer, let applicationElement else { return false }
        removeFocusedElementNotifications(observer: observer)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else {
            focusedElement = nil
            return false
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        focusedElement = element

        let notifications = [
            kAXSelectedTextChangedNotification as String,
            kAXValueChangedNotification as String,
        ]
        return notifications.reduce(false) { installed, notification in
            addNotification(
                notification,
                element: element,
                refcon: refcon
            ) || installed
        }
    }

    private func removeFocusedElementNotifications(observer: AXObserver) {
        guard let focusedElement else { return }
        AXObserverRemoveNotification(
            observer,
            focusedElement,
            kAXSelectedTextChangedNotification as CFString
        )
        AXObserverRemoveNotification(
            observer,
            focusedElement,
            kAXValueChangedNotification as CFString
        )
    }

    private func addNotification(
        _ notification: String,
        element: AXUIElement,
        refcon: UnsafeMutableRawPointer
    ) -> Bool {
        guard let observer else { return false }
        let result = AXObserverAddNotification(
            observer,
            element,
            notification as CFString,
            refcon
        )
        return result == .success || result == .notificationAlreadyRegistered
    }
}

@MainActor
protocol HaloCaretTrackingTimer: AnyObject {
    func cancel()
}

@MainActor
protocol HaloCaretTrackingScheduling: AnyObject {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloCaretTrackingTimer
}

@MainActor
final class SystemHaloCaretTrackingScheduler: HaloCaretTrackingScheduling {
    func schedule(
        after interval: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> any HaloCaretTrackingTimer {
        SystemHaloCaretTrackingTimer(interval: interval, action: action)
    }
}

@MainActor
private final class SystemHaloCaretTrackingTimer: HaloCaretTrackingTimer {
    private var task: Task<Void, Never>?

    init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        let nanoseconds = UInt64(max(0, interval) * 1_000_000_000)
        task = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}

/// Production lookup adapter over the existing bounded AX resolver. The
/// system-wide focused identity is sampled first and returned with the anchor;
/// the coordinator validates both values again before moving Halo.
@MainActor
final class DefaultHaloCaretTrackingResolver: HaloCaretTrackingResolving {
    typealias FocusedDestinationLookup = @Sendable () -> HaloFocusedDestinationSnapshot
    typealias ScreenProvider = @MainActor () -> [HaloScreenGeometry]

    private let anchorResolver: HaloCaretAnchorResolver
    private let focusedDestinationLookup: FocusedDestinationLookup
    private let screenProvider: ScreenProvider

    init(
        anchorResolver: HaloCaretAnchorResolver = HaloCaretAnchorResolver(),
        focusedDestinationLookup: @escaping FocusedDestinationLookup = {
            HaloCaretAnchorResolver.focusedDestinationSnapshot(timeout: 0.12)
        },
        screenProvider: @escaping ScreenProvider = {
            HaloScreenGeometry.currentScreens()
        }
    ) {
        self.anchorResolver = anchorResolver
        self.focusedDestinationLookup = focusedDestinationLookup
        self.screenProvider = screenProvider
    }

    func resolve(
        expectedDestination: HaloFocusedDestinationSnapshot
    ) async -> HaloCaretTrackingLookupResult {
        let lookup = focusedDestinationLookup
        let currentDestination = await Task.detached(priority: .userInitiated) {
            lookup()
        }.value

        guard HaloCaretTrackingDestinationMatcher.matches(
            expected: expectedDestination,
            current: currentDestination
        ) else {
            return HaloCaretTrackingLookupResult(
                destination: currentDestination,
                anchor: nil
            )
        }

        let anchor = await anchorResolver.resolve(
            destinationPID: expectedDestination.processID,
            applicationName: expectedDestination.applicationName,
            screens: screenProvider(),
            allowSystemFocusedDestination: false
        )
        return HaloCaretTrackingLookupResult(
            destination: currentDestination,
            anchor: anchor
        )
    }
}

/// Stricter than paste compatibility validation: visual movement requires a
/// known original process, the same bundle when one was captured, and the same
/// field identity whenever one was available. PID-only matching remains the
/// compatibility path for editors that expose no stable field identity.
enum HaloCaretTrackingDestinationMatcher {
    static func matches(
        expected: HaloFocusedDestinationSnapshot,
        current: HaloFocusedDestinationSnapshot
    ) -> Bool {
        guard let expectedProcessID = expected.processID,
            current.processID == expectedProcessID
        else {
            return false
        }

        if let expectedBundleIdentifier = normalizedBundleIdentifier(
            expected.bundleIdentifier
        ) {
            guard normalizedBundleIdentifier(current.bundleIdentifier)
                == expectedBundleIdentifier
            else {
                return false
            }
        }

        if let expectedStableIdentity = expected.focusedElementStableIdentity {
            return current.focusedElementStableIdentity == expectedStableIdentity
        }

        if let expectedTransientIdentity = expected.focusedElementIdentity {
            return current.focusedElementIdentity == expectedTransientIdentity
        }

        return true
    }

    static func matches(
        expected: HaloFocusedDestinationSnapshot,
        anchor: HaloCaretAnchor
    ) -> Bool {
        matches(
            expected: expected,
            current: HaloFocusedDestinationSnapshot(
                processID: anchor.destinationPID,
                applicationName: anchor.applicationName,
                bundleIdentifier: anchor.bundleIdentifier,
                focusedElementIdentity: anchor.focusedElementIdentity,
                focusedElementStableIdentity: anchor.focusedElementStableIdentity
            )
        )
    }

    private static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value.lowercased()
    }
}

/// Tracks only the visual caret position. `expectedDestination` never changes;
/// accepting a new anchor cannot retarget paste delivery to another field.
@MainActor
final class HaloContinuousCaretTracker {
    nonisolated static let defaultNotificationDebounce: TimeInterval = 0.08
    nonisolated static let defaultWatchdogInterval: TimeInterval = 1.25
    nonisolated static let defaultJitterTolerance: CGFloat = 2

    let expectedDestination: HaloFocusedDestinationSnapshot
    private(set) var lastSafeVisualAnchor: HaloCaretAnchor?
    private(set) var state: HaloCaretTrackingState = .idle
    private(set) var isLookupInFlight = false

    private let resolver: any HaloCaretTrackingResolving
    private let notifier: any HaloCaretTrackingNotifying
    private let scheduler: any HaloCaretTrackingScheduling
    private let notificationDebounce: TimeInterval
    private let watchdogInterval: TimeInterval
    private let jitterTolerance: CGFloat
    private let onAnchorChange: @MainActor (HaloCaretAnchor) -> Void
    private let onStateChange: @MainActor (HaloCaretTrackingState) -> Void

    private var pauseReasons = Set<HaloCaretTrackingPauseReason>()
    private var notificationTimer: (any HaloCaretTrackingTimer)?
    private var watchdogTimer: (any HaloCaretTrackingTimer)?
    private var lookupTask: Task<Void, Never>?
    private var lookupGeneration = 0
    private var activeLookupGeneration: Int?
    private var needsLookupAfterCurrent = false
    private var hasStarted = false
    private var isPermanentlyStopped = false

    init(
        expectedDestination: HaloFocusedDestinationSnapshot,
        initialAnchor: HaloCaretAnchor?,
        resolver: any HaloCaretTrackingResolving,
        notifier: any HaloCaretTrackingNotifying,
        scheduler: (any HaloCaretTrackingScheduling)? = nil,
        notificationDebounce: TimeInterval = defaultNotificationDebounce,
        watchdogInterval: TimeInterval = defaultWatchdogInterval,
        jitterTolerance: CGFloat = defaultJitterTolerance,
        onAnchorChange: @escaping @MainActor (HaloCaretAnchor) -> Void = { _ in },
        onStateChange: @escaping @MainActor (HaloCaretTrackingState) -> Void = { _ in }
    ) {
        self.expectedDestination = expectedDestination
        self.lastSafeVisualAnchor = initialAnchor
        self.resolver = resolver
        self.notifier = notifier
        self.scheduler = scheduler ?? SystemHaloCaretTrackingScheduler()
        self.notificationDebounce = max(0, notificationDebounce)
        self.watchdogInterval = max(0.1, watchdogInterval)
        self.jitterTolerance = max(0, jitterTolerance)
        self.onAnchorChange = onAnchorChange
        self.onStateChange = onStateChange
    }

    func start() {
        guard !hasStarted, !isPermanentlyStopped else { return }
        hasStarted = true

        guard pauseReasons.isEmpty else {
            publishState(.paused(pauseReasons))
            return
        }
        activateTracking()
    }

    func pause(for reason: HaloCaretTrackingPauseReason) {
        guard !isPermanentlyStopped else { return }
        let inserted = pauseReasons.insert(reason).inserted
        guard inserted else { return }

        suspendTracking()
        publishState(.paused(pauseReasons))
    }

    func resume(after reason: HaloCaretTrackingPauseReason) {
        guard !isPermanentlyStopped,
            pauseReasons.remove(reason) != nil
        else {
            return
        }

        guard pauseReasons.isEmpty else {
            publishState(.paused(pauseReasons))
            return
        }

        guard hasStarted else {
            publishState(.idle)
            return
        }
        activateTracking()
    }

    /// Terminal for this review/recording session. A stopped tracker cannot be
    /// restarted, preventing stale notifications from a reset or termination.
    func stop() {
        guard !isPermanentlyStopped else { return }
        isPermanentlyStopped = true
        hasStarted = false
        pauseReasons.removeAll()
        suspendTracking()
        publishState(.stopped)
    }

    private var isActivelyTracking: Bool {
        hasStarted && !isPermanentlyStopped && pauseReasons.isEmpty
    }

    private func activateTracking() {
        guard isActivelyTracking else { return }

        notifier.stop()
        notifier.start(
            expectedDestination: expectedDestination,
            onChange: { [weak self] in
                self?.receivedCaretNotification()
            }
        )
        scheduleWatchdog()
        publishState(.tracking)
        requestLookup()
    }

    private func suspendTracking() {
        lookupGeneration &+= 1
        notificationTimer?.cancel()
        notificationTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        notifier.stop()
        needsLookupAfterCurrent = false
        lookupTask?.cancel()
        lookupTask = nil
        activeLookupGeneration = nil
        isLookupInFlight = false
    }

    private func receivedCaretNotification() {
        guard isActivelyTracking else { return }
        notificationTimer?.cancel()
        notificationTimer = scheduler.schedule(after: notificationDebounce) { [weak self] in
            guard let self else { return }
            self.notificationTimer = nil
            self.requestLookup()
        }
    }

    private func scheduleWatchdog() {
        guard isActivelyTracking else { return }
        watchdogTimer?.cancel()
        watchdogTimer = scheduler.schedule(after: watchdogInterval) { [weak self] in
            guard let self else { return }
            self.watchdogTimer = nil
            self.requestLookup()
            self.scheduleWatchdog()
        }
    }

    private func requestLookup() {
        guard isActivelyTracking else { return }
        guard !isLookupInFlight else {
            needsLookupAfterCurrent = true
            return
        }

        isLookupInFlight = true
        let generation = lookupGeneration
        activeLookupGeneration = generation
        let expectedDestination = expectedDestination
        let resolver = resolver
        lookupTask = Task { [weak self] in
            let result = await resolver.resolve(
                expectedDestination: expectedDestination
            )
            let wasCancelled = Task.isCancelled
            self?.completeLookup(
                result,
                generation: generation,
                wasCancelled: wasCancelled
            )
        }
    }

    private func completeLookup(
        _ result: HaloCaretTrackingLookupResult,
        generation: Int,
        wasCancelled: Bool
    ) {
        guard activeLookupGeneration == generation else {
            return
        }
        isLookupInFlight = false
        activeLookupGeneration = nil
        lookupTask = nil

        let shouldRunPendingLookup = needsLookupAfterCurrent && isActivelyTracking
        needsLookupAfterCurrent = false

        if !wasCancelled, generation == lookupGeneration, isActivelyTracking {
            consume(result)
        }

        if shouldRunPendingLookup {
            receivedCaretNotification()
        }
    }

    private func consume(_ result: HaloCaretTrackingLookupResult) {
        guard HaloCaretTrackingDestinationMatcher.matches(
            expected: expectedDestination,
            current: result.destination
        ) else {
            publishState(.frozenForFocusMismatch)
            return
        }

        publishState(.tracking)
        guard let candidate = result.anchor else { return }
        guard HaloCaretTrackingDestinationMatcher.matches(
            expected: expectedDestination,
            anchor: candidate
        ) else {
            publishState(.frozenForFocusMismatch)
            return
        }
        guard shouldAccept(candidate) else { return }
        lastSafeVisualAnchor = candidate
        onAnchorChange(candidate)
    }

    private func shouldAccept(_ candidate: HaloCaretAnchor) -> Bool {
        guard candidate.appKitRect != nil else { return false }
        guard let current = lastSafeVisualAnchor else { return true }
        guard candidate.quality >= current.quality else { return false }

        if candidate.quality > current.quality {
            return true
        }
        return !isJitter(candidate, relativeTo: current)
    }

    private func isJitter(
        _ candidate: HaloCaretAnchor,
        relativeTo current: HaloCaretAnchor
    ) -> Bool {
        guard candidate.screenID == current.screenID,
            let candidateRect = candidate.appKitRect,
            let currentRect = current.appKitRect
        else {
            return false
        }

        return abs(candidateRect.midX - currentRect.midX) <= jitterTolerance
            && abs(candidateRect.midY - currentRect.midY) <= jitterTolerance
            && abs(candidateRect.width - currentRect.width) <= jitterTolerance
            && abs(candidateRect.height - currentRect.height) <= jitterTolerance
    }

    private func publishState(_ newState: HaloCaretTrackingState) {
        guard state != newState else { return }
        state = newState
        onStateChange(newState)
    }
}
