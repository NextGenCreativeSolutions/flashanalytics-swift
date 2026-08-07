import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class FlashAnalytics: @unchecked Sendable {
    public static let sdkVersion = SDK_VERSION

    @MainActor private static var sharedInstance: FlashAnalytics?

    private let options: FlashAnalyticsOptions
    private let api: APIClient
    private let userDefaults: UserDefaults
    private let stateLock = NSLock()

    private static let sessionTimeoutSeconds: TimeInterval = 30 * 60

    private var sessionIdKey: String { "flashanalytics.session_id.\(options.appId)" }
    private var sessionIdTimestampKey: String { "flashanalytics.session_id_ts.\(options.appId)" }

    private var _profileId: String?
    private var profileProperties: [String: Any]?
    private var sessionProperties: [String: Any]?
    private var _sessionId: String?
    private var _sessionIdExpiresAt: TimeInterval = 0
    private var capturedAssignments: [String: ExperimentAssignmentResponse] = [:]
    private var lastAutoSessionKey: String?
    private var globalProperties: [String: Any] = [:]
    private var deferredQueue: [TrackHandlerPayload] = []
    private var _deferUntilIdentifyEnabled: Bool
    private var _hasTrackedInitialOpen = false
    private var pendingRevenues: [PendingRevenueEntry] = []
    private var lastPagePath = ""
    private var observers: [NSObjectProtocol] = []
    private var batchQueue: [BatchQueueItem] = []
    private var batchFlushTask: Task<Void, Never>?
    private var hasTrackedSessionInit = false
    private var sessionInitTask: Task<Void, Never>?

    @MainActor public static func configureShared(
        options: FlashAnalyticsOptions,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) -> FlashAnalytics {
        if let sharedInstance {
            return sharedInstance
        }

        let analytics = FlashAnalytics(options: options, session: session, userDefaults: userDefaults)
        sharedInstance = analytics
        return analytics
    }

    @MainActor public static var shared: FlashAnalytics {
        guard let sharedInstance else {
            fatalError("FlashAnalytics is not configured. Call FlashAnalytics.configureShared(options:) first.")
        }
        return sharedInstance
    }

    public init(
        options: FlashAnalyticsOptions,
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.options = options
        self.userDefaults = userDefaults
        self._deferUntilIdentifyEnabled = options.deferUntilIdentify

        let endpoint = URL(string: options.endpoint) ?? URL(string: "https://api.flashanalytics.app")!
        var headers = [
            "flash-analytics-client-id": options.appId,
            "flash-analytics-sdk-name": options.platform,
            "flash-analytics-sdk-version": options.version,
        ]
        if let secretKey = options.secretKey, !secretKey.isEmpty {
            headers["flash-analytics-client-secret"] = secretKey
        }
        if let userAgent = options.userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        }

        self.api = APIClient(
            baseURL: endpoint,
            defaultHeaders: headers,
            session: session,
            maxRetries: options.maxRetries,
            initialRetryDelayMs: options.initialRetryDelayMs
        )

        restorePendingRevenues()
        restorePersistedSessionId()
        setGlobalProperties(defaultProperties())
        loadPersistedBatchQueue()
        trackSessionInitialized()
        registerAutoCaptureIfNeeded()

        let installBuild = options.captureAppLifecycle ? trackInstallOrUpdate() : nil

        if options.captureInstallAttribution {
            Task {
                await self.resolveInstallAttributionIfNeeded(url: nil, installBuild: installBuild)
            }
        } else if let installBuild {
            trackAfterSessionInit("app_installed")
            // Write only after the event fires so a kill before track() leaves
            // lastBuildNumber unset and the install retries on next launch.
            userDefaults.set(installBuild, forKey: StorageKey.lastBuildNumber)
        }

        if options.captureNativeCrashes || options.captureErrors {
            FlashCrashHandler.install()
            flushPendingCrashReports()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    public var profileId: String? {
        stateLock.withLock { _profileId }
    }

    public var sessionId: String? { getSessionId() }

    public func getSession() -> SessionInfo? {
        let expired = stateLock.withLock { () -> Bool in
            guard _sessionId != nil else { return false }
            guard Date().timeIntervalSince1970 >= _sessionIdExpiresAt else { return false }
            _sessionId = nil
            _sessionIdExpiresAt = 0
            lastAutoSessionKey = nil
            userDefaults.removeObject(forKey: sessionIdKey)
            userDefaults.removeObject(forKey: sessionIdTimestampKey)
            return true
        }
        if expired {
            removeSessionAssignments()
            return nil
        }
        return stateLock.withLock {
            guard let id = _sessionId else { return nil }
            let expiresAtMs = Int(_sessionIdExpiresAt * 1000)
            let ttlMs = max(0, expiresAtMs - Int(Date().timeIntervalSince1970 * 1000))
            return SessionInfo(id: id, estimatedExpiresAt: expiresAtMs, estimatedTtlMs: ttlMs)
        }
    }

    public func getSessionId() -> String? {
        getSession()?.id
    }

    private func onSessionId(_ id: String, estimatedExpiresAtMs: Int? = nil) {
        let expiresAt = normalizeSessionExpiryFromResponse(estimatedExpiresAtMs)
        let shouldRefresh = stateLock.withLock { () -> Bool in
            let changed = lastAutoSessionKey != id
            _sessionId = id
            _sessionIdExpiresAt = expiresAt
            if changed {
                lastAutoSessionKey = id
            }
            return changed
        }
        userDefaults.set(id, forKey: sessionIdKey)
        userDefaults.set(expiresAt, forKey: sessionIdTimestampKey)
        notifySessionUpdated(id: id, expiresAt: expiresAt)
        if shouldRefresh {
            refreshCapturedVariants()
        }
    }

    private func restorePersistedSessionId() {
        guard let id = userDefaults.string(forKey: sessionIdKey) else { return }
        let storedExpiry = userDefaults.double(forKey: sessionIdTimestampKey)
        let expiresAt = normalizeRestoredSessionExpiresAt(storedExpiry > 0 ? Int(storedExpiry * 1000) : nil)
        if expiresAt > Date().timeIntervalSince1970 {
            stateLock.withLock {
                _sessionId = id
                _sessionIdExpiresAt = expiresAt
                lastAutoSessionKey = id
            }
            notifySessionUpdated(id: id, expiresAt: expiresAt)
            refreshCapturedVariants()
        } else {
            userDefaults.removeObject(forKey: sessionIdKey)
            userDefaults.removeObject(forKey: sessionIdTimestampKey)
        }
    }

    private func notifySessionUpdated(id: String, expiresAt: TimeInterval) {
        guard let onSessionUpdated = options.onSessionUpdated else { return }
        let expiresAtMs = Int(expiresAt * 1000)
        let ttlMs = max(0, expiresAtMs - Int(Date().timeIntervalSince1970 * 1000))
        onSessionUpdated(SessionInfo(id: id, estimatedExpiresAt: expiresAtMs, estimatedTtlMs: ttlMs))
    }

    public func setGlobalProperties(_ properties: [String: Any]) {
        let normalized = JSONValue.normalize(dictionary: properties)
        stateLock.withLock {
            globalProperties.merge(normalized, uniquingKeysWith: { _, new in new })
        }
    }

    public func getCapturedVariants() -> [ExperimentAssignmentResponse] {
        stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
        }
    }

    public func getAllExperiments() -> [ExperimentAssignmentResponse] {
        stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
        }
    }

    private func upsertAssignment(_ assignment: ExperimentAssignmentResponse) {
        let before = stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                .map { "\($0.experimentId):\($0.variantId)" }
        }
        stateLock.withLock {
            capturedAssignments[assignment.experimentId] = assignment
        }
        let after = stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                .map { "\($0.experimentId):\($0.variantId)" }
        }
        if before != after {
            options.captureVariants?.onAssignmentsChanged?(getAllExperiments())
        }
    }

    public func getExperimentById(experimentId: String) async -> ExperimentAssignmentResponse? {
        if let local = stateLock.withLock({ capturedAssignments[experimentId] }) {
            return local
        }
        let result = await assignExperiment(experimentId: experimentId)
        if let result {
            upsertAssignment(result)
        }
        return result
    }

    public func getExperimentById(
        experimentId: String,
        completion: @escaping @Sendable (ExperimentAssignmentResponse?) -> Void
    ) {
        Task { completion(await getExperimentById(experimentId: experimentId)) }
    }

    private func refreshCapturedVariants() {
        guard let captureVariants = options.captureVariants else { return }
        Task {
            let assignments = await autoAssignExperiments()
            let before = stateLock.withLock {
                capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                    .map { "\($0.experimentId):\($0.variantId)" }
            }
            stateLock.withLock {
                capturedAssignments.removeAll()
                for assignment in assignments {
                    capturedAssignments[assignment.experimentId] = assignment
                }
            }
            let after = stateLock.withLock {
                capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                    .map { "\($0.experimentId):\($0.variantId)" }
            }
            if before != after {
                captureVariants.onAssignmentsChanged?(getAllExperiments())
            }
        }
    }

    private func refreshProfileAssignments() {
        guard let captureVariants = options.captureVariants else { return }
        Task {
            let assignments = await autoAssignExperiments(
                AutoExperimentAssignmentOptions(modes: [.profile])
            )
            let before = stateLock.withLock {
                capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                    .map { "\($0.experimentId):\($0.variantId)" }
            }
            stateLock.withLock {
                capturedAssignments = capturedAssignments.filter { _, a in
                    a.assignmentMode.autoMode != .profile
                }
                for assignment in assignments {
                    capturedAssignments[assignment.experimentId] = assignment
                }
            }
            let after = stateLock.withLock {
                capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                    .map { "\($0.experimentId):\($0.variantId)" }
            }
            if before != after {
                captureVariants.onAssignmentsChanged?(getAllExperiments())
            }
        }
    }

    // Used only for session-expiry cleanup — keeps profile/event assignments intact
    private func removeSessionAssignments() {
        let before = stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                .map { "\($0.experimentId):\($0.variantId)" }
        }
        stateLock.withLock {
            capturedAssignments = capturedAssignments.filter { _, assignment in
                assignment.assignmentMode.autoMode != .session
            }
        }
        let after = stateLock.withLock {
            capturedAssignments.values.sorted { $0.experimentName < $1.experimentName }
                .map { "\($0.experimentId):\($0.variantId)" }
        }
        if before != after {
            options.captureVariants?.onAssignmentsChanged?(getAllExperiments())
        }
    }

    public func track(_ name: String, properties: [String: Any] = [:]) {
        let normalized = JSONValue.normalize(dictionary: properties)
        let resolvedProfileId = normalized["profileId"] as? String ?? profileId
        let payload = TrackPayload(
            name: name,
            properties: mergedProperties(with: normalized),
            profileId: resolvedProfileId
        )

        log("track", name, normalized)
        send(.track(payload))
    }

    @discardableResult
    private func trackSessionInitialized() -> Task<Void, Never>? {
        guard options.captureSessionOnInit, options.enabled else {
            return nil
        }

        let payload = TrackPayload(
            name: "sdk_initialized",
            properties: mergedProperties(with: [:]),
            profileId: profileId
        )
        if let shouldTrack = options.shouldTrack, !shouldTrack(.track(payload)) {
            return nil
        }

        enum SessionInitStart {
            case existing(Task<Void, Never>)
            case deferred
            case started(Task<Void, Never>)
            case skipped
        }

        let start = stateLock.withLock { () -> SessionInitStart in
            if let sessionInitTask {
                return .existing(sessionInitTask)
            }
            guard !hasTrackedSessionInit else {
                return .skipped
            }
            hasTrackedSessionInit = true
            if _deferUntilIdentifyEnabled && _profileId == nil {
                return .deferred
            }
            let task = Task { [weak self] in
                guard let self else { return }
                _ = await self.dispatch(.track(payload))
                self.stateLock.withLock {
                    self.sessionInitTask = nil
                }
            }
            sessionInitTask = task
            return .started(task)
        }

        switch start {
        case .existing(let task):
            return task
        case .deferred:
            send(.track(payload))
            return nil
        case .skipped:
            return nil
        case .started(let task):
            return task
        }
    }

    private func trackAfterSessionInit(_ name: String, properties: [String: String] = [:]) {
        guard let initTask = trackSessionInitialized() else {
            track(name, properties: properties)
            return
        }

        Task { [weak self] in
            await initTask.value
            self?.track(name, properties: properties)
        }
    }

    public func identify(_ payload: IdentifyPayload) {
        log("identify", payload.profileId)
        let mergedProfileProperties = mergedProperties(with: payload.properties ?? [:])

        stateLock.withLock {
            _profileId = payload.profileId
            profileProperties = mergedProfileProperties
        }

        guard options.enabled else { return }

        let resolvedSessionId = payload.sessionId ?? getSessionId()
        let resolvedPayload = IdentifyPayload(
            profileId: payload.profileId,
            sessionId: resolvedSessionId,
            firstName: payload.firstName,
            lastName: payload.lastName,
            email: payload.email,
            avatar: payload.avatar,
            properties: payload.properties
        )

        if resolvedPayload.hasProfileData {
            let mergedPayload = IdentifyPayload(
                profileId: payload.profileId,
                sessionId: resolvedSessionId,
                firstName: payload.firstName,
                lastName: payload.lastName,
                email: payload.email,
                avatar: payload.avatar,
                properties: mergedProperties(with: payload.properties ?? [:])
            )

            Task { [weak self] in
                guard let self else { return }
                if options.batchEnable {
                    await self.flushBatch()
                }
                _ = await self.dispatch(.identify(mergedPayload))
                await self.flushDeferredQueue()
            }
        } else {
            ready()
        }

        refreshProfileAssignments()
    }

    public func increment(_ payload: IncrementPayload) {
        log("increment", payload.property)
        send(.increment(payload))
    }

    public func decrement(_ payload: DecrementPayload) {
        log("decrement", payload.property)
        send(.decrement(payload))
    }

    public func revenue(_ amount: Double, properties: [String: Any] = [:]) {
        var normalized = JSONValue.normalize(dictionary: properties)
        if let deviceId = normalized["deviceId"] as? String {
            normalized.removeValue(forKey: "deviceId")
            normalized["__deviceId"] = deviceId
        }
        normalized["__revenue"] = amount
        track("revenue", properties: normalized)
    }

    public func pageView(properties: [String: Any] = [:]) {
        track("page_view", properties: properties)
    }

    public func pageView(_ path: String, properties: [String: Any] = [:]) {
        let shouldTrack = stateLock.withLock { () -> Bool in
            guard lastPagePath != path else { return false }
            lastPagePath = path
            return true
        }

        guard shouldTrack else { return }
        var normalized = JSONValue.normalize(dictionary: properties)
        normalized["__path"] = path
        track("page_view", properties: normalized)
    }

    public func trackScreen(_ name: String, properties: [String: Any] = [:]) {
        pageView(name, properties: properties)
    }

    public func trackNotificationEvent(
        _ event: FlashNotificationEvent,
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        guard options.capturePushLifecycle else { return }
        var mergedProperties = payload.properties
        mergedProperties["notificationId"] = payload.notificationId
        if let messageId = payload.messageId { mergedProperties["messageId"] = messageId }
        if let campaignId = payload.campaignId { mergedProperties["campaignId"] = campaignId }
        if let provider = payload.provider { mergedProperties["provider"] = provider }
        if let actionId = payload.actionId { mergedProperties["actionId"] = actionId }
        if let actionLabel = payload.actionLabel { mergedProperties["actionLabel"] = actionLabel }
        if let source { mergedProperties["source"] = source }
        if let appState { mergedProperties["appState"] = appState }
        if let coldStart { mergedProperties["coldStart"] = coldStart }
        mergedProperties.merge(properties, uniquingKeysWith: { _, new in new })
        track(event.rawValue, properties: mergedProperties)
    }

    public func trackNotificationDelivered(
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        trackNotificationEvent(
            .delivered,
            payload: payload,
            source: source,
            appState: appState,
            coldStart: coldStart,
            properties: properties
        )
    }

    public func trackNotificationOpened(
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        trackNotificationEvent(
            .opened,
            payload: payload,
            source: source,
            appState: appState,
            coldStart: coldStart,
            properties: properties
        )
    }

    public func trackNotificationDismissed(
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        trackNotificationEvent(
            .dismissed,
            payload: payload,
            source: source,
            appState: appState,
            coldStart: coldStart,
            properties: properties
        )
    }

    public func trackNotificationActionClicked(
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        trackNotificationEvent(
            .actionClicked,
            payload: payload,
            source: source,
            appState: appState,
            coldStart: coldStart,
            properties: properties
        )
    }

    public func trackNotificationExpired(
        payload: FlashNotificationPayload,
        source: String? = nil,
        appState: String? = nil,
        coldStart: Bool? = nil,
        properties: [String: Any] = [:]
    ) {
        trackNotificationEvent(
            .expired,
            payload: payload,
            source: source,
            appState: appState,
            coldStart: coldStart,
            properties: properties
        )
    }

    /// Manually track a caught error (e.g. inside a do/catch block).
    ///
    /// ```swift
    /// do {
    ///     try riskyOperation()
    /// } catch {
    ///     analytics.trackError(error)
    /// }
    /// ```
    public func trackError(_ error: Error, eventName: String = "caught_error", properties: [String: Any] = [:]) {
        var props: [String: Any] = [
            "errorClass": String(describing: type(of: error)),
            "message":    error.localizedDescription,
        ]
        props.merge(properties, uniquingKeysWith: { _, new in new })
        track(eventName, properties: props)
    }

    /// Manually track a caught ObjC exception or any other string-described error.
    public func trackError(message: String, eventName: String = "caught_error", properties: [String: Any] = [:]) {
        var props: [String: Any] = ["message": message]
        props.merge(properties, uniquingKeysWith: { _, new in new })
        track(eventName, properties: props)
    }

    public func pendingRevenue(_ amount: Double, properties: [String: Any] = [:]) {
        let entry = PendingRevenueEntry(amount: amount, properties: JSONValue.normalize(dictionary: properties))
        let snapshot = stateLock.withLock { () -> [PendingRevenueEntry] in
            pendingRevenues.append(entry)
            return pendingRevenues
        }
        persistPendingRevenues(snapshot)
    }

    public func flushRevenue() {
        let queued = stateLock.withLock { () -> [PendingRevenueEntry] in
            let snapshot = pendingRevenues
            pendingRevenues.removeAll()
            return snapshot
        }

        persistPendingRevenues([])
        queued.forEach { revenue($0.amount, properties: $0.properties) }
    }

    public func clearRevenue() {
        stateLock.withLock {
            pendingRevenues.removeAll()
        }
        persistPendingRevenues([])
    }

    public func fetchDeviceId() -> String {
        if let existing = userDefaults.string(forKey: StorageKey.deviceId) {
            return existing
        }

#if canImport(UIKit)
        let generated = [
            "ios",
            UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
        ].joined(separator: "_")
#else
        let generated = [
            "apple",
            UUID().uuidString,
        ].joined(separator: "_")
#endif

        userDefaults.set(generated, forKey: StorageKey.deviceId)
        return generated
    }

    public func fetchRemoteConfig(_ context: RemoteConfigContext = .init()) async -> RemoteConfigSnapshot {
        let mergedContext = autoRemoteConfigContext().merging(with: context)
        guard let data = await api.send(
            path: "/remote-config",
            method: "GET",
            queryItems: mergedContext.queryItems
        ) else {
            return RemoteConfigSnapshot()
        }

        guard let response = try? JSONDecoder().decode(RemoteConfigResponse.self, from: data) else {
            return RemoteConfigSnapshot()
        }

        let parameters = response.parameters?.mapValues { $0.toFoundationObject() } ?? [:]
        return RemoteConfigSnapshot(parameters: parameters)
    }

    public func fetchRemoteConfig(
        _ context: RemoteConfigContext = .init(),
        completion: @escaping @Sendable (RemoteConfigSnapshot) -> Void
    ) {
        Task {
            completion(await fetchRemoteConfig(context))
        }
    }

    public func setSessionProperties(_ properties: [String: Any]) {
        stateLock.withLock {
            sessionProperties = JSONValue.normalize(dictionary: properties)
        }
    }

    public func clear() {
        stateLock.withLock {
            _profileId = nil
            profileProperties = nil
            sessionProperties = nil
            _sessionId = nil
            _sessionIdExpiresAt = 0
            capturedAssignments.removeAll()
            lastAutoSessionKey = nil
            batchQueue.removeAll()
            batchFlushTask?.cancel()
            batchFlushTask = nil
        }
        userDefaults.removeObject(forKey: sessionIdKey)
        userDefaults.removeObject(forKey: sessionIdTimestampKey)
        userDefaults.removeObject(forKey: batchQueueKey)
    }

    public func ready() {
        stateLock.withLock {
            _deferUntilIdentifyEnabled = false
        }
        Task {
            await self.flushDeferredQueue()
        }
    }

    public func handleOpenURL(_ url: URL) {
        guard options.captureDeepLinks else { return }
        track("deep_link_opened", properties: deepLinkProperties(for: url))
        guard options.captureInstallAttribution else { return }
        Task {
            await resolveInstallAttributionIfNeeded(url: url, installBuild: nil)
        }
    }

    public func handleUserActivity(_ activity: NSUserActivity) {
        guard options.captureDeepLinks, activity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = activity.webpageURL else { return }
        handleOpenURL(url)
    }

