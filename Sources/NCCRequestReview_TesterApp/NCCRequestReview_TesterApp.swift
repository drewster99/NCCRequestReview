//
//  NCCRequestReview_TesterApp.swift
//  NCCRequestReview
//
//  Created by Andrew Benson on 2/19/25.
//


import Foundation
import SwiftUI
import NCCRequestReview

@main
struct NCCRequestReview_TesterApp: App {
    @StateObject var reviewManager = NCCRequestReviewManager(minimumSecondsBetweenRequests: 60.0, eventCountsAfterWhichToRequestReview: [4, 8, 16, 20])
    @Environment(\.requestReview) private var directRequestReview
    init() {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var eventCountsText: String {
        let eventCounts = reviewManager.eventCountsAfterWhichToRequestReview
        let text = eventCounts.map({"\($0)"}).joined(separator: ", ")
        return text
    }
    var body: some Scene {
        WindowGroup("NCCRequestReview - Tester App") {
            VStack {
                Text("Current event count is")
                Text("\(reviewManager.eventCount)")
                    .font(.title2)
                    .padding(.bottom)
                Text("Will call requestReview if `requestReviewIfAppropriate` is called after any of these events: ") + Text(eventCountsText).bold()

                Button(action: {
                    reviewManager.eventCount += 1
                }) {
                    Text("Increment event count")
                }

                Button(action: {
                    reviewManager.requestReviewIfAppropriate()
                }) {
                    Text("Request review if appropriate")
                }

                Button(action: {
                    directRequestReview()
                }) {
                    Text("Request review directly (control case)")
                }

            }
            .nccRequestReviewHandler()
            .environmentObject(reviewManager)
        }
    }
}
