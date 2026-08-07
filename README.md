# Flash Analytics Swift SDK

This package provides a native Swift/iOS SDK for Flash Analytics with the same core concepts as the Kotlin and React Native SDKs:

- `track`, `identify`, `increment`, `decrement`
- `revenue`, `pendingRevenue`, `flushRevenue`, `clearRevenue`
- `pageView`
- experiment assignment
- iOS helpers for app lifecycle, deep links, screen tracking, and control interaction tracking

## Install

For local development in this monorepo, add the package from disk:

```swift
.package(path: "../../packages/sdks/swift")
```

For published releases, SwiftPM requires the package manifest to live at the root of the Git repo or package registry entry. This SDK currently lives inside the monorepo at `packages/sdks/swift`, so publish it as a standalone repo history first, then depend on that repo:

```swift
.package(url: "https://github.com/NextGenCreativeSolutions/flashanalytics-swift.git", from: "1.1.5")
```

You can create that standalone package history from this repo with:

```bash
./sh/publish-swift-sdk 1.1.5 git@github.com:your-org/flashanalytics-swift.git
```

The script uses `git subtree split` to publish only `packages/sdks/swift` to the target remote.

## Quick Start

```swift
import FlashAnalytics

let analytics = FlashAnalytics.configureShared(
    options: FlashAnalyticsOptions(
        appId: "your-app-id",
        secretKey: "sec_xxx",
        endpoint: "https://qa-api.flashanalytics.app",
        maxSessionTimeoutInMin: 3,
        captureAppLifecycle: true,
        captureDeepLinks: true,
        captureScreenViews: true,
        captureViewInteractions: true
    )
)

analytics.identify(
    IdentifyPayload(
        profileId: "user-123",
        email: "user@example.com"
    )
)

analytics.track("signup_clicked", properties: ["plan": "pro"])
```

## SDK-local event rules and session timeout

```swift
let analytics = FlashAnalytics(
    options: FlashAnalyticsOptions(
        appId: "your-app-id",
        maxSessionTimeoutInMin: 3,
        allowEvents: [
            LocalSdkEventRule(
                name: "purchase",
                allowProperties: ["amount", "products.*.sku"],
                blockProperties: ["email"]
            )
        ],
        blockEvents: ["debug.*"],
        blockProperties: ["internalDebug"]
    )
)
```

Developer rules run before admin `/sdk-config` rules. `allowEvents` activates local whitelist mode when non-empty, while `blockEvents` drops matching events locally.

Property paths support `products.*.sku` for every array item and `products.0.sku` for only index `0`.

`maxSessionTimeoutInMin` controls local session expiry and heartbeat timing, is sent to the backend, and is cached per client.

## Experiment Auto-Assignment

Enable `captureVariants` to automatically keep a local cache of experiment assignments in sync throughout the session lifecycle.

```swift
let analytics = FlashAnalytics.configureShared(
    options: FlashAnalyticsOptions(
        appId: "your-app-id",
        captureVariants: CaptureVariantsOptions(
            onAssignmentsChanged: { assignments in
                // called whenever the local cache changes
            }
        )
    )
)
```

### How the local cache is maintained

**Session start (new session ID received from `/track`):**
Fetches ALL experiments — profile, session, and event-triggered — and replaces the entire local store. Only fires when the session ID actually changes; repeated `track()` calls on the same session do not re-fetch.

**After `identify()`:**
Fetches only profile-mode experiments (user identity just changed) and replaces only the profile-mode entries in the store. Session and event assignments are left untouched.

**Session expiry:**
Removes only session-mode assignments from the store when the cached session TTL runs out. Profile and event assignments survive.

### Reading assignments

```swift
// All cached assignments — no API call
let all = analytics.getAllExperiments()

// Single experiment — checks cache first, falls back to API if not found
let assignment = await analytics.getExperimentById(experimentId: "checkout-cta")
print(assignment?.variantName ?? "none")

// Callback wrapper
analytics.getExperimentById(experimentId: "checkout-cta") { assignment in
    print(assignment?.variantName ?? "none")
}
```

