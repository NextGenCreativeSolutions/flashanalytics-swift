import Foundation

public struct TrackPayload: @unchecked Sendable {
    public let name: String
    public let properties: [String: Any]?
    public let profileId: String?

    public init(name: String, properties: [String: Any]? = nil, profileId: String? = nil) {
        self.name = name
        self.properties = properties
        self.profileId = profileId
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["name": name]
        if let properties {
            object["properties"] = properties
        }
        if let profileId {
            object["profileId"] = profileId
        }
        return object
    }
}

public struct IdentifyPayload: @unchecked Sendable {
    public let profileId: String
    public let sessionId: String?
    public let firstName: String?
    public let lastName: String?
    public let email: String?
    public let avatar: String?
    public let properties: [String: Any]?

    public init(
        profileId: String,
        sessionId: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        avatar: String? = nil,
        properties: [String: Any]? = nil
    ) {
        self.profileId = profileId
        self.sessionId = sessionId
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.avatar = avatar
        self.properties = properties
    }

    var hasProfileData: Bool {
        firstName != nil || lastName != nil || email != nil || avatar != nil || !(properties ?? [:]).isEmpty
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["profileId": profileId]
        if let sessionId { object["sessionId"] = sessionId }
        if let firstName { object["firstName"] = firstName }
        if let lastName { object["lastName"] = lastName }
        if let email { object["email"] = email }
        if let avatar { object["avatar"] = avatar }
        if let properties { object["properties"] = properties }
        return object
    }
}

public struct IncrementPayload: Sendable {
    public let profileId: String
    public let property: String
    public let value: Double?

    public init(profileId: String, property: String, value: Double? = nil) {
        self.profileId = profileId
        self.property = property
        self.value = value
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["profileId": profileId, "property": property]
        if let value { object["value"] = value }
        return object
    }
}

public struct DecrementPayload: Sendable {
    public let profileId: String
    public let property: String
    public let value: Double?

    public init(profileId: String, property: String, value: Double? = nil) {
        self.profileId = profileId
        self.property = property
        self.value = value
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["profileId": profileId, "property": property]
        if let value { object["value"] = value }
        return object
    }
}

public enum FlashNotificationEvent: String, Sendable {
    case delivered = "notification_delivered"
    case opened = "notification_opened"
    case dismissed = "notification_dismissed"
    case actionClicked = "notification_action_clicked"
    case expired = "notification_expired"
}

public struct FlashNotificationPayload: @unchecked Sendable {
    public let notificationId: String
    public let messageId: String?
    public let campaignId: String?
    public let provider: String?
    public let actionId: String?
    public let actionLabel: String?
    public let properties: [String: Any]

    public init(
        notificationId: String,
        messageId: String? = nil,
        campaignId: String? = nil,
        provider: String? = nil,
        actionId: String? = nil,
        actionLabel: String? = nil,
        properties: [String: Any] = [:]
    ) {
        self.notificationId = notificationId
        self.messageId = messageId
        self.campaignId = campaignId
        self.provider = provider
        self.actionId = actionId
        self.actionLabel = actionLabel
        self.properties = properties
    }

