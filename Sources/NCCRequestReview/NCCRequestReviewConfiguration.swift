//
//  NCCRequestReviewConfiguration.swift
//  NCCRequestReview
//

import Foundation

extension NCCRequestReviewManager {
    /// Gating rules controlling when a review request is allowed.
    ///
    /// All gates must pass, and they are evaluated both when a request is
    /// scheduled and again when it fires.
    public struct Configuration: Sendable {
        /// Request only after this many primary actions have ever been recorded.
        public var minimumPrimaryActionCount: Int

        /// Cooldown between request attempts.
        public var minimumIntervalBetweenRequests: TimeInterval

        /// First-session protection: the app must have been launched at least
        /// this many times before any request.
        public var minimumLaunchCount: Int

        /// First-session protection: at least this much time must have passed
        /// since the very first launch.
        public var minimumIntervalSinceFirstLaunch: TimeInterval

        /// If `true`, at most one request attempt per app version
        /// (`CFBundleShortVersionString`).
        public var limitToOneRequestPerAppVersion: Bool

        /// Delay between an eligible trigger and the request firing, used when
        /// the call site does not specify its own delay.
        public var defaultRequestDelay: TimeInterval

        /// Creates a configuration. Negative values are clamped to zero so a
        /// bad constant can never open a gate wider than "no restriction".
        public init(
            minimumPrimaryActionCount: Int = 3,
            minimumIntervalBetweenRequests: TimeInterval = 3 * 24 * 60 * 60,
            minimumLaunchCount: Int = 2,
            minimumIntervalSinceFirstLaunch: TimeInterval = 24 * 60 * 60,
            limitToOneRequestPerAppVersion: Bool = false,
            defaultRequestDelay: TimeInterval = 9.0
        ) {
            self.minimumPrimaryActionCount = max(0, minimumPrimaryActionCount)
            self.minimumIntervalBetweenRequests = max(0, minimumIntervalBetweenRequests)
            self.minimumLaunchCount = max(0, minimumLaunchCount)
            self.minimumIntervalSinceFirstLaunch = max(0, minimumIntervalSinceFirstLaunch)
            self.limitToOneRequestPerAppVersion = limitToOneRequestPerAppVersion
            self.defaultRequestDelay = max(0, defaultRequestDelay)
        }

        /// Production defaults: 3 primary actions, 3-day cooldown, never in
        /// the first session (2+ launches and 24h+ since first launch).
        public static let standard = Configuration()

        /// Fast iteration in DEBUG builds: 60s cooldown, no first-session
        /// gates, a single primary action qualifies, 2s request delay.
        ///
        /// NOTE: this disables the first-session gates, so it cannot be used
        /// to verify first-session behavior — use `.standard` for that.
        public static let debugQuickTesting = Configuration(
            minimumPrimaryActionCount: 1,
            minimumIntervalBetweenRequests: 60,
            minimumLaunchCount: 1,
            minimumIntervalSinceFirstLaunch: 0,
            limitToOneRequestPerAppVersion: false,
            defaultRequestDelay: 2.0
        )
    }
}