#if canImport(UIKit)
    public func trackViewController(_ viewController: UIViewController) {
        guard options.captureScreenViews else { return }
        let screenName = Self.screenName(for: type(of: viewController))
        guard !screenName.isEmpty else { return }
        pageView(screenName)
    }

    @MainActor
    public func attachControlTracking(
        to control: UIControl,
        eventName: String,
        properties: [String: Any] = [:],
        for events: UIControl.Event = .touchUpInside
    ) {
        guard options.captureViewInteractions else { return }

        let tracker = ControlTracker(analytics: self, eventName: eventName, properties: properties)
        control.addTarget(tracker, action: #selector(ControlTracker.handleControlEvent), for: events)
        control.flashAnalyticsTrackers.add(tracker)
    }
#endif

    public func assignExperiment(
        experimentId: String,
        options: ExperimentAssignmentOptions = .init()
    ) async -> ExperimentAssignmentResponse? {
        guard self.options.enabled else { return nil }

        let resolvedUserId = (options.userId?.isEmpty == false ? options.userId : profileId)
        let resolvedDeviceId = (options.deviceId?.isEmpty == false ? options.deviceId : fetchDeviceId())
        let resolvedProperties: [String: Any]?
        if options.includeInternalProperties {
            resolvedProperties = mergedProperties(with: options.properties ?? [:])
        } else {
            resolvedProperties = options.properties.map(JSONValue.normalize(dictionary:))
        }

        let request = ExperimentAssignmentRequest(
            experimentId: experimentId,
            userId: resolvedUserId,
            deviceId: resolvedDeviceId,
            eventName: options.eventName,
            profile: options.profile.map(JSONValue.normalize(dictionary:)) ?? profileProperties,
            sessionProperties: options.sessionProperties.map(JSONValue.normalize(dictionary:)),
            properties: resolvedProperties
        )

        log("assignExperiment", experimentId)
        let assignUrl = api.url(for: "/experiments/assign")
        if let shouldCaptureRequest = self.options.shouldCaptureRequest {
            var syntheticProps: [String: Any] = ["experimentId": experimentId]
            if let id = resolvedDeviceId { syntheticProps["deviceId"] = id }
            if let name = options.eventName { syntheticProps["eventName"] = name }
            if let profile = options.profile { syntheticProps["profile"] = JSONValue.normalize(dictionary: profile) }
            if let sessionProperties = options.sessionProperties { syntheticProps["sessionProperties"] = JSONValue.normalize(dictionary: sessionProperties) }
            if let props = resolvedProperties { syntheticProps["properties"] = props }
            let syntheticPayload = TrackHandlerPayload.track(
                TrackPayload(name: "__experiment_assign", properties: syntheticProps, profileId: resolvedUserId)
            )
            if !shouldCaptureRequest(assignUrl, syntheticPayload) {
                log("filtered by shouldCaptureRequest", assignUrl.absoluteString)
                return nil
            }
        }
        guard let data = await api.send(path: "/experiments/assign", body: request.jsonObject) else {
            return nil
        }

        return try? JSONDecoder().decode(ExperimentAssignmentResponse.self, from: data)
    }

    public func autoAssignExperiments(
        _ options: AutoExperimentAssignmentOptions = .init()
    ) async -> [ExperimentAssignmentResponse] {
        guard self.options.enabled else { return [] }

        let resolvedModes = options.modes  // nil = no filter (API returns all)
        let resolvedProperties: [String: Any]?
        if options.includeInternalProperties {
            resolvedProperties = mergedProperties(with: [:])
        } else {
            resolvedProperties = nil
        }
        let resolvedDeviceId = fetchDeviceId()
        let resolvedSessionId = getSessionId()

        let request = AutoExperimentAssignmentRequest(
            modes: resolvedModes.map { Array($0).sorted { $0.rawValue < $1.rawValue } },
            userId: profileId,
            deviceId: resolvedDeviceId,
            sessionId: resolvedSessionId,
            profile: profileProperties,
            sessionProperties: sessionProperties,
            properties: resolvedProperties
        )

        let autoAssignUrl = api.url(for: "/experiments/auto-assign")
        if let shouldCaptureRequest = self.options.shouldCaptureRequest {
            var syntheticProps: [String: Any] = [:]
            if let resolvedModes {
                syntheticProps["modes"] = resolvedModes.map(\.rawValue).sorted()
            }
            syntheticProps["deviceId"] = resolvedDeviceId
            if let resolvedSessionId { syntheticProps["sessionId"] = resolvedSessionId }
            if let profileProperties { syntheticProps["profile"] = profileProperties }
            if let sessionProperties { syntheticProps["sessionProperties"] = sessionProperties }
            if let resolvedProperties { syntheticProps["properties"] = resolvedProperties }
            let syntheticPayload = TrackHandlerPayload.track(
                TrackPayload(name: "__experiments_auto_assign", properties: syntheticProps, profileId: profileId)
            )
            if !shouldCaptureRequest(autoAssignUrl, syntheticPayload) {
                log("filtered by shouldCaptureRequest", autoAssignUrl.absoluteString)
                return []
            }
        }

        guard let data = await api.send(path: "/experiments/auto-assign", body: request.jsonObject) else {
            return []
        }

        return (try? JSONDecoder().decode(AutoExperimentAssignmentResponse.self, from: data).assignments) ?? []
    }

    public func autoAssignExperiments(
        _ options: AutoExperimentAssignmentOptions = .init(),
        completion: @escaping @Sendable ([ExperimentAssignmentResponse]) -> Void
    ) {
        Task {
            completion(await autoAssignExperiments(options))
        }
    }

    public func assignExperiment(
        experimentId: String,
        options: ExperimentAssignmentOptions = .init(),
        completion: @escaping @Sendable (ExperimentAssignmentResponse?) -> Void
    ) {
        Task {
            let response = await assignExperiment(experimentId: experimentId, options: options)
            completion(response)
        }
    }

    private func registerAutoCaptureIfNeeded() {
#if canImport(UIKit)
        if options.captureAppLifecycle {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.setGlobalProperties(self.defaultProperties())
                    let isFirst = self.stateLock.withLock {
                        guard !self._hasTrackedInitialOpen else { return false }
                        self._hasTrackedInitialOpen = true
                        return true
                    }
                    if isFirst {
                        self.trackAfterSessionInit("app_opened")
                    } else {
                        self.track("app_foregrounded")
                    }
                }
            )

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.track("app_backgrounded")
                    if self?.options.batchEnable == true {
                        Task { [weak self] in await self?.flushBatch() }
                    }
                }
            )

            // Fires when the system terminates the app while it is still running
            // (e.g. killed from the foreground, low-memory eviction).
            // When the app is already suspended and killed from recents, iOS does
            // not deliver any callback — app_backgrounded is the last event in that case.
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    self?.track("app_closed")
                }
            )
        }

        if options.captureScreenViews {
            ViewControllerSwizzler.install(analytics: self)
        }
