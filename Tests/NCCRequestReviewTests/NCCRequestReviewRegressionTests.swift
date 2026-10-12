//
//  NCCRequestReviewRegressionTests.swift
//  NCCRequestReview
//

import Combine
import Foundation
import SwiftUI
import Testing
@testable import NCCRequestReview

/// Regression tests for bugs found after 3.0.1. Serialized because every test
/// drives the main actor and real-time `Task.sleep` delays.
@MainActor
@Suite(.serialized)
struct NCCRequestReviewRegressionTests {

    /// Mutable clock shared with the manager's injected `now`.
    private final class Clock {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        func advance(by interval: TimeInterval) { currentDate.addTimeInterval(interval) }
    }

    /// Collects events and lets a handler reach the manager it belongs to.
    private final class EventRecorder {
        var events: [NCCRequestReviewManager.Event] = []
        var onScheduled: (() -> Void)?

        var attemptedTriggers: [String] {
            events.compactMap {
                if case .reviewRequestAttempted(let trigger) = $0 { return trigger }
                return nil
            }
        }

        var skipReasons: [NCCRequestReviewManager.SkipReason] {
            events.compactMap {
                if case .reviewRequestSkipped(_, let reason) = $0 { return reason }
                return nil
            }
        }
    }

    private struct Fixture {
        let manager: NCCRequestReviewManager
        let clock: Clock
        let recorder: EventRecorder
        let suiteName: String

        /// Deletes the test's UserDefaults suite so runs don't leave preference files behind.
        func removeStoredDefaults() {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    private static func openConfiguration() -> NCCRequestReviewManager.Configuration {
        NCCRequestReviewManager.Configuration(
            minimumPrimaryActionCount: 0,
            minimumIntervalBetweenRequests: 0,
            minimumLaunchCount: 0,
            minimumIntervalSinceFirstLaunch: 0,
            limitToOneRequestPerAppVersion: false
        )
    }

    private static func makeFixture(
        configuration: NCCRequestReviewManager.Configuration
    ) throws -> Fixture {
        let suiteName = "NCCRequestReviewRegressionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        NCCRequestReviewManager.resetLaunchCountingForTesting()
        let clock = Clock()
        let recorder = EventRecorder()
        let manager = NCCRequestReviewManager(
            configuration: configuration,
            userDefaults: defaults,
            now: { clock.currentDate },
            onEvent: { event in
                recorder.events.append(event)
                if case .reviewRequestScheduled = event {
                    recorder.onScheduled?()
                }
            }
        )
        manager.isApplicationActive = { true }
        manager.currentAppVersion = "1.0"
        manager.registerScene(NCCRequestReviewManager.SceneToken(), phase: .active) {}
        return Fixture(manager: manager, clock: clock, recorder: recorder, suiteName: suiteName)
    }

    // MARK: - Re-entrant scheduling

    /// An `onEvent` handler that requests a review while handling
    /// `.reviewRequestScheduled` must coalesce into the pending request, not
    /// start a second, uncancellable one.
    @Test func reentrantRequestFromScheduledEventCoalesces() async throws {
        let fixture = try Self.makeFixture(configuration: Self.openConfiguration())
        defer { fixture.removeStoredDefaults() }
        let manager = fixture.manager
        var didReenter = false
        fixture.recorder.onScheduled = {
            guard !didReenter else { return }
            didReenter = true
            manager.requestReviewIfAppropriate(trigger: "reentrant", delay: 0)
        }

        manager.requestReviewIfAppropriate(trigger: "outer", delay: 0.05)
        await manager.scheduledRequestTaskForTesting?.value
        // Give any orphaned task time to fire so a duplicate is observable.
        try await Task.sleep(for: .milliseconds(200))

        #expect(fixture.recorder.attemptedTriggers == ["outer"])
        #expect(fixture.recorder.skipReasons == [.alreadyScheduled])
    }

    // MARK: - Future-dated stored timestamps

    // MARK: - Observation

    /// Every public persisted property is observable: an attempt changes
    /// `lastRequestAttemptDate`, so SwiftUI must be told.
    @Test func attemptPublishesObjectWillChange() async throws {
        let fixture = try Self.makeFixture(configuration: Self.openConfiguration())
        defer { fixture.removeStoredDefaults() }
        var changeNotificationCount = 0
        let subscription = fixture.manager.objectWillChange.sink { _ in
            changeNotificationCount += 1
        }
        defer { subscription.cancel() }

        fixture.manager.requestReviewIfAppropriate(trigger: "observed", delay: 0)
        await fixture.manager.scheduledRequestTaskForTesting?.value

        #expect(fixture.recorder.attemptedTriggers == ["observed"])
        #expect(changeNotificationCount > 0)
    }
}
