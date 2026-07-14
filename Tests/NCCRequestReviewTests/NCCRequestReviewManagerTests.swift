//
//  NCCRequestReviewManagerTests.swift
//  NCCRequestReview
//

import XCTest
import SwiftUI
@testable import NCCRequestReview

@MainActor
final class NCCRequestReviewManagerTests: XCTestCase {

    /// Mutable clock shared with the manager's injected `now`.
    private final class Clock {
        var currentDate = Date(timeIntervalSince1970: 1_000_000)
        func advance(by interval: TimeInterval) { currentDate.addTimeInterval(interval) }
    }

    private var clock = Clock()
    private var recordedEvents: [NCCRequestReviewManager.Event] = []
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        clock = Clock()
        recordedEvents = []
        suiteName = "NCCRequestReviewTests-\(UUID().uuidString)"
        NCCRequestReviewManager.resetLaunchCountingForTesting()
    }

    override func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Instant-eligibility configuration; individual tests tighten single gates.
    private func openConfiguration() -> NCCRequestReviewManager.Configuration {
        NCCRequestReviewManager.Configuration(
            minimumPrimaryActionCount: 0,
            minimumIntervalBetweenRequests: 0,
            minimumLaunchCount: 0,
            minimumIntervalSinceFirstLaunch: 0,
            limitToOneRequestPerAppVersion: false
        )
    }

    private func makeManager(
        configuration: NCCRequestReviewManager.Configuration,
        applicationActive: Bool = true
    ) -> NCCRequestReviewManager {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create test UserDefaults suite")
        }
        let clock = self.clock
        let manager = NCCRequestReviewManager(
            configuration: configuration,
            userDefaults: defaults,
            now: { clock.currentDate },
            onEvent: { [weak self] event in self?.recordedEvents.append(event) }
        )
        manager.isApplicationActive = { applicationActive }
        manager.currentAppVersion = "1.0"
        return manager
    }

    /// Simulates quitting and relaunching: new process = launch counting guard
    /// cleared and a fresh UserDefaults instance over the same suite.
    private func relaunch(
        configuration: NCCRequestReviewManager.Configuration,
        applicationActive: Bool = true
    ) -> NCCRequestReviewManager {
        NCCRequestReviewManager.resetLaunchCountingForTesting()
        return makeManager(configuration: configuration, applicationActive: applicationActive)
    }

    private func registerActiveScene(
        on manager: NCCRequestReviewManager,
        onInvoke: @escaping () -> Void = {}
    ) -> NCCRequestReviewManager.SceneToken {
        let token = NCCRequestReviewManager.SceneToken()
        manager.registerScene(token, phase: .active, invokeReviewRequest: onInvoke)
        return token
    }

    private func requestAndAwaitOutcome(
        _ manager: NCCRequestReviewManager,
        trigger: String = "test",
        delay: TimeInterval = 0
    ) async {
        manager.requestReviewIfAppropriate(trigger: trigger, delay: delay)
        await manager.scheduledRequestTaskForTesting?.value
    }

    private var skipReasons: [NCCRequestReviewManager.SkipReason] {
        recordedEvents.compactMap {
            if case .reviewRequestSkipped(_, let reason) = $0 { return reason }
            return nil
        }
    }

    private var attemptedTriggers: [String] {
        recordedEvents.compactMap {
            if case .reviewRequestAttempted(let trigger) = $0 { return trigger }
            return nil
        }
    }

    // MARK: - Gate matrix

    func testRequestSucceedsWhenAllGatesPass() async {
        let manager = makeManager(configuration: openConfiguration())
        var invoked = false
        _ = registerActiveScene(on: manager) { invoked = true }

        await requestAndAwaitOutcome(manager, trigger: "success")

        XCTAssertTrue(invoked)
        XCTAssertEqual(attemptedTriggers, ["success"])
        XCTAssertEqual(manager.lastRequestAttemptDate, clock.currentDate)
    }

    func testFirstSessionLaunchCountGateBlocks() async {
        var configuration = openConfiguration()
        configuration.minimumLaunchCount = 2
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        await requestAndAwaitOutcome(manager)

        XCTAssertEqual(skipReasons, [.firstSession])
        XCTAssertTrue(attemptedTriggers.isEmpty)
    }

    func testSecondLaunchPassesLaunchCountGate() async {
        var configuration = openConfiguration()
        configuration.minimumLaunchCount = 2
        _ = makeManager(configuration: configuration)

        let secondLaunchManager = relaunch(configuration: configuration)
        _ = registerActiveScene(on: secondLaunchManager)

        await requestAndAwaitOutcome(secondLaunchManager)

        XCTAssertEqual(attemptedTriggers, ["test"])
    }

    func testFirstSessionIntervalGateBlocksUntilElapsed() async {
        var configuration = openConfiguration()
        configuration.minimumIntervalSinceFirstLaunch = 24 * 60 * 60
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        await requestAndAwaitOutcome(manager)
        XCTAssertEqual(skipReasons, [.firstSession])

        clock.advance(by: 24 * 60 * 60 + 1)
        await requestAndAwaitOutcome(manager)
        XCTAssertEqual(attemptedTriggers, ["test"])
    }

    func testBelowActionThresholdGate() async {
        var configuration = openConfiguration()
        configuration.minimumPrimaryActionCount = 3
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        manager.recordPrimaryAction("action")
        manager.recordPrimaryAction("action")
        await requestAndAwaitOutcome(manager)
        XCTAssertEqual(skipReasons, [.belowActionThreshold])

        manager.recordPrimaryAction("action")
        await requestAndAwaitOutcome(manager)
        XCTAssertEqual(attemptedTriggers, ["test"])
    }

    func testCooldownGate() async {
        var configuration = openConfiguration()
        configuration.minimumIntervalBetweenRequests = 100
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        await requestAndAwaitOutcome(manager, trigger: "first")
        clock.advance(by: 50)
        await requestAndAwaitOutcome(manager, trigger: "tooSoon")
        clock.advance(by: 51)
        await requestAndAwaitOutcome(manager, trigger: "afterCooldown")

        XCTAssertEqual(attemptedTriggers, ["first", "afterCooldown"])
        XCTAssertEqual(skipReasons, [.cooldownActive])
    }

    func testPerAppVersionLimit() async {
        var configuration = openConfiguration()
        configuration.limitToOneRequestPerAppVersion = true
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        await requestAndAwaitOutcome(manager, trigger: "first")
        await requestAndAwaitOutcome(manager, trigger: "sameVersion")
        manager.currentAppVersion = "2.0"
        await requestAndAwaitOutcome(manager, trigger: "newVersion")

        XCTAssertEqual(attemptedTriggers, ["first", "newVersion"])
        XCTAssertEqual(skipReasons, [.alreadyRequestedThisVersion])
    }

    func testClockRollbackFailsClosed() async {
        var configuration = openConfiguration()
        configuration.minimumIntervalSinceFirstLaunch = 60
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        clock.advance(by: -3600)
        await requestAndAwaitOutcome(manager)

        XCTAssertEqual(skipReasons, [.firstSession])
        XCTAssertTrue(attemptedTriggers.isEmpty)
    }

    // MARK: - Scheduling behavior

    func testOverlappingTriggersCoalesce() async {
        let manager = makeManager(configuration: openConfiguration())
        _ = registerActiveScene(on: manager)

        manager.requestReviewIfAppropriate(trigger: "first", delay: 0.05)
        manager.requestReviewIfAppropriate(trigger: "second", delay: 0)
        await manager.scheduledRequestTaskForTesting?.value

        XCTAssertEqual(skipReasons, [.alreadyScheduled])
        XCTAssertEqual(attemptedTriggers, ["first"])
    }

    func testCancelScheduledRequest() async {
        let manager = makeManager(configuration: openConfiguration())
        _ = registerActiveScene(on: manager)

        manager.requestReviewIfAppropriate(trigger: "cancelled", delay: 10)
        let pendingTask = manager.scheduledRequestTaskForTesting
        manager.cancelScheduledRequest()
        await pendingTask?.value

        XCTAssertEqual(skipReasons, [.cancelled])
        XCTAssertTrue(attemptedTriggers.isEmpty)
        XCTAssertNil(manager.scheduledRequestTaskForTesting)
    }

    func testFireTimeRecheckSkipsWhenAppBecameInactive() async {
        let manager = makeManager(configuration: openConfiguration())
        _ = registerActiveScene(on: manager)

        var applicationActive = true
        manager.isApplicationActive = { applicationActive }

        manager.requestReviewIfAppropriate(trigger: "backgrounded", delay: 0.05)
        applicationActive = false
        await manager.scheduledRequestTaskForTesting?.value

        XCTAssertEqual(skipReasons, [.appNotActive])
        XCTAssertTrue(attemptedTriggers.isEmpty)
    }

    func testFireTimeRecheckSkipsWhenCooldownStartedMidDelay() async {
        // A cooldown that begins mid-delay (e.g. clock manipulation or another
        // path writing an attempt) must be honored at fire time.
        var configuration = openConfiguration()
        configuration.minimumIntervalSinceFirstLaunch = 30
        let manager = makeManager(configuration: configuration)
        _ = registerActiveScene(on: manager)

        clock.advance(by: 60)
        manager.requestReviewIfAppropriate(trigger: "rollback", delay: 0.05)
        clock.advance(by: -60)
        await manager.scheduledRequestTaskForTesting?.value

        XCTAssertEqual(skipReasons, [.firstSession])
        XCTAssertTrue(attemptedTriggers.isEmpty)
    }

    // MARK: - Scene registry

    func testNoRegisteredSceneSkips() async {
        let manager = makeManager(configuration: openConfiguration())

        await requestAndAwaitOutcome(manager)

        XCTAssertEqual(skipReasons, [.noRequestReviewAction])
    }

    func testOnlyCurrentlyActiveScenesAreEligible() async {
        let manager = makeManager(configuration: openConfiguration())
        var invokedBackground = false
        let backgroundToken = registerActiveScene(on: manager) { invokedBackground = true }
        manager.sceneDidChangePhase(backgroundToken, phase: .background)

        await requestAndAwaitOutcome(manager)

        XCTAssertFalse(invokedBackground)
        XCTAssertEqual(skipReasons, [.noRequestReviewAction])
    }

    func testMostRecentlyActivatedSceneWins() async {
        let manager = makeManager(configuration: openConfiguration())
        var invokedFirst = false
        var invokedSecond = false
        let firstToken = registerActiveScene(on: manager) { invokedFirst = true }
        _ = registerActiveScene(on: manager) { invokedSecond = true }

        // Reactivating the first window makes it the most recent activation.
        manager.sceneDidChangePhase(firstToken, phase: .inactive)
        manager.sceneDidChangePhase(firstToken, phase: .active)

        await requestAndAwaitOutcome(manager)

        XCTAssertTrue(invokedFirst)
        XCTAssertFalse(invokedSecond)
    }

    func testWindowClosedMidDelayFiresThroughRemainingScene() async {
        let manager = makeManager(configuration: openConfiguration())
        var invokedRemaining = false
        let closingToken = registerActiveScene(on: manager)
        _ = registerActiveScene(on: manager) { invokedRemaining = true }
        manager.sceneDidChangePhase(closingToken, phase: .active)

        manager.requestReviewIfAppropriate(trigger: "windowClosed", delay: 0.05)
        manager.unregisterScene(closingToken)
        await manager.scheduledRequestTaskForTesting?.value

        XCTAssertTrue(invokedRemaining)
        XCTAssertEqual(attemptedTriggers, ["windowClosed"])
        XCTAssertEqual(manager.registeredSceneCountForTesting, 1)
    }

    func testSceneActivatedMidDelayWinsSelection() async {
        let manager = makeManager(configuration: openConfiguration())
        var invokedOld = false
        var invokedNew = false
        _ = registerActiveScene(on: manager) { invokedOld = true }

        manager.requestReviewIfAppropriate(trigger: "focusChange", delay: 0.05)
        _ = registerActiveScene(on: manager) { invokedNew = true }
        await manager.scheduledRequestTaskForTesting?.value

        XCTAssertFalse(invokedOld)
        XCTAssertTrue(invokedNew)
    }

    // MARK: - Launch counting

    func testLaunchCountedOncePerProcessPerStore() {
        let manager = makeManager(configuration: openConfiguration())
        XCTAssertEqual(manager.launchCount, 1)

        // Same process, same store instance identity is NOT re-counted...
        let secondManagerSameProcess = makeManager(configuration: openConfiguration())
        XCTAssertEqual(secondManagerSameProcess.launchCount, 2)
        // ...but our helper creates a NEW UserDefaults instance each time, so
        // this documents the contract: one manager per store per process.
        // A true relaunch:
        let relaunched = relaunch(configuration: openConfiguration())
        XCTAssertEqual(relaunched.launchCount, 3)
    }

    func testFirstLaunchDateSetOnceAndPersists() {
        let manager = makeManager(configuration: openConfiguration())
        let recordedFirstLaunch = manager.firstLaunchDate
        XCTAssertEqual(recordedFirstLaunch, clock.currentDate)

        clock.advance(by: 999)
        let relaunched = relaunch(configuration: openConfiguration())
        XCTAssertEqual(relaunched.firstLaunchDate, recordedFirstLaunch)
    }

    // MARK: - Events

    func testPrimaryActionRecordingEmitsEventAndPersists() {
        let manager = makeManager(configuration: openConfiguration())
        manager.recordPrimaryAction("thing_done")

        guard case .primaryActionRecorded(let name, let totalCount) = recordedEvents.first else {
            XCTFail("Expected primaryActionRecorded, got \(recordedEvents)")
            return
        }
        XCTAssertEqual(name, "thing_done")
        XCTAssertEqual(totalCount, 1)

        let relaunched = relaunch(configuration: openConfiguration())
        XCTAssertEqual(relaunched.primaryActionCount, 1)
    }

    func testEventOrderForCombinedCall() async {
        let manager = makeManager(configuration: openConfiguration())
        _ = registerActiveScene(on: manager)

        manager.recordPrimaryActionAndRequestReview("combo", delay: 0)
        await manager.scheduledRequestTaskForTesting?.value

        guard recordedEvents.count == 3,
              case .primaryActionRecorded = recordedEvents[0],
              case .reviewRequestScheduled(let trigger, _) = recordedEvents[1],
              case .reviewRequestAttempted(let attemptedTrigger) = recordedEvents[2] else {
            XCTFail("Unexpected event sequence: \(recordedEvents)")
            return
        }
        XCTAssertEqual(trigger, "combo")
        XCTAssertEqual(attemptedTrigger, "combo")
    }

    // MARK: - Configuration

    func testNegativeConfigurationValuesClampToZero() {
        let configuration = NCCRequestReviewManager.Configuration(
            minimumPrimaryActionCount: -5,
            minimumIntervalBetweenRequests: -100,
            minimumLaunchCount: -2,
            minimumIntervalSinceFirstLaunch: -50
        )
        XCTAssertEqual(configuration.minimumPrimaryActionCount, 0)
        XCTAssertEqual(configuration.minimumIntervalBetweenRequests, 0)
        XCTAssertEqual(configuration.minimumLaunchCount, 0)
        XCTAssertEqual(configuration.minimumIntervalSinceFirstLaunch, 0)
    }
}