### Local store state at each lifecycle point

| Moment | Profile assignments | Session assignments | Event assignments |
|---|---|---|---|
| After first `track()` (new session) | fetched | fetched | fetched |
| After `identify()` | re-fetched | unchanged | unchanged |
| After session expiry | unchanged | removed | unchanged |
| After next `track()` (new session) | re-fetched | re-fetched | re-fetched |

### Manual assignment

```swift
// Single experiment
let result = await analytics.assignExperiment("checkout-cta")

// All eligible experiments
let assignments = await analytics.autoAssignExperiments()
```

## Native Crash Tracking

Enable `captureNativeCrashes` (or the equivalent `captureErrors`) to automatically capture ObjC exceptions and POSIX signals (SIGABRT, SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGPIPE) and report them as `native_crash` events on the next app launch:

```swift
let analytics = FlashAnalytics.configureShared(
    options: FlashAnalyticsOptions(
        appId: "your-app-id",
        endpoint: "https://api.flashanalytics.app",
        captureNativeCrashes: true  // installs ObjC + signal handlers
        // captureErrors: true       // alias — use either flag
    )
)
```

Crashes are written to a JSON file in the Documents directory and flushed automatically when the SDK is next initialized.

## Manual Error Tracking

Use `trackError()` to report caught errors without crashing:

```swift
do {
    try riskyOperation()
} catch {
    analytics.trackError(error)
    // or with a custom event name and extra properties:
    analytics.trackError(error, eventName: "payment_failed", properties: ["orderId": orderId])
}

// Or report a plain message string:
analytics.trackError("Unexpected nil value in user profile")
```

The default event name is `caught_error`. Properties always include `errorClass`, `message`, and `stackTrace`.

## Auto-Tracking Matrix

| Capability | Status | Notes |
| --- | --- | --- |
| App lifecycle | Auto | `captureAppLifecycle` listens to `UIApplication` notifications |
| UIKit screen views | Auto | `captureScreenViews` swizzles `UIViewController.viewDidAppear` |
| SwiftUI screen views | SDK-assisted | Use `.flashAnalyticsScreen(...)` to emit `page_view` |
| Deep links | SDK-assisted | App must call `handleOpenURL(...)` or `handleUserActivity(...)` |
| Native crashes | Auto | `captureNativeCrashes` (or `captureErrors`) installs ObjC exception + POSIX signal handlers; crash written to disk and flushed as `native_crash` on next launch |
| Experiment auto-assignment | Auto | `captureVariants` calls `/experiments/auto-assign` on new session and `identify()` |
| Push delivered/expired | Manual host wiring required | Requires a `UNNotificationServiceExtension` |
| Push open/dismiss/action | Manual host wiring required | Requires `UNUserNotificationCenterDelegate` integration in the app target |

## Notification Lifecycle Manual

The Swift SDK supports notification lifecycle events through the same
`track()` pipeline.

These iOS install steps are provider-agnostic. They work for Firebase, AppsFlyer,
Braze, and similar providers as long as the notification still arrives through
APNs and the app/extension receives the payload.

Supported events:

- `notification_delivered`
- `notification_opened`
- `notification_dismissed`
- `notification_action_clicked`
- `notification_expired` _(iOS: fires via `serviceExtensionTimeWillExpire()`; Android: TTL-based via `expiresAt` in the FCM payload — see Kotlin SDK README)_

### Install in an iOS app

Import the package and configure the SDK in the host app:

```swift
import FlashAnalytics

let analytics = FlashAnalytics.configureShared(
    options: FlashAnalyticsOptions(
        appId: "your-app-id",
        endpoint: "https://api.flashanalytics.app"
    )
)
```

### Step 1: Track delivery in `UNNotificationServiceExtension`

The app developer must add a Notification Service Extension target manually in
Xcode:

1. `File` -> `New` -> `Target`
2. Choose `Notification Service Extension`
3. Add `NotificationService.swift`
4. Include the Flash Analytics package in that extension target

Example:

```swift
import UserNotifications
import FlashAnalytics

final class NotificationService: UNNotificationServiceExtension {
    // lazy var ensures a single FlashAnalytics instance per notification lifecycle.
    // Using a computed property or inline init would create a new instance on every
    // call, producing a different device ID each time.
    private lazy var analytics = FlashAnalytics(
        options: FlashAnalyticsOptions(
            appId: "your-app-id",
            endpoint: "https://api.flashanalytics.app"
        )
    )

    private var bestAttemptRequest: UNNotificationRequest?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        bestAttemptRequest = request

        if let payload = FlashNotificationPayload.from(
            userInfo: request.content.userInfo,
            fallbackNotificationId: request.identifier
        ) {
            analytics.trackNotificationDelivered(
                payload: payload,
                source: "ios_service_extension"
            )
        }

        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        guard
            let request = bestAttemptRequest,
            let payload = FlashNotificationPayload.from(
                userInfo: request.content.userInfo,
                fallbackNotificationId: request.identifier
            )
        else { return }

        analytics.trackNotificationExpired(
            payload: payload,
            source: "ios_service_extension"
        )
    }
}
```

Push payloads must include:

```json
{
  "aps": {
    "mutable-content": 1
  }
}
```

If your provider uses different custom keys, map them into the standard Flash
payload fields before calling the SDK:

- `notificationId`
- `messageId`
- `campaignId`
- `provider`
- `actionId`
- `actionLabel`

### Step 2: Track open, dismiss, and actions in the app target

Use `UNUserNotificationCenterDelegate` in the main app:

```swift
import UserNotifications
import FlashAnalytics

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    let analytics: FlashAnalytics

    init(analytics: FlashAnalytics) {
        self.analytics = analytics
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let payload = FlashNotificationPayload.from(
            userInfo: response.notification.request.content.userInfo,
            fallbackNotificationId: response.notification.request.identifier
        ) {
            if response.actionIdentifier == UNNotificationDismissActionIdentifier {
                analytics.trackNotificationDismissed(
                    payload: payload,
                    source: "ios_notification_center"
                )
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                analytics.trackNotificationOpened(
                    payload: payload,
                    source: "ios_notification_center",
                    coldStart: true
                )
            } else {
                analytics.trackNotificationActionClicked(
                    payload: payload,
                    source: "ios_notification_center",
                    properties: ["actionIdentifier": response.actionIdentifier]
                )
            }
        }

        completionHandler()
    }
}
```

### Step 3: Share config with the extension

Recommended approaches:

- App Group `UserDefaults`
- shared plist checked into the app target and extension target

The extension needs enough configuration to initialize `FlashAnalytics`, at
minimum:

- `appId`
- `endpoint`

### Manual setup summary

The iOS developer must manually:

1. add the Notification Service Extension target
2. attach the Swift package to that target
3. add the extension source file
4. add app-side notification response tracking

This part cannot be fully automated by package install alone.

## Session Access

```swift
analytics.track("page_view")

if let session = analytics.getSession() {
    print(session.id)
    print(session.estimatedExpiresAt)
    print(session.estimatedTtlMs)
}
```

## SwiftUI

Use the screen helper modifier to emit `page_view` events:

```swift
SomeView()
    .flashAnalyticsScreen(analytics, path: "Home")
```

For deep links:

```swift
.onOpenURL { url in
    analytics.handleOpenURL(url)
}
```

## Release Notes

- Commit the Swift SDK changes before publishing. The publish script releases the committed Git state, not uncommitted files from your working tree.
- Use a dedicated Swift package repository if possible. It keeps semver tags for the iOS SDK separate from tags for the rest of the monorepo.
- After pushing a release tag, point Xcode or SwiftPM at the published repo URL and tag.
