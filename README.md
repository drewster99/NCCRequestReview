# NCCRequestReview

Gated App Store review requests for SwiftUI apps. The package decides *when* asking for a review is appropriate, so the system prompt (SwiftUI's `requestReview` environment action) only appears after the user has gotten real value from the app, never during onboarding or the first session, and never in a window the user isn't using.

- Requires a minimum number of **primary actions** (finished a recording, completed a round, and so on)
- **First-session protection**: a minimum launch count and a minimum time since first launch
- **Cooldown** between request attempts, plus an optional one-request-per-app-version limit
- **Delayed, re-checked requests**: gates are evaluated when a request is scheduled and again when it fires
- **Multi-window aware**: each window registers itself; the request goes to the most recently activated active window
- **Event stream** for analytics: scheduled, attempted, skipped (with a reason), primary action recorded

## Requirements

| Platform | Minimum |
|----------|---------|
| iOS / iPadOS / Mac Catalyst | 17.0 |
| macOS | 14.0 |
| visionOS | 1.0 (builds; not declared in `platforms`) |

Swift 6 language mode. tvOS and watchOS are not supported: StoreKit's `RequestReviewAction` is unavailable there.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/drewster99/NCCRequestReview.git", from: "3.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["NCCRequestReview"])
]
```

Or in Xcode: **File ▸ Add Package Dependencies…** and enter `https://github.com/drewster99/NCCRequestReview.git`.

## Usage

Create one manager at the `App` level, attach the handler to the outermost view of every window scene, and record primary actions where they happen.

```swift
import SwiftUI
import NCCRequestReview

@main
struct MyApp: App {
    @StateObject private var reviewManager = NCCRequestReviewManager(
        configuration: .standard,
        onEvent: { event in
            // Map to your analytics, e.g.
            // Analytics.log("review_\(event)")
            print(event)
        }
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(reviewManager)
                .nccRequestReviewHandler(reviewManager)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var reviewManager: NCCRequestReviewManager

    var body: some View {
        Button("Finish recording") {
            saveRecording()
            // Counts the action, then requests a review 2 seconds later if
            // every gate passes at both moments.
            reviewManager.recordPrimaryActionAndRequestReview("recording_finished", delay: 2)
        }
    }

    private func saveRecording() { /* ... */ }
}
```

To count an action without requesting, call `recordPrimaryAction(_:)`. To request without counting, call `requestReviewIfAppropriate(trigger:delay:)`. `cancelScheduledRequest()` cancels a pending request, for example when the user starts a new task during the delay.

### Configuration

```swift
NCCRequestReviewManager.Configuration(
    minimumPrimaryActionCount: 3,                       // lifetime actions before any request
    minimumIntervalBetweenRequests: 3 * 24 * 60 * 60,   // cooldown between attempts
    minimumLaunchCount: 2,                              // never in the first launch
    minimumIntervalSinceFirstLaunch: 24 * 60 * 60,      // and not within 24 hours of it
    limitToOneRequestPerAppVersion: false               // keyed by CFBundleShortVersionString
)
```

`.standard` uses the values above. `.debugQuickTesting` (one action, a 60-second cooldown, no first-session gates) is meant for development only. Negative values are clamped to zero.

### Events

`onEvent` is called on the main actor, after the manager's state has been updated, so a handler may call back into the manager.

| Event | Meaning |
|-------|---------|
| `.primaryActionRecorded(name:totalCount:)` | A primary action was counted |
| `.reviewRequestScheduled(trigger:delaySeconds:)` | All gates passed; the request fires after the delay |
| `.reviewRequestAttempted(trigger:)` | StoreKit's review action was invoked |
| `.reviewRequestSkipped(trigger:reason:)` | No request was made; `reason` is a `SkipReason` |

**Attempted is not shown.** StoreKit never reports whether the prompt was displayed. The system rate-limits prompts (at most three a year per app), honors the user's "In-App Ratings & Reviews" setting, and suppresses prompts in TestFlight builds. `.reviewRequestAttempted` means the API was called, nothing more.

## Behavior notes

- **One manager per process.** Launches are counted when the manager is created, once per `UserDefaults` store per process. Create the manager at `App` level (as above), not lazily in a screen, and pass the same `UserDefaults` instance every time.
- **A "launch" is a process launch.** On iOS an app can stay resident for days, so `minimumLaunchCount` may take longer to satisfy than expected.
- **Clock changes.** All intervals use absolute `Date`s, so time zone changes have no effect. If a stored date is in the future (the clock was set forward, then corrected), the affected gate fails closed until real time catches up.
- **Window targeting.** The request goes to the most recently activated window whose `scenePhase` is `.active`. On macOS every visible window is `.active`, so the chosen window may not be the key window.
- **Attach to the outermost view.** A window's registration lasts from the handler view's `onAppear` to its `onDisappear`. If the handler sits on a view that disappears while its window stays open (a tab's content, a pushed view), requests skip with `.noRequestReviewAction`.
- **App extensions.** On iOS the manager reads `UIApplication.shared`, which is unavailable in app extensions. Use it only in the app target.
- **Missing app version.** If the main bundle has no `CFBundleShortVersionString`, the version is recorded as `"unknown"` and an error is logged. With `limitToOneRequestPerAppVersion` on, every build then counts as the same version.
- **Logging** uses `OSLog` with subsystem `com.nuclearcyborg.NCCRequestReview`.

Persisted state lives in `UserDefaults` under keys prefixed `NCCRequestReview.`. Version 1.x used different keys and its history is not migrated.

## Tester app

`NCCRequestReview_TesterApp` is a small macOS harness (`swift run NCCRequestReview_TesterApp`) that uses `.debugQuickTesting`. Run outside an app bundle, StoreKit does not present a real prompt, but the events and gate state are visible.

## License

MIT. See [LICENSE](LICENSE).
