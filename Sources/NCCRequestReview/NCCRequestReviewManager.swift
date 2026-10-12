//
//  NCCRequestReviewManager.swift
//  NCCRequestReview
//
//  Gated App Store review requests: never during the first session, only
//  after the user has completed enough primary actions, with a cooldown
//  between attempts. Compliant with App Review's "no rating prompts during
//  onboarding or first launch" enforcement.
//

import Foundation
import SwiftUI
import OSLog
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Decides when it is appropriate to request an App Store review and invokes
/// the request through the currently active window's scene.
///
/// Create ONE manager per app (typically at `App` level), attach
/// `.nccRequestReviewHandler(manager)` to the content view of every
/// `WindowGroup`/`Window` scene, call `recordPrimaryAction(_:)` (or the
/// combined `recordPrimaryActionAndRequestReview(_:delay:)`) when the user
/// completes a meaningful action, and observe lifecycle via `onEvent`.
///
/// Gate state is persisted in `UserDefaults`. Every public persisted property
/// publishes `objectWillChange` before it changes, so SwiftUI views reading
/// them stay current.
@MainActor
public final class NCCRequestReviewManager: ObservableObject {
    private static let logger = Logger(subsystem: "com.nuclearcyborg.NCCRequestReview", category: "NCCRequestReviewManager")

    /// Receives lifecycle events; always called on the main actor.
    ///
    /// Events are delivered after the manager's state is updated, so the
    /// handler may safely call back into the manager.
    public typealias EventHandler = (Event) -> Void

    /// Upper bound for a scheduled request's delay, in seconds. Anything
    /// longer is almost certainly a units mistake at the call site.
    private static let maximumRequestDelay: TimeInterval = 60 * 60

    private enum StorageKey {
        static let launchCount = "NCCRequestReview.launchCount"
        static let firstLaunchDate = "NCCRequestReview.firstLaunchDate"
        static let primaryActionCount = "NCCRequestReview.primaryActionCount"
        static let lastRequestAttemptDate = "NCCRequestReview.lastRequestAttemptDate"
        static let lastRequestAppVersion = "NCCRequestReview.lastRequestAppVersion"
    }

    // Launch counting must happen exactly once per process launch even if the
    // process creates several managers. UserDefaults has no public suite name,
    // so instance identity is the guard key; the documented contract is one
    // manager per defaults store per process.
    private static var launchCountedStores = Set<ObjectIdentifier>()

    /// Test hook: forget which stores have already counted a launch.
    internal static func resetLaunchCountingForTesting() {
        launchCountedStores.removeAll()
    }

    private let configuration: Configuration
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let onEvent: EventHandler

    /// Injectable for tests; defaults to the platform's application-active check.
    internal var isApplicationActive: () -> Bool
    /// Injectable for tests; defaults to `CFBundleShortVersionString`.
    internal var currentAppVersion: String

    /// The single pending request, if any. Task and trigger live together so
    /// they can never disagree.
    private struct ScheduledRequest {
        let task: Task<Void, Never>
        let trigger: String
    }

    private var scheduledRequest: ScheduledRequest?

    /// Creates a review-request manager.
    /// - Parameters:
    ///   - configuration: Gating rules; defaults to `.standard`.
    ///   - userDefaults: Persistence store for gate state. One manager per
    ///     store per process.
    ///   - now: Clock, injectable for tests.
    ///   - onEvent: Lifecycle observer, typically mapped to analytics.
    public init(
        configuration: Configuration = .standard,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        onEvent: @escaping EventHandler = { _ in }
    ) {
        self.configuration = configuration
        self.userDefaults = userDefaults
        self.now = now
        self.onEvent = onEvent
        if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            self.currentAppVersion = bundleVersion
        } else {
            // Kept as a fixed placeholder so persisted per-version state is
            // unchanged; logged because `limitToOneRequestPerAppVersion`
            // then treats every build as the same version.
            Self.logger.error("CFBundleShortVersionString missing from the main bundle; using \(Self.unknownAppVersion, privacy: .public) as the app version")
            self.currentAppVersion = Self.unknownAppVersion
        }
        #if os(iOS) || os(visionOS)
        self.isApplicationActive = { UIApplication.shared.applicationState == .active }
        #elseif os(macOS)
        self.isApplicationActive = { NSApp?.isActive ?? false }
        #else
        self.isApplicationActive = { true }
        #endif

