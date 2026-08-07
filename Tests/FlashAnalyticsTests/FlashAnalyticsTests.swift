import Foundation
import Testing
@testable import FlashAnalytics

@Suite(.serialized)
struct FlashAnalyticsTests {
    @Test func pageViewDeduplicatesConsecutivePaths() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureScreenViews: false,
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        analytics.pageView("/pricing")
        analytics.pageView("/pricing")
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(recorder.count() == 1)
    }

    @Test func deferUntilIdentifyFlushesQueuedEvents() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                deferUntilIdentify: true,
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        analytics.track("signup_clicked")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.count() == 0)

        analytics.identify(IdentifyPayload(profileId: "user-123", email: "user@example.com"))
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(recorder.count() == 2)
    }

    @Test func sessionInitRespectsDeferUntilIdentify() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                deferUntilIdentify: true,
                captureAppLifecycle: true
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.count() == 0)

        analytics.identify(IdentifyPayload(profileId: "user-123", email: "user@example.com"))
        try await Task.sleep(nanoseconds: 400_000_000)

        let bodies = (0..<recorder.count()).compactMap { recorder.body(at: $0) }
        #expect(bodies.contains { $0.contains(#""name":"sdk_initialized""#) })
        #expect(bodies.filter { $0.contains(#""name":"sdk_initialized""#) }.count == 1)
    }

    @Test func readyDisablesFutureDeferral() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                deferUntilIdentify: true,
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        // Before ready(): event with no profileId should be queued, not sent
        analytics.track("pre_ready_event")
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(recorder.count() == 0)

        // ready() flushes the queue and disables future deferral
        analytics.ready()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 1)

        // After ready(): new event with no profileId should be sent immediately
        analytics.track("post_ready_event")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count() == 2)
    }

    @Test func assignExperimentBlockedByShouldCaptureRequest() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false,
                shouldCaptureRequest: { url, _ in !url.path.contains("/experiments/assign") }
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        let result = await analytics.assignExperiment(experimentId: "exp-1")
        #expect(result == nil)
        #expect(recorder.count() == 0)
    }

    @Test func assignExperimentAllowedByShouldCaptureRequest() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false,
                shouldCaptureRequest: { _, _ in true }
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        _ = await analytics.assignExperiment(experimentId: "exp-1")
        #expect(recorder.count() == 1)
    }

    @Test func normalizesNestedProperties() {
        let normalized = JSONValue.normalize(dictionary: [
            "count": 3,
            "meta": [
                "flag": true,
                "url": URL(string: "https://flashanalytics.app")!,
            ],
            "timestamps": [Date(timeIntervalSince1970: 0)],
        ])

        #expect(normalized["count"] as? Int == 3)
        #expect((normalized["meta"] as? [String: Any])?["flag"] as? Bool == true)
        #expect((normalized["meta"] as? [String: Any])?["url"] as? String == "https://flashanalytics.app")
        #expect((normalized["timestamps"] as? [String])?.first == "1970-01-01T00:00:00Z")
    }

    @Test func getSessionUsesTrackResponseExpiry() async throws {
        let recorder = RequestRecorder()
        let expiresAt = Int(Date().addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000)
        var callbackSession: SessionInfo?
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false,
                onSessionUpdated: { callbackSession = $0 }
            ),
            session: makeSession(
                recorder: recorder,
                responseBody: #"{"sessionId":"session-123","estimatedSessionExpiresAt":\#(expiresAt)}"#
            ),
            userDefaults: makeUserDefaults()
        )

        analytics.track("page_view")
        try await Task.sleep(nanoseconds: 300_000_000)

        let session = analytics.getSession()
        #expect(session?.id == "session-123")
        #expect(session?.estimatedExpiresAt == expiresAt)
        #expect((session?.estimatedTtlMs ?? 0) > 0)
        #expect(callbackSession?.id == "session-123")
        #expect(callbackSession?.estimatedExpiresAt == expiresAt)
        #expect((callbackSession?.estimatedTtlMs ?? 0) > 0)
    }

    @Test func identifyIncludesActiveSessionIdWhenProfileDataIsProvided() async throws {
        let recorder = RequestRecorder()
        let expiresAt = Int(Date().addingTimeInterval(30 * 60).timeIntervalSince1970 * 1000)
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(
                recorder: recorder,
                responseBodySequence: [
                    #"{"sessionId":"session-123","estimatedSessionExpiresAt":\#(expiresAt)}"#,
                    #"{}"#
                ]
            ),
            userDefaults: makeUserDefaults()
        )

        analytics.track("page_view")
        try await Task.sleep(nanoseconds: 300_000_000)

        analytics.identify(IdentifyPayload(profileId: "user-123", email: "user@example.com"))
        try await Task.sleep(nanoseconds: 300_000_000)

        let body = recorder.body(at: 1) ?? ""
        #expect(body.contains(#""type":"identify""#))
        #expect(body.contains(#""profileId":"user-123""#))
        #expect(body.contains(#""email":"user@example.com""#))
        #expect(body.contains(#""sessionId":"session-123""#))
    }

    @Test func getSessionFallsBackWhenExpiryIsMissing() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(
                recorder: recorder,
                responseBody: #"{"sessionId":"session-legacy"}"#
            ),
            userDefaults: makeUserDefaults()
        )

        analytics.track("page_view")
        try await Task.sleep(nanoseconds: 300_000_000)

        let session = analytics.getSession()
        #expect(session?.id == "session-legacy")
        #expect((session?.estimatedTtlMs ?? 0) > 0)
    }

    @Test func staleServerExpiryFallsBackToNowPlusSessionTimeout() async throws {
        let recorder = RequestRecorder()
        let staleExpiry = Int(Date().addingTimeInterval(-(5 * 60)).timeIntervalSince1970 * 1000)
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false
            ),
            session: makeSession(
                recorder: recorder,
                responseBody: #"{"sessionId":"session-stale","estimatedSessionExpiresAt":\#(staleExpiry)}"#
            ),
            userDefaults: makeUserDefaults()
        )

        analytics.track("page_view")
        try await Task.sleep(nanoseconds: 300_000_000)

        let session = analytics.getSession()
        #expect(session?.id == "session-stale")
        #expect((session?.estimatedTtlMs ?? 0) > (29 * 60 * 1000))
        #expect((session?.estimatedTtlMs ?? 0) <= (30 * 60 * 1000))
    }

    @Test func trackNotificationEventUsesStandardTrackPipeline() async throws {
        let recorder = RequestRecorder()
        let analytics = FlashAnalytics(
            options: FlashAnalyticsOptions(
                appId: "11111111-1111-4111-8111-111111111111",
                endpoint: "https://example.com",
                captureAppLifecycle: false,
                captureSessionOnInit: false,
                capturePushLifecycle: true
            ),
            session: makeSession(recorder: recorder),
            userDefaults: makeUserDefaults()
        )

        analytics.trackNotificationEvent(
            .opened,
            payload: FlashNotificationPayload(
                notificationId: "notif-123",
                messageId: "msg-123",
                provider: "firebase"
            ),
            source: "ios_notification_center",
            coldStart: true
        )
        try await Task.sleep(nanoseconds: 300_000_000)

        let body = recorder.body(at: 0) ?? ""
        #expect(body.contains(#""name":"notification_opened""#))
        #expect(body.contains(#""notificationId":"notif-123""#))
        #expect(body.contains(#""messageId":"msg-123""#))
        #expect(body.contains(#""provider":"firebase""#))
        #expect(body.contains(#""source":"ios_notification_center""#))
        #expect(body.contains(#""coldStart":true"#))
    }

    @Test func notificationPayloadParsesUserInfo() {
        let payload = FlashNotificationPayload.from(
            userInfo: [
                "notification_id": "notif-123",
                "message_id": "msg-123",
                "provider": "firebase",
                "custom": "value",
            ]
        )

        #expect(payload?.notificationId == "notif-123")
        #expect(payload?.messageId == "msg-123")
        #expect(payload?.provider == "firebase")
        #expect(payload?.properties["custom"] as? String == "value")
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestCount = 0
    private var requestBodies: [String] = []

    func appendRequest(body: Data?) {
        lock.lock()
        requestCount += 1
        if let body, let string = String(data: body, encoding: .utf8) {
            requestBodies.append(string)
        } else {
            requestBodies.append("")
        }
        lock.unlock()
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func body(at index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard requestBodies.indices.contains(index) else { return nil }
        return requestBodies[index]
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var recorder: RequestRecorder?
    nonisolated(unsafe) static var responseBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder?.appendRequest(body: requestBody(for: request))

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 202,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.responseBodies.isEmpty {
            let responseBody = Self.responseBodies.removeFirst()
            client?.urlProtocol(self, didLoad: responseBody)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let data = NSMutableData()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, length: read)
        }
        return data as Data
    }
}

private func makeSession(
    recorder: RequestRecorder,
    responseBody: String? = nil,
    responseBodySequence: [String] = []
) -> URLSession {
    MockURLProtocol.recorder = recorder
    MockURLProtocol.responseBodies = responseBodySequence.map { Data($0.utf8) }
    if let responseBody {
        MockURLProtocol.responseBodies = [Data(responseBody.utf8)]
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeUserDefaults() -> UserDefaults {
    let suite = "FlashAnalyticsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}
