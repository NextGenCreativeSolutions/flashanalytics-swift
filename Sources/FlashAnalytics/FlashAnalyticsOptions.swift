import Foundation

public enum AutoExperimentAssignmentMode: String, Codable, Hashable, Sendable {
    case profile
    case session
}

public struct CaptureVariantsOptions: Sendable {
    public let onAssignmentsChanged: (@Sendable ([ExperimentAssignmentResponse]) -> Void)?

    public init(onAssignmentsChanged: (@Sendable ([ExperimentAssignmentResponse]) -> Void)? = nil) {
        self.onAssignmentsChanged = onAssignmentsChanged
    }
}

public struct LocalSdkEventRule: Sendable {
    public let name: String
    public let allowProperties: [String]
    public let blockProperties: [String]

    public init(
        name: String,
        allowProperties: [String] = [],
        blockProperties: [String] = []
    ) {
        self.name = name
        self.allowProperties = allowProperties
        self.blockProperties = blockProperties
    }
}

public struct FlashAnalyticsOptions {
    public let appId: String
    public let secretKey: String?
    public let endpoint: String
    public let platform: String
    public let version: String
    public let deferUntilIdentify: Bool
    public let enabled: Bool
    public let verbose: Bool
    public let maxRetries: Int
    public let initialRetryDelayMs: UInt64
    public let userAgent: String?
    public let appVersion: String?
    public let buildNumber: String?
    public let language: String?
    public let country: String?
    public let maxSessionTimeoutInMin: Int?
    public let captureScreenViews: Bool
    public let captureAppLifecycle: Bool
    public let captureDeepLinks: Bool
    public let captureInstallAttribution: Bool
    public let captureSessionOnInit: Bool
    public let capturePushLifecycle: Bool
    public let captureViewInteractions: Bool
    /// Install native crash handlers (ObjC exceptions + POSIX signals) and report
    /// any crashes from the previous session as `native_crash` events on next launch.
    public let captureNativeCrashes: Bool
    /// Automatically capture and report native crashes.
    /// Equivalent to `captureNativeCrashes` — use either flag.
    public let captureErrors: Bool
    public let captureVariants: CaptureVariantsOptions?
    public let collectionConfig: Bool
    public let allowEvents: [LocalSdkEventRule]
    public let blockEvents: [String]
    public let blockProperties: [String]
    public let shouldTrack: ((TrackHandlerPayload) -> Bool)?
    public let shouldCaptureRequest: ((URL, TrackHandlerPayload) -> Bool)?
    /// Called whenever the SDK receives, refreshes, or restores the current session ID.
    public let onSessionUpdated: ((SessionInfo) -> Void)?
    /// When true, events are buffered and sent together as a batch to /track/batch.
    /// Preserves user journey ordering by stamping each event's real trigger time
    /// at enqueue rather than at HTTP delivery.
    /// Call `flushBatch()` to flush manually (e.g. on app background).
    public let batchEnable: Bool
    /// Maximum number of events to buffer before an immediate flush is triggered.
    public let batchSize: Int
    /// Maximum time in milliseconds to wait before flushing a non-full batch.
    public let batchTimeoutMs: UInt64

    public init(
        appId: String,
        secretKey: String? = nil,
        endpoint: String = "https://api.flashanalytics.app",
        platform: String = "ios",
        version: String = SDK_VERSION,
        deferUntilIdentify: Bool = false,
        enabled: Bool = true,
        verbose: Bool = false,
        maxRetries: Int = 3,
        initialRetryDelayMs: UInt64 = 500,
        userAgent: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        language: String? = nil,
        country: String? = nil,
        maxSessionTimeoutInMin: Int? = nil,
        captureScreenViews: Bool = false,
        captureAppLifecycle: Bool = false,
        captureDeepLinks: Bool = false,
        captureInstallAttribution: Bool = false,
        captureSessionOnInit: Bool = true,
        capturePushLifecycle: Bool = false,
        captureViewInteractions: Bool = false,
        captureVariants: CaptureVariantsOptions? = nil,
        collectionConfig: Bool = true,
        allowEvents: [LocalSdkEventRule] = [],
        blockEvents: [String] = [],
        blockProperties: [String] = [],
        captureNativeCrashes: Bool = false,
        captureErrors: Bool = false,
        shouldTrack: ((TrackHandlerPayload) -> Bool)? = nil,
        shouldCaptureRequest: ((URL, TrackHandlerPayload) -> Bool)? = nil,
        onSessionUpdated: ((SessionInfo) -> Void)? = nil,
        batchEnable: Bool = false,
        batchSize: Int = 10,
        batchTimeoutMs: UInt64 = 5_000
    ) {
        precondition(UUID(uuidString: appId) != nil, "FlashAnalytics appId must be a valid UUID")
        self.appId = appId
        self.secretKey = secretKey
        self.endpoint = endpoint
        self.platform = platform
        self.version = version
        self.deferUntilIdentify = deferUntilIdentify
        self.enabled = enabled
        self.verbose = verbose
        self.maxRetries = maxRetries
        self.initialRetryDelayMs = initialRetryDelayMs
        self.userAgent = userAgent
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.language = language
        self.country = country
        self.maxSessionTimeoutInMin = maxSessionTimeoutInMin
        self.captureScreenViews = captureScreenViews
        self.captureAppLifecycle = captureAppLifecycle
        self.captureDeepLinks = captureDeepLinks
        self.captureInstallAttribution = captureInstallAttribution
        self.captureSessionOnInit = captureSessionOnInit
        self.capturePushLifecycle = capturePushLifecycle
        self.captureViewInteractions = captureViewInteractions
        self.captureVariants = captureVariants
        self.collectionConfig = collectionConfig
        self.allowEvents = allowEvents
        self.blockEvents = blockEvents
        self.blockProperties = blockProperties
        self.captureNativeCrashes = captureNativeCrashes
        self.captureErrors = captureErrors
        self.shouldTrack = shouldTrack
        self.shouldCaptureRequest = shouldCaptureRequest
        self.onSessionUpdated = onSessionUpdated
        self.batchEnable = batchEnable
        self.batchSize = batchSize
        self.batchTimeoutMs = batchTimeoutMs
    }
}

public let SDK_VERSION = "1.1.5"