    public static func from(
        userInfo: [AnyHashable: Any],
        fallbackNotificationId: String? = nil
    ) -> FlashNotificationPayload? {
        let pairs: [(String, Any)] = userInfo.compactMap { entry in
            guard let key = entry.key as? String else { return nil }
            return (key, entry.value)
        }
        let stringKeyed = Dictionary<String, Any>(uniqueKeysWithValues: pairs)

        let notificationId = firstString(
            in: stringKeyed,
            keys: ["notificationId", "notification_id", "notif_id", "id"]
        ) ?? fallbackNotificationId

        guard let notificationId, !notificationId.isEmpty else { return nil }

        let reservedKeys: Set<String> = [
            "notificationId",
            "notification_id",
            "notif_id",
            "id",
            "messageId",
            "message_id",
            "google.message_id",
            "gcm.message_id",
            "campaignId",
            "campaign_id",
            "provider",
            "actionId",
            "action_id",
            "actionLabel",
            "action_label",
            "expiresAt",
            "expires_at",
            "aps",
        ]

        var extraProperties: [String: Any] = [:]

        // Extract title/body from aps.alert (present when app is killed — APNs path)
        if let aps = stringKeyed["aps"] as? [String: Any] {
            if let alert = aps["alert"] as? [String: Any] {
                if let title = alert["title"] as? String, !title.isEmpty {
                    extraProperties["title"] = title
                }
                if let body = alert["body"] as? String, !body.isEmpty {
                    extraProperties["body"] = body
                }
            } else if let alertBody = aps["alert"] as? String, !alertBody.isEmpty {
                extraProperties["body"] = alertBody
            }
        }

        var properties = stringKeyed.filter { !reservedKeys.contains($0.key) }
        for (key, value) in extraProperties where properties[key] == nil {
            properties[key] = value
        }

        return FlashNotificationPayload(
            notificationId: notificationId,
            messageId: firstString(in: stringKeyed, keys: ["messageId", "message_id", "google.message_id", "gcm.message_id"]),
            campaignId: firstString(in: stringKeyed, keys: ["campaignId", "campaign_id"]),
            provider: firstString(in: stringKeyed, keys: ["provider"]),
            actionId: firstString(in: stringKeyed, keys: ["actionId", "action_id"]),
            actionLabel: firstString(in: stringKeyed, keys: ["actionLabel", "action_label"]),
            properties: properties
        )
    }