#endif
    }

    // ── Batch delivery ───────────────────────────────────────────────────────

    private struct BatchQueueItem {
        let payload: TrackHandlerPayload
        let timestamp: String

        var envelope: [String: Any] {
            var item = payload.envelope
            item["__timestamp"] = timestamp
            return item
        }
    }

    private var batchQueueKey: String { "flashanalytics.batch_queue.\(options.appId)" }

    private func persistBatchQueue() {
        let envelopes = stateLock.withLock { batchQueue.map { $0.envelope } }
        if envelopes.isEmpty {
            userDefaults.removeObject(forKey: batchQueueKey)
        } else if let data = try? JSONSerialization.data(withJSONObject: envelopes) {
            userDefaults.set(data, forKey: batchQueueKey)
        }
    }

    private func loadPersistedBatchQueue() {
        guard options.batchEnable,
              let data = userDefaults.data(forKey: batchQueueKey),
              let envelopes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !envelopes.isEmpty else { return }
        let restoredItems = envelopes.compactMap { envelope -> BatchQueueItem? in
            guard let payload = TrackHandlerPayload.from(envelope: envelope) else { return nil }
            return BatchQueueItem(
                payload: payload,
                timestamp: envelope["__timestamp"] as? String ?? Self.nowIso8601()
            )
        }
        guard !restoredItems.isEmpty else { return }
        stateLock.withLock {
            batchQueue = restoredItems + batchQueue
        }
        scheduleBatchFlush()
    }

    private static func nowIso8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func generateBatchMessageId() -> String {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let rand = Int64.random(in: 0..<0xFFFFFF)
        return "\(ts)-\(String(rand, radix: 16))"
    }

    // Stamps __timestamp and __messageId into payload properties at enqueue time
    // so event ordering is preserved regardless of when the HTTP request actually lands.
    private func stampPayloadForBatch(_ payload: TrackHandlerPayload) -> BatchQueueItem {
        let now = Self.nowIso8601()
        let stampedPayload: TrackHandlerPayload
        if case let .track(trackPayload) = payload {
            var properties = (trackPayload.properties ?? [:]) as [String: Any]
            if properties["__timestamp"] == nil { properties["__timestamp"] = now }
            if properties["__messageId"] == nil { properties["__messageId"] = generateBatchMessageId() }
            stampedPayload = .track(TrackPayload(name: trackPayload.name, properties: properties, profileId: trackPayload.profileId))
        } else {
            stampedPayload = payload
        }
        return BatchQueueItem(payload: stampedPayload, timestamp: now)
    }

    // Pure serialization of a pre-stamped payload to the /track/batch envelope format.
    private func serializeToBatchItem(_ item: BatchQueueItem) -> [String: Any] {
        item.envelope
    }

    private func enqueueBatch(_ payload: TrackHandlerPayload) {
        let stamped = stampPayloadForBatch(payload)
        let effectiveBatchSize = max(1, min(100, options.batchSize))
        let shouldFlushNow = stateLock.withLock { () -> Bool in
            batchQueue.append(stamped)
            return batchQueue.count >= effectiveBatchSize
        }
        persistBatchQueue()
        if shouldFlushNow {
            stateLock.withLock {
                batchFlushTask?.cancel()
                batchFlushTask = nil
            }
            Task { [weak self] in await self?.flushBatch() }
        } else {
            scheduleBatchFlush()
        }
    }

    private func scheduleBatchFlush() {
        let alreadyScheduled = stateLock.withLock { () -> Bool in
            guard let t = batchFlushTask else { return false }
            return !t.isCancelled
        }
        guard !alreadyScheduled else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: options.batchTimeoutMs * 1_000_000)
            guard !Task.isCancelled else { return }
            await self.flushBatch()
        }

        stateLock.withLock {
            if batchFlushTask == nil || batchFlushTask!.isCancelled {
                batchFlushTask = task
            } else {
                task.cancel()
            }
        }
    }

    /// Flush any buffered batch events immediately. Awaitable from async contexts.
    public func flushBatch() async {
        stateLock.withLock {
            batchFlushTask?.cancel()
            batchFlushTask = nil
        }
        while true {
            let chunk = stateLock.withLock { () -> [BatchQueueItem] in
                guard !batchQueue.isEmpty else { return [] }
                let size = min(100, batchQueue.count)
                let result = Array(batchQueue.prefix(size))
                batchQueue.removeFirst(size)
                return result
            }
            guard !chunk.isEmpty else { return }

            let batchItems = chunk.map { serializeToBatchItem($0) }
            let body: [String: Any] = ["batch": batchItems]
            if let data = await api.send(path: "/track/batch", body: body),
               let response = try? JSONDecoder().decode(TrackBatchResponse.self, from: data) {
                let sessionId = response.sessionId
                    ?? response.results?.compactMap { $0.sessionId }.first
                if let sessionId {
                    onSessionId(sessionId, estimatedExpiresAtMs: response.estimatedSessionExpiresAt)
                }
            } else {
                // /track/batch failed after retries — fall back to individual /track requests
                var failedItems: [BatchQueueItem] = []
                for item in chunk {
                    let delivered = await dispatch(item.payload, timestamp: item.timestamp)
                    if !delivered {
                        failedItems.append(item)
                    }
                }
                if !failedItems.isEmpty {
                    stateLock.withLock {
                        batchQueue = failedItems + batchQueue
                        batchFlushTask = nil
                    }
                    persistBatchQueue()
                    scheduleBatchFlush()
                    return
                }
            }
            // Persist remaining queue so a force-close can't lose the next chunk
            persistBatchQueue()
        }
    }

    private func send(_ payload: TrackHandlerPayload) {
        guard options.enabled else { return }

        if let shouldTrack = options.shouldTrack, !shouldTrack(payload) {
            log("filtered by shouldTrack", payload.type)
            return
        }

        let shouldDefer = stateLock.withLock { _deferUntilIdentifyEnabled && _profileId == nil }
        if shouldDefer {
            stateLock.withLock {
                deferredQueue.append(payload)
            }
            log("queued", payload.type)
            return
        }

        if options.batchEnable {
            enqueueBatch(payload)
        } else {
            Task {
                _ = await self.dispatch(payload)
            }
        }
    }

    private func dispatch(_ payload: TrackHandlerPayload, timestamp: String? = nil) async -> Bool {
        let url = api.url(for: "/track")
        if let shouldCaptureRequest = options.shouldCaptureRequest, !shouldCaptureRequest(url, payload) {
            log("filtered by shouldCaptureRequest", url.absoluteString)
            return true
        }

        var envelope = payload.envelope
        if let timestamp {
            envelope["__timestamp"] = timestamp
        }

        if let data = await api.send(path: "/track", body: envelope),
           let response = try? JSONDecoder().decode(TrackResponse.self, from: data) {
            if let id = response.sessionId {
                onSessionId(id, estimatedExpiresAtMs: response.estimatedSessionExpiresAt)
            }
            return true
        }
        return false
    }

    private func normalizeSessionExpiryFromResponse(_ expiresAtMs: Int?) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        guard let expiresAtMs, expiresAtMs > 0 else {
            return now + Self.sessionTimeoutSeconds
        }

        let expiresAtSeconds = TimeInterval(expiresAtMs) / 1000
        if expiresAtSeconds > now {
            return expiresAtSeconds
        }

        return now + Self.sessionTimeoutSeconds
    }

    private func normalizeRestoredSessionExpiresAt(_ expiresAtMs: Int?) -> TimeInterval {
        let now = Date().timeIntervalSince1970
        guard let expiresAtMs, expiresAtMs > 0 else {
            return now + Self.sessionTimeoutSeconds
        }

        let expiresAtSeconds = TimeInterval(expiresAtMs) / 1000
        if expiresAtSeconds > now {
            return expiresAtSeconds
        }

        return expiresAtSeconds + Self.sessionTimeoutSeconds
    }

    private func flushDeferredQueue() async {
        let queued = stateLock.withLock { () -> [TrackHandlerPayload] in
            let snapshot = deferredQueue
            deferredQueue.removeAll()
            return snapshot
        }

        for payload in queued {
            let backfilled = payload.backfilled(profileId: profileId)
            if options.batchEnable {
                enqueueBatch(backfilled)
            } else {
                _ = await dispatch(backfilled)
            }
        }
        if options.batchEnable && !queued.isEmpty {
            await flushBatch()
        }
    }

    private func mergedProperties(with properties: [String: Any]) -> [String: Any] {
        stateLock.withLock {
            globalProperties.merging(JSONValue.normalize(dictionary: properties), uniquingKeysWith: { _, new in new })
        }
    }

    private func remoteConfigUserProperties() -> [String: Any] {
        stateLock.withLock {
            globalProperties.compactMapValues { value in
                switch value {
                case is String, is Bool, is Int, is Double, is Float, is NSNumber:
                    return value
                default:
                    return nil
                }
            }
        }
    }

    private func autoRemoteConfigContext() -> RemoteConfigContext {
        let locale = Locale.current
        let resolvedProfileId = profileId
        let resolvedRandomSeed = resolvedProfileId ?? getSessionId() ?? fetchDeviceId()

        return RemoteConfigContext(
            platform: options.platform,
            appVersion: options.appVersion,
            buildNumber: options.buildNumber,
            language: options.language ?? locale.languageCode,
            country: options.country ?? locale.regionCode,
            profileId: resolvedProfileId,
            sessionId: getSessionId(),
            randomSeed: resolvedRandomSeed,
            userProperties: remoteConfigUserProperties()
        )
    }

    private func restorePendingRevenues() {
        guard let data = userDefaults.data(forKey: StorageKey.pendingRevenues),
              let decoded = try? JSONDecoder().decode([PendingRevenueCodable].self, from: data) else {
            return
        }

        stateLock.withLock {
            pendingRevenues = decoded.compactMap {
                guard let properties = $0.properties.toFoundationObject() as? [String: Any] else {
                    return nil
                }
                return PendingRevenueEntry(amount: $0.amount, properties: properties)
            }
        }
    }

    private func persistPendingRevenues(_ entries: [PendingRevenueEntry]) {
        let encoded = entries.map {
            PendingRevenueCodable(amount: $0.amount, properties: JSONValue.fromFoundation(dictionary: $0.properties))
        }

        if let data = try? JSONEncoder().encode(encoded) {
            userDefaults.set(data, forKey: StorageKey.pendingRevenues)
        }
    }

    private func defaultProperties() -> [String: Any] {
#if canImport(UIKit)
        var properties: [String: Any] = [
            "__deviceId": fetchDeviceId(),
            "__os": UIDevice.current.systemName,
            "__os_version": UIDevice.current.systemVersion,
            "__brand": "Apple",
            "__model": Self.hardwareModel(),
            "__device": "mobile",
        ]

        if let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            properties["__version"] = shortVersion
        }
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String {
            properties["__buildNumber"] = buildNumber
        }

        return properties
