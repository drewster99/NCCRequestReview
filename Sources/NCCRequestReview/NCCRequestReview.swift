// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import SwiftUI
import StoreKit

class NCCRequestReview: ObservableObject {

}

public class NCCRequestReviewManager: ObservableObject {
    public static let lastReviewRequestedTimestampUserDefaultsKey = "NCCRequestReviewManager_lastReviewRequestedTimestampKey"
    public private(set) var lastReviewRequestedTimestamp: Date {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.lastReviewRequestedTimestampUserDefaultsKey) else {
                return .distantPast
            }
            do {
                let timestamp = try JSONDecoder().decode(Date.self, from: data)
                return timestamp
            } catch {
                print("NCCRequestReviewManager: Error decoding timestamp from data: \(error)")
                return .distantPast
            }
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(data, forKey: Self.lastReviewRequestedTimestampUserDefaultsKey)
            } catch {
                print("NCCRequestReviewManager: Error encoding timestamp to data: \(error)")
            }
        }
    }

    public let minimumSecondsBetweenRequests: TimeInterval
    public init(minimumSecondsBetweenRequests: TimeInterval, eventCountsAfterWhichToRequestReview: [Int] = []) {
        self.eventCountsAfterWhichToRequestReview = eventCountsAfterWhichToRequestReview
        self.minimumSecondsBetweenRequests = minimumSecondsBetweenRequests
    }
    
    /// If this array is empty, both it and `eventCount` are completely ignored.
    /// However, if this array is *not* empty, whenever `eventCount` is set to
    /// one of the values specified by `eventCountsAfterWhichToRequestReview`,
    /// the flag `requestReviewAtNextOpportunity` will be set to `true`
    @Published public var eventCountsAfterWhichToRequestReview: [Int] = []

    private let userDefaultsEventCountKey = "NCCRequestReviewManager_requestReview_eventCount"

    /// An arbitrary event counter that can be used to track the number of times an
    /// event has occurred in determining when to request a review.
    ///
    /// For example, this could be the number of app launches, the number of levels
    /// cleared in a game, or anything else.
    ///
    /// Using it is not necessary.  It's just here as a convenience.
    public var eventCount: Int {
        get {
            UserDefaults.standard.integer(forKey: userDefaultsEventCountKey)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: userDefaultsEventCountKey)
            if eventCountsAfterWhichToRequestReview.contains(newValue) {
                self.requestReviewAtNextOpportunity = true
            }
        }
    }


    private let userDefaultsRequestReviewAtNextOpportunityKey = "NCCRequestReviewManager_requestReview_requestReviewAtNextOpportunity"

    /// If set to `true`, Apple's request review function will be called the next time `requestReviewIfAppropriate()`
    /// is called, and `requestReviewAtNextOpportunity` will be set back to `false`.
    ///
    /// This value is persisted via `UserDefaults` between launches
    public var requestReviewAtNextOpportunity: Bool {
        get {
            UserDefaults.standard.bool(forKey: userDefaultsRequestReviewAtNextOpportunityKey)
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: userDefaultsRequestReviewAtNextOpportunityKey)
        }
    }

    public func requestReviewIfAppropriate() {
        guard requestReviewAtNextOpportunity else { return }
        guard Date().timeIntervalSince(lastReviewRequestedTimestamp) >= minimumSecondsBetweenRequests else {
            print("Not requesting review yet - not enough time has passed")
            return
        }
        guard let requestReview else {
            print("Could not request review because `requestReview` is nil")
            return
        }
        requestReviewAtNextOpportunity = false
        lastReviewRequestedTimestamp = Date()
        Task { @MainActor in
            requestReview()
        }
    }
    fileprivate var requestReview: RequestReviewAction?
}
struct NCCRequestReviewViewMmodifier: ViewModifier {
    @EnvironmentObject private var requestReviewManager: NCCRequestReviewManager
    @Environment(\.requestReview) private var requestReview
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                requestReviewManager.requestReview = requestReview
            }
    }
}
public extension View {
    func nccRequestReviewHandler() -> some View {
        modifier(NCCRequestReviewViewMmodifier())
    }
}
