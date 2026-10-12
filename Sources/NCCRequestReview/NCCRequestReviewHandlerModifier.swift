//
//  NCCRequestReviewHandlerModifier.swift
//  NCCRequestReview
//

import Foundation
import SwiftUI
import StoreKit

/// Registers one window's `RequestReviewAction` and scene phase with the
/// manager. Lives in each window's view tree: `WindowGroup` instantiates the
/// root view per window, so every window — including multiple windows of the
/// same scene type — registers itself automatically.
private struct NCCRequestReviewHandlerModifier: ViewModifier {
    let manager: NCCRequestReviewManager

    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var sceneToken = NCCRequestReviewManager.SceneToken()

    func body(content: Content) -> some View {
        content
            .onAppear {
                let requestReview = self.requestReview
                manager.registerScene(sceneToken, phase: scenePhase) {
                    requestReview()
                }
            }
            .onDisappear {
                manager.unregisterScene(sceneToken)
            }
            .onChange(of: scenePhase) { _, newPhase in
                manager.sceneDidChangePhase(sceneToken, phase: newPhase)
            }
    }
}

public extension View {
    /// Registers this window's review-request capability with `manager`.
    ///
    /// Attach to the OUTERMOST content view of every `WindowGroup`/`Window`
    /// scene so the manager can present the review prompt in the window the
    /// user is actually using.
    ///
    /// The registration lives from this view's `onAppear` to its
    /// `onDisappear`. Attaching it to a view that disappears while its window
    /// stays open (a tab's content, a pushed view) unregisters the window, and
    /// requests then skip with `.noRequestReviewAction`.
    func nccRequestReviewHandler(_ manager: NCCRequestReviewManager) -> some View {
        modifier(NCCRequestReviewHandlerModifier(manager: manager))
    }
}