#else
        return [
            "__deviceId": fetchDeviceId(),
            "__os": "Apple",
            "__device": "desktop",
        ]
#endif
    }

    // Returns the current build string if this is a brand-new install (so the caller
    // can write lastBuildNumber after the event fires), or nil otherwise.
    // Returning the build string avoids a second Bundle.main read later, which
    // could return "0" on failure and permanently break the nil-sentinel check.
    private func trackInstallOrUpdate() -> String? {
        let currentBuild = (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "0"
        let previousBuild = userDefaults.string(forKey: StorageKey.lastBuildNumber)

        if previousBuild == nil {
            // Do NOT write lastBuildNumber yet — write it only after app_installed fires
            // so a process kill before the event fires allows a retry on next launch.
            return currentBuild
        } else if previousBuild != currentBuild {
            trackAfterSessionInit("app_updated", properties: ["previous_build": previousBuild ?? ""])
            userDefaults.set(currentBuild, forKey: StorageKey.lastBuildNumber)
        }
        return nil
    }

    private func deepLinkProperties(for url: URL) -> [String: Any] {
        var properties: [String: Any] = [
            "__url": url.absoluteString,
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
        ]

        if !url.path.isEmpty {
            properties["__path"] = url.path
        }
        if let query = url.query, !query.isEmpty {
            properties["query"] = query
        }
        return properties
    }

    // installBuild: non-nil means this is a new install; the value is the build string
    // to write to lastBuildNumber after the event fires — avoids a second Bundle.main
    // read that could return "0" and permanently break the nil-sentinel check.
    private func resolveInstallAttributionIfNeeded(url: URL?, installBuild: String?) async {
        let isFirstAppOpen = isFirstInstallAttributionOpen()
        if !isFirstAppOpen && url == nil {
            if let installBuild {
                trackAfterSessionInit("app_installed")
                userDefaults.set(installBuild, forKey: StorageKey.lastBuildNumber)
            }
            return
        }

        let request = ResolveInstallContextRequest(
            projectId: nil,
            platform: "ios",
            deviceId: fetchDeviceId(),
            profileId: profileId,
            sessionId: getSessionId(),
            clickId: url?.queryValue(for: "fa_click_id"),
            smartPageToken: url?.queryValue(for: "fa_smart_page_token"),
            installReferrer: nil,
            deepLinkUrl: url?.absoluteString,
            appInstalledAt: nil,
            firstOpenedAt: Self.iso8601Timestamp(Date()),
            isFirstAppOpen: isFirstAppOpen,
            appVersion: options.appVersion,
            buildNumber: installBuild ?? options.buildNumber ?? currentBuildNumber(),
            timezone: TimeZone.current.identifier,
            locale: Locale.current.identifier
        )

        let data = await api.send(
            path: "/deep-links/resolve-install-context",
            body: request.jsonObject
        )

        if let installBuild {
            let resultType = data
                .flatMap { try? JSONDecoder().decode(ResolveInstallContextResponse.self, from: $0) }
                .flatMap { $0.attribution?.resultType }
            trackAfterSessionInit(resultType == "reinstall" ? "app_reinstalled" : "app_installed")
            userDefaults.set(installBuild, forKey: StorageKey.lastBuildNumber)
        }

        if isFirstAppOpen {
            markInstallAttributionProcessed()
        }
    }

    private func isFirstInstallAttributionOpen() -> Bool {
        let currentBuild = currentBuildNumber()
        return userDefaults.string(forKey: StorageKey.installAttributionProcessedBuild) != currentBuild
    }

    private func markInstallAttributionProcessed() {
        userDefaults.set(currentBuildNumber(), forKey: StorageKey.installAttributionProcessedBuild)
    }

    private func currentBuildNumber() -> String {
        (Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String) ?? "0"
    }

    private static func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func flushPendingCrashReports() {
        let reports = FlashCrashHandler.consumePending()
        for report in reports {
            track("native_crash", properties: [
                "errorClass": report.errorClass,
                "message":    report.message,
                "stackTrace": report.stackTrace,
                "type":       report.type,
                "timestamp":  report.timestamp,
            ])
        }
    }

    private func log(_ parts: Any...) {
        guard options.verbose else { return }
        print("[FlashAnalytics.app]", parts.map { String(describing: $0) }.joined(separator: " "))
    }

    #if canImport(UIKit)
    func autoTrackScreenViewController(_ viewController: UIViewController) {
        guard options.captureScreenViews else { return }
        guard Bundle(for: type(of: viewController)) == .main else { return }

        let className = String(describing: type(of: viewController))
        if className.contains("UIHostingController") || className.contains("UIAlertController") {
            return
        }

        trackViewController(viewController)
    }

    private static func screenName(for viewControllerType: UIViewController.Type) -> String {
        String(describing: viewControllerType)
            .replacingOccurrences(of: "ViewController", with: "")
            .replacingOccurrences(of: "Controller", with: "")
            .replacingOccurrences(of: "View", with: "")
            .replacingOccurrences(
                of: "([A-Z]+)([A-Z][a-z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "([a-z\\d])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif

    private static func hardwareModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.compactMap { element in
            guard let value = element.value as? Int8, value != 0 else { return nil }
            return String(UnicodeScalar(UInt8(value)))
        }.joined()
    }
}

private extension AssignmentMode {
    var autoMode: AutoExperimentAssignmentMode? {
        switch self {
        case .profile:
            return .profile
        case .session:
            return .session
        case .event:
            return nil
        }
    }
}

private struct StorageKey {
    static let deviceId = "flashanalytics.device_id"
    static let pendingRevenues = "flashanalytics.pending_revenues"
    static let lastBuildNumber = "flashanalytics.last_build_number"
    static let installAttributionProcessedBuild = "flashanalytics.install_attribution_processed_build"
}

private struct PendingRevenueEntry {
    let amount: Double
    let properties: [String: Any]
}

private struct PendingRevenueCodable: Codable {
    let amount: Double
    let properties: JSONValue
}

private struct ResolveInstallContextResponse: Codable {
    struct Attribution: Codable {
        let resultType: String
    }
    let attribution: Attribution?
}

private struct ResolveInstallContextRequest {
    let projectId: String?
    let platform: String
    let deviceId: String?
    let profileId: String?
    let sessionId: String?
    let clickId: String?
    let smartPageToken: String?
    let installReferrer: String?
    let deepLinkUrl: String?
    let appInstalledAt: String?
    let firstOpenedAt: String
    let isFirstAppOpen: Bool
    let appVersion: String?
    let buildNumber: String?
    let timezone: String?
    let locale: String?

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "platform": platform,
            "firstOpenedAt": firstOpenedAt,
            "isFirstAppOpen": isFirstAppOpen,
        ]
        if let projectId { value["projectId"] = projectId }
        if let deviceId { value["deviceId"] = deviceId }
        if let profileId { value["profileId"] = profileId }
        if let sessionId { value["sessionId"] = sessionId }
        if let clickId { value["clickId"] = clickId }
        if let smartPageToken { value["smartPageToken"] = smartPageToken }
        if let installReferrer { value["installReferrer"] = installReferrer }
        if let deepLinkUrl { value["deepLinkUrl"] = deepLinkUrl }
        if let appInstalledAt { value["appInstalledAt"] = appInstalledAt }
        if let appVersion { value["appVersion"] = appVersion }
        if let buildNumber { value["buildNumber"] = buildNumber }
        if let timezone { value["timezone"] = timezone }
        if let locale { value["locale"] = locale }
        return value
    }
}

private extension URL {
    func queryValue(for name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
