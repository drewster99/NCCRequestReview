//
//  NCCRequestReview_TesterApp.swift
//  NCCRequestReview
//
//  Manual test harness for the v2 gating and scene-registry behavior.
//

import Foundation
import SwiftUI
import NCCRequestReview

@main
struct NCCRequestReview_TesterApp: App {
    @StateObject private var reviewManager = NCCRequestReviewManager(
        configuration: .debugQuickTesting,
        onEvent: { event in
            print("NCCRequestReview event: \(event)")
        }
    )

    init() {
        #if os(macOS)
        // `swift run` launches a bare executable with no app bundle; promote
        // it to a regular foreground app so its window can become active.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("NCCRequestReview - Tester App") {
            VStack(spacing: 12) {
                Text("Launch count: \(reviewManager.launchCount)")
                Text("Primary actions: \(reviewManager.primaryActionCount)")
                Text("Last attempt: \(reviewManager.lastRequestAttemptDate?.formatted() ?? "never")")

                Button("Record primary action") {
                    reviewManager.recordPrimaryAction("tester_action")
                }

                Button("Record primary action + request review") {
                    reviewManager.recordPrimaryActionAndRequestReview("tester_action", delay: 2)
                }

                Button("Request review if appropriate") {
                    reviewManager.requestReviewIfAppropriate(trigger: "tester_manual", delay: 2)
                }

                Button("Cancel scheduled request") {
                    reviewManager.cancelScheduledRequest()
                }
            }
            .padding()
            .nccRequestReviewHandler(reviewManager)
        }
    }
}
