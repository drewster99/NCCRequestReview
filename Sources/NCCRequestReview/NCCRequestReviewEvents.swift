//
//  NCCRequestReviewEvents.swift
//  NCCRequestReview
//

import Foundation

extension NCCRequestReviewManager {
    /// Observable milestones in the review-request lifecycle, delivered to the
    /// `onEvent` handler supplied at init. Apps typically map these to their
    /// own analytics events.
    public enum Event: Sendable {
        /// The StoreKit review-request API was actually invoked.
        ///
        /// StoreKit never reports whether a prompt was DISPLAYED (system rate
        /// limits, the user's "don't ask" setting, and TestFlight suppression
        /// all silently swallow requests), so this means "attempted", not
        /// "shown". The naming is deliberate.
        case reviewRequestAttempted(trigger: String)

        /// A request passed all gates and was scheduled to fire after a delay.
        case reviewRequestScheduled(trigger: String, delaySeconds: TimeInterval)

        /// A request was not made, and why.
        case reviewRequestSkipped(trigger: String, reason: SkipReason)

        /// `recordPrimaryAction` ran; `totalCount` is the new lifetime total.
        case primaryActionRecorded(name: String, totalCount: Int)
    }

    /// Why a review request was skipped.
    public enum SkipReason: String, Sendable {
        /// The launch-count or time-since-first-launch gate failed.
        case firstSession
        /// Fewer primary actions recorded than the configured minimum.
        case belowActionThreshold
        /// The cooldown since the last request attempt has not elapsed.
        case cooldownActive
        /// A request is already scheduled and pending; triggers coalesce.
        case alreadyScheduled
        /// The application was not active at fire time.
        case appNotActive
        /// `cancelScheduledRequest()` was called while a request was pending.
        case cancelled
        /// `limitToOneRequestPerAppVersion` is on and this version already
        /// attempted a request.
        case alreadyRequestedThisVersion
        /// No registered scene was active at fire time, so there was no
        /// `RequestReviewAction` to invoke.
        case noRequestReviewAction
    }
}