    private static func firstString(
        in values: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = values[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

public struct ExperimentAssignmentRequest: @unchecked Sendable {
    public let experimentId: String
    public let userId: String?
    public let deviceId: String?
    public let eventName: String?
    public let profile: [String: Any]?
    public let sessionProperties: [String: Any]?
    public let properties: [String: Any]?

    public init(
        experimentId: String,
        userId: String? = nil,
        deviceId: String? = nil,
        eventName: String? = nil,
        profile: [String: Any]? = nil,
        sessionProperties: [String: Any]? = nil,
        properties: [String: Any]? = nil
    ) {
        self.experimentId = experimentId
        self.userId = userId
        self.deviceId = deviceId
        self.eventName = eventName
        self.profile = profile
        self.sessionProperties = sessionProperties
        self.properties = properties
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["experimentId": experimentId]
        if let userId { object["userId"] = userId }
        if let deviceId { object["deviceId"] = deviceId }
        if let eventName { object["eventName"] = eventName }
        if let profile { object["profile"] = profile }
        if let sessionProperties { object["sessionProperties"] = sessionProperties }
        if let properties { object["properties"] = properties }
        return object
    }
}

public struct ExperimentAssignmentOptions: @unchecked Sendable {
    public let userId: String?
    public let deviceId: String?
    public let eventName: String?
    public let profile: [String: Any]?
    public let sessionProperties: [String: Any]?
    public let properties: [String: Any]?
    public let includeInternalProperties: Bool

    public init(
        userId: String? = nil,
        deviceId: String? = nil,
        eventName: String? = nil,
        profile: [String: Any]? = nil,
        sessionProperties: [String: Any]? = nil,
        properties: [String: Any]? = nil,
        includeInternalProperties: Bool = true
    ) {
        self.userId = userId
        self.deviceId = deviceId
        self.eventName = eventName
        self.profile = profile
        self.sessionProperties = sessionProperties
        self.properties = properties
        self.includeInternalProperties = includeInternalProperties
    }
}

public struct AutoExperimentAssignmentRequest: @unchecked Sendable {
    public let modes: [AutoExperimentAssignmentMode]?
    public let userId: String?
    public let deviceId: String?
    public let sessionId: String?
    public let profile: [String: Any]?
    public let sessionProperties: [String: Any]?
    public let properties: [String: Any]?

    public init(
        modes: [AutoExperimentAssignmentMode]? = nil,
        userId: String? = nil,
        deviceId: String? = nil,
        sessionId: String? = nil,
        profile: [String: Any]? = nil,
        sessionProperties: [String: Any]? = nil,
        properties: [String: Any]? = nil
    ) {
        self.modes = modes
        self.userId = userId
        self.deviceId = deviceId
        self.sessionId = sessionId
        self.profile = profile
        self.sessionProperties = sessionProperties
        self.properties = properties
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = [:]
        if let modes { object["modes"] = modes.map(\.rawValue) }
        if let userId { object["userId"] = userId }
        if let deviceId { object["deviceId"] = deviceId }
        if let sessionId { object["sessionId"] = sessionId }
        if let profile { object["profile"] = profile }
        if let sessionProperties { object["sessionProperties"] = sessionProperties }
        if let properties { object["properties"] = properties }
        return object
    }
}

public struct AutoExperimentAssignmentOptions: Sendable {
    // nil = no mode filter (API returns all experiments)
    public let modes: Set<AutoExperimentAssignmentMode>?
    public let includeInternalProperties: Bool

    public init(
        modes: Set<AutoExperimentAssignmentMode>? = nil,
        includeInternalProperties: Bool = true
    ) {
        self.modes = modes
        self.includeInternalProperties = includeInternalProperties
    }
}

public struct RemoteConfigContext: @unchecked Sendable {
    public let platform: String?
    public let appVersion: String?
    public let buildNumber: String?
    public let language: String?
    public let country: String?
    public let profileId: String?
    public let sessionId: String?
    public let randomSeed: String?
    public let userProperties: [String: Any]?

    public init(
        platform: String? = nil,
        appVersion: String? = nil,
        buildNumber: String? = nil,
        language: String? = nil,
        country: String? = nil,
        profileId: String? = nil,
        sessionId: String? = nil,
        randomSeed: String? = nil,
        userProperties: [String: Any]? = nil
    ) {
        self.platform = platform
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.language = language
        self.country = country
        self.profileId = profileId
        self.sessionId = sessionId
        self.randomSeed = randomSeed
        self.userProperties = userProperties
    }
}

struct RemoteConfigResponse: Codable, Sendable {
    let parameters: [String: JSONValue]?
}

public struct RemoteConfigSnapshot: @unchecked Sendable {
    public let parameters: [String: Any]

    public init(parameters: [String: Any] = [:]) {
        self.parameters = parameters
    }

    public func get(_ key: String) -> Any? {
        parameters[key]
    }

    public func getString(_ key: String, fallback: String = "") -> String {
        parameters[key] as? String ?? fallback
    }

    public func getBoolean(_ key: String, fallback: Bool = false) -> Bool {
        parameters[key] as? Bool ?? fallback
    }

    public func getNumber(_ key: String, fallback: Double = 0) -> Double {
        switch parameters[key] {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return fallback
        }
    }

    public func getJSON<T>(_ key: String, fallback: T) -> T {
        parameters[key] as? T ?? fallback
    }
}

public struct ExperimentAssignmentResponse: Codable, Equatable, Sendable {
    public let experimentId: String
    public let experimentName: String
    public let variantId: String
    public let variantName: String
    public let reason: AssignmentReason
    public let matchedRuleId: String?
    public let assignmentMode: AssignmentMode
    public let message: String?
    public let attribution: ExperimentAttribution
}

public struct AutoExperimentAssignmentResponse: Codable, Equatable, Sendable {
    public let assignments: [ExperimentAssignmentResponse]
}

public struct ExperimentAttribution: Codable, Equatable, Sendable {
    public let experimentId: String
    public let experimentName: String
    public let variantId: String
    public let variantName: String
}

public enum AssignmentReason: String, Codable, Sendable {
    case experimentInactive = "experiment_inactive"
    case fixedUserOverride = "fixed_user_override"
    case fixedDeviceOverride = "fixed_device_override"
    case manualUserList = "manual_user_list"
    case manualDeviceList = "manual_device_list"
    case criteriaMatch = "criteria_match"
    case randomAllocation = "random_allocation"
    case defaultFallback = "default_fallback"
}

public enum AssignmentMode: String, Codable, Sendable {
    case profile
    case session
    case event
}

public struct SessionInfo: Equatable, Sendable {
    public let id: String
    public let estimatedExpiresAt: Int
    public let estimatedTtlMs: Int

    public init(id: String, estimatedExpiresAt: Int, estimatedTtlMs: Int) {
        self.id = id
        self.estimatedExpiresAt = estimatedExpiresAt
        self.estimatedTtlMs = estimatedTtlMs
    }
}

struct TrackResponse: Codable, Sendable {
    let sessionId: String?
    let estimatedSessionTtlMs: Int?
    let estimatedSessionExpiresAt: Int?
}

struct TrackBatchResponse: Decodable, Sendable {
    let sessionId: String?
    let estimatedSessionTtlMs: Int?
    let estimatedSessionExpiresAt: Int?
    let results: [TrackResponse]?
}

public enum TrackHandlerPayload: @unchecked Sendable {
    case track(TrackPayload)
    case identify(IdentifyPayload)
    case increment(IncrementPayload)
    case decrement(DecrementPayload)

    var type: String {
        switch self {
        case .track:
            return "track"
        case .identify:
            return "identify"
        case .increment:
            return "increment"
        case .decrement:
            return "decrement"
        }
    }

    var envelope: [String: Any] {
        switch self {
        case let .track(payload):
            return ["type": type, "payload": payload.jsonObject]
        case let .identify(payload):
            return ["type": type, "payload": payload.jsonObject]
        case let .increment(payload):
            return ["type": type, "payload": payload.jsonObject]
        case let .decrement(payload):
            return ["type": type, "payload": payload.jsonObject]
        }
    }

    func backfilled(profileId: String?) -> TrackHandlerPayload {
        switch self {
        case let .track(payload) where payload.profileId == nil:
            return .track(TrackPayload(name: payload.name, properties: payload.properties, profileId: profileId))
        default:
            return self
        }
    }

    static func from(envelope: [String: Any]) -> TrackHandlerPayload? {
        guard let type = envelope["type"] as? String,
              let payloadDict = envelope["payload"] as? [String: Any] else { return nil }
        switch type {
        case "track":
            guard let name = payloadDict["name"] as? String else { return nil }
            return .track(TrackPayload(
                name: name,
                properties: payloadDict["properties"] as? [String: Any],
                profileId: payloadDict["profileId"] as? String
            ))
        case "identify":
            guard let profileId = payloadDict["profileId"] as? String else { return nil }
            return .identify(IdentifyPayload(
                profileId: profileId,
                sessionId: payloadDict["sessionId"] as? String,
                firstName: payloadDict["firstName"] as? String,
                lastName: payloadDict["lastName"] as? String,
                email: payloadDict["email"] as? String,
                avatar: payloadDict["avatar"] as? String,
                properties: payloadDict["properties"] as? [String: Any]
            ))
        case "increment":
            guard let profileId = payloadDict["profileId"] as? String,
                  let property = payloadDict["property"] as? String else { return nil }
            return .increment(IncrementPayload(
                profileId: profileId,
                property: property,
                value: payloadDict["value"] as? Double
            ))
        case "decrement":
            guard let profileId = payloadDict["profileId"] as? String,
                  let property = payloadDict["property"] as? String else { return nil }
            return .decrement(DecrementPayload(
                profileId: profileId,
                property: property,
                value: payloadDict["value"] as? Double
            ))
        default:
            return nil
        }
    }
}

extension RemoteConfigContext {
    func merging(with other: RemoteConfigContext) -> RemoteConfigContext {
        RemoteConfigContext(
            platform: other.platform ?? platform,
            appVersion: other.appVersion ?? appVersion,
            buildNumber: other.buildNumber ?? buildNumber,
            language: other.language ?? language,
            country: other.country ?? country,
            profileId: other.profileId ?? profileId,
            sessionId: other.sessionId ?? sessionId,
            randomSeed: other.randomSeed ?? randomSeed,
            userProperties: (userProperties ?? [:]).merging(other.userProperties ?? [:]) { _, new in new }
        )
    }

    var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []

        func append(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(URLQueryItem(name: name, value: value))
        }

        append("platform", platform)
        append("appVersion", appVersion)
        append("buildNumber", buildNumber)
        append("language", language)
        append("country", country)
        append("profileId", profileId)
        append("sessionId", sessionId)
        append("randomSeed", randomSeed)

        if let userProperties,
           !userProperties.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: JSONValue.normalize(dictionary: userProperties)),
           let json = String(data: data, encoding: .utf8) {
            items.append(URLQueryItem(name: "userProperties", value: json))
        }

        return items
    }
}