        recordLaunchIfNeeded()
    }

    /// App version recorded when the main bundle has no
    /// `CFBundleShortVersionString`.
    private static let unknownAppVersion = "unknown"

    // MARK: - Persistent gate state

    /// Number of process launches seen by this package (counted once per process).
    public private(set) var launchCount: Int {
        get { userDefaults.integer(forKey: StorageKey.launchCount) }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: StorageKey.launchCount)
        }
    }

    /// When this package first ever ran inside this app.
    public private(set) var firstLaunchDate: Date? {
        get { userDefaults.object(forKey: StorageKey.firstLaunchDate) as? Date }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: StorageKey.firstLaunchDate)
        }
    }

    /// Lifetime number of primary actions recorded.
    public private(set) var primaryActionCount: Int {
        get { userDefaults.integer(forKey: StorageKey.primaryActionCount) }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: StorageKey.primaryActionCount)
        }
    }

    /// When the StoreKit request API was last invoked (attempted, not
    /// necessarily displayed — StoreKit does not report display).
    public private(set) var lastRequestAttemptDate: Date? {
        get { userDefaults.object(forKey: StorageKey.lastRequestAttemptDate) as? Date }
        set {
            objectWillChange.send()
            userDefaults.set(newValue, forKey: StorageKey.lastRequestAttemptDate)
        }
    }

    private var lastRequestAppVersion: String? {
        get { userDefaults.string(forKey: StorageKey.lastRequestAppVersion) }
        set { userDefaults.set(newValue, forKey: StorageKey.lastRequestAppVersion) }
    }

    private func recordLaunchIfNeeded() {
        let storeIdentity = ObjectIdentifier(userDefaults)
        guard !Self.launchCountedStores.contains(storeIdentity) else { return }
        Self.launchCountedStores.insert(storeIdentity)

        launchCount += 1
        if firstLaunchDate == nil {
            firstLaunchDate = now()
        }
        Self.logger.info("Launch recorded: launchCount=\(self.launchCount)")
    }

    // MARK: - Primary actions

    /// Records that the user completed a primary action (e.g. finished a
    /// recording, completed a game round). Counted for the lifetime of the app.
    public func recordPrimaryAction(_ name: String) {
        primaryActionCount += 1
        Self.logger.info("Primary action '\(name, privacy: .public)' recorded, total=\(self.primaryActionCount)")
        onEvent(.primaryActionRecorded(name: name, totalCount: primaryActionCount))
    }

    /// Convenience for the common "action completed → maybe request" call site:
    /// `recordPrimaryAction(name)` followed by
    /// `requestReviewIfAppropriate(trigger: name, delay: delay)`.
    /// - Parameters:
    ///   - name: The primary action's name; also used as the request trigger.
    ///   - delay: Seconds to wait before the request fires, clamped to
    ///     0...3600; non-finite values are treated as zero.
    public func recordPrimaryActionAndRequestReview(_ name: String, delay: TimeInterval) {
        recordPrimaryAction(name)
        requestReviewIfAppropriate(trigger: name, delay: delay)
    }

    // MARK: - Requesting

    /// Requests a review after `delay` seconds if every gate passes.
    ///
    /// Gates are checked now AND re-checked when the delay elapses, so a
    /// request that becomes inappropriate mid-delay (another trigger's request
    /// fired, the app went inactive) is skipped. While one request is pending,
    /// further triggers coalesce into it.
    ///
    /// - Parameters:
    ///   - trigger: Names what prompted the request; reported in every event.
    ///   - delay: Seconds to wait before the request fires, clamped to
    ///     0...3600; non-finite values are treated as zero.
    public func requestReviewIfAppropriate(trigger: String, delay: TimeInterval) {
        guard scheduledRequest == nil else {
            skip(trigger: trigger, reason: .alreadyScheduled)
            return
        }
        if let reason = gateFailure() {
            skip(trigger: trigger, reason: reason)
            return
        }

        // Non-finite or absurd delays are programmer error; clamp rather than
        // trap when converting to a sleep duration.
        let delaySeconds = delay.isFinite ? min(max(0, delay), Self.maximumRequestDelay) : 0

        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                // Sleep only throws on cancellation, which
                // `cancelScheduledRequest()` already reported.
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.fireScheduledRequest(trigger: trigger)
        }
        // Record the pending request BEFORE emitting the event so a handler
        // that calls back into the manager coalesces into this request.
        scheduledRequest = ScheduledRequest(task: task, trigger: trigger)
        Self.logger.info("Review request scheduled: trigger=\(trigger, privacy: .public) delay=\(delaySeconds)s")
        onEvent(.reviewRequestScheduled(trigger: trigger, delaySeconds: delaySeconds))
    }

    /// Cancels a pending scheduled request, if any.
    public func cancelScheduledRequest() {
        guard let pendingRequest = scheduledRequest else { return }
        pendingRequest.task.cancel()
        scheduledRequest = nil
        skip(trigger: pendingRequest.trigger, reason: .cancelled)
    }

    private func fireScheduledRequest(trigger: String) {
        scheduledRequest = nil

        if let reason = gateFailure() {
            skip(trigger: trigger, reason: reason)
            return
        }
        guard isApplicationActive() else {
            skip(trigger: trigger, reason: .appNotActive)
            return
        }
        guard let invokeReviewRequest = activeSceneReviewAction() else {
            skip(trigger: trigger, reason: .noRequestReviewAction)
            return
        }

        invokeReviewRequest()
        lastRequestAttemptDate = now()
        lastRequestAppVersion = currentAppVersion
        Self.logger.info("Review request attempted: trigger=\(trigger, privacy: .public)")
        onEvent(.reviewRequestAttempted(trigger: trigger))
    }

    /// The first gate that fails, or nil if a request is currently allowed.
    private func gateFailure() -> SkipReason? {
        if launchCount < configuration.minimumLaunchCount {
            return .firstSession
        }
        // A missing first-launch date yields a zero interval, which fails
        // whenever a minimum interval is configured.
        let intervalSinceFirstLaunch = now().timeIntervalSince(firstLaunchDate ?? now())
        if intervalSinceFirstLaunch < configuration.minimumIntervalSinceFirstLaunch {
            return .firstSession
        }
        if primaryActionCount < configuration.minimumPrimaryActionCount {
            return .belowActionThreshold
        }
        if configuration.limitToOneRequestPerAppVersion,
           lastRequestAppVersion == currentAppVersion {
            return .alreadyRequestedThisVersion
        }
        if let lastAttempt = lastRequestAttemptDate,
           now().timeIntervalSince(lastAttempt) < configuration.minimumIntervalBetweenRequests {
            return .cooldownActive
        }
        return nil
    }

    private func skip(trigger: String, reason: SkipReason) {
        Self.logger.info("Review request skipped: trigger=\(trigger, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        onEvent(.reviewRequestSkipped(trigger: trigger, reason: reason))
    }

    // MARK: - Scene registry

    /// Identifies one window's registration with the manager.
    public struct SceneToken: Hashable, Sendable {
        private let id = UUID()
        public init() {}
    }

    private struct SceneRegistration {
        var invokeReviewRequest: () -> Void
        var phase: ScenePhase
        var activationSequence: UInt64
    }

    private var sceneRegistrations: [SceneToken: SceneRegistration] = [:]
    // Monotonic counter (not a timestamp) so "most recently activated" is
    // deterministic even when several scenes activate in the same instant.
    private var nextActivationSequence: UInt64 = 1

    /// Registers a window's review-request action. Called by the handler view
    /// modifier; call directly only from custom scene plumbing.
    public func registerScene(
        _ token: SceneToken,
        phase: ScenePhase,
        invokeReviewRequest: @escaping () -> Void
    ) {
        var registration = SceneRegistration(
            invokeReviewRequest: invokeReviewRequest,
            phase: phase,
            activationSequence: 0
        )
        if phase == .active {
            registration.activationSequence = nextActivationSequence
            nextActivationSequence += 1
        }
        sceneRegistrations[token] = registration
    }

    /// Removes a window's registration. A pending scheduled request is NOT
    /// cancelled — it will fire through whichever eligible scene remains.
    public func unregisterScene(_ token: SceneToken) {
        sceneRegistrations[token] = nil
    }

    /// Updates a registered window's scene phase.
    public func sceneDidChangePhase(_ token: SceneToken, phase: ScenePhase) {
        guard var registration = sceneRegistrations[token] else { return }
        registration.phase = phase
        if phase == .active {
            registration.activationSequence = nextActivationSequence
            nextActivationSequence += 1
        }
        sceneRegistrations[token] = registration
    }

    /// The review action of the most recently activated scene whose CURRENT
    /// phase is `.active`, or nil if no scene qualifies. Best-effort frontmost
    /// targeting: `ScenePhase` is not a key-window signal (on macOS several
    /// scenes can be active at once), so the guarantee is "an active window,
    /// preferring the most recently activated".
    private func activeSceneReviewAction() -> (() -> Void)? {
        sceneRegistrations.values
            .filter { $0.phase == .active }
            .max { $0.activationSequence < $1.activationSequence }?
            .invokeReviewRequest
    }

    /// Test hook: number of currently registered scenes.
    internal var registeredSceneCountForTesting: Int { sceneRegistrations.count }

    /// Test hook: the pending scheduled request, awaitable by tests.
    internal var scheduledRequestTaskForTesting: Task<Void, Never>? { scheduledRequest?.task }
}
