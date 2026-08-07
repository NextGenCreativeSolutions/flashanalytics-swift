import Foundation

enum SdkEventRuleAction: String, Codable, Sendable {
    case allow
    case block
    case transform
}

struct SdkEventFilter: Codable, Sendable {
    let type: String
    let `operator`: String
    let value: JSONValue?
    let propertyName: String?
}

struct SdkEventRuleConfig: Codable, Sendable {
    let eventName: String?
    let action: SdkEventRuleAction?
    let clientIds: [String]?
    let enabled: Bool?
    let allowedProperties: [String]?
    let blockedProperties: [String]?
    let filters: [SdkEventFilter]?
}

struct SdkCollectionConfig: Codable, Sendable {
    let enabled: Bool
    let blockedProperties: [String]?
    let rules: [SdkEventRuleConfig]?
    let events: [String: SdkEventRuleConfig]?
}

struct SdkConfigResponse: Codable, Sendable {
    let version: String?
    let ttlSec: Int?
    let maxSessionTimeoutInMin: Int?
    let collection: SdkCollectionConfig?
}

private let internalPropertyPrefix = "__"
private let alwaysAllowedEvents: Set<String> = ["sdk_initialized", "sdk_heartbeat"]

private struct NormalizedSdkEventRule {
    let eventName: String
    let action: SdkEventRuleAction
    let clientIds: [String]
    let enabled: Bool
    let allowedProperties: [String]
    let blockedProperties: [String]
    let filters: [SdkEventFilter]
}

enum SdkCollectionDecision {
    case allowed([String: Any])
    case dropped(String)
}

func resolveLocalSdkCollection(
    allowEvents: [LocalSdkEventRule],
    blockEvents: [String],
    blockProperties: [String],
    eventName: String,
    properties: [String: Any]
) -> SdkCollectionDecision {
    if alwaysAllowedEvents.contains(eventName) {
        return .allowed(properties)
    }

    if blockEvents.contains(where: { matchesEventPattern($0, eventName: eventName) }) {
        return .dropped("event_blocked")
    }

    let allowRule = findBestLocalAllowRule(allowEvents, eventName: eventName)
    if !allowEvents.isEmpty, allowRule == nil {
        return .dropped("not_whitelisted")
    }

    let blocked = Set(blockProperties + (allowRule?.blockProperties ?? []))
    return .allowed(filterProperties(
        properties,
        allowed: allowRule?.allowProperties ?? [],
        blocked: blocked
    ))
}

func resolveSdkCollection(
    config: SdkCollectionConfig?,
    eventName: String,
    clientId: String,
    properties: [String: Any],
    context: RemoteConfigContext
) -> SdkCollectionDecision {
    if alwaysAllowedEvents.contains(eventName) {
        return .allowed(properties)
    }

    guard let config, config.enabled else {
        return .allowed(properties)
    }

    let activeRules = normalizeRules(config).filter(\.enabled)
    let clientRules = activeRules.filter { rule in
        rule.clientIds.isEmpty || rule.clientIds.contains(clientId)
    }
    let matchingRules = findMatchingRules(clientRules, eventName: eventName)

    if findBestRule(matchingRules.filter { $0.action == .block }, eventName: eventName) != nil {
        return .dropped("event_blocked")
    }

    let allowRule = findBestRule(matchingRules.filter { $0.action == .allow }, eventName: eventName)
    let hasAllowRules = clientRules.contains { $0.action == .allow }
    if allowRule == nil && hasAllowRules {
        return .dropped("not_whitelisted")
    }

    let transformRule = findBestRule(matchingRules.filter { $0.action == .transform }, eventName: eventName)
    let rule = allowRule ?? transformRule

    if let filters = rule?.filters, !filters.isEmpty,
       filters.allSatisfy({ evaluateFilter($0, context: context, properties: properties) }) {
        return .dropped("filter_matched")
    }

    let blocked = Set((config.blockedProperties ?? []) + (rule?.blockedProperties ?? []))
    return .allowed(filterProperties(
        properties,
        allowed: rule?.allowedProperties ?? [],
        blocked: blocked
    ))
}

private func normalizeRules(_ config: SdkCollectionConfig) -> [NormalizedSdkEventRule] {
    if let rules = config.rules, !rules.isEmpty {
        return rules.compactMap(normalizeRule)
    }

    return (config.events ?? [:]).compactMap { eventName, rule in
        normalizeRule(SdkEventRuleConfig(
            eventName: eventName,
            action: rule.action,
            clientIds: rule.clientIds,
            enabled: rule.enabled,
            allowedProperties: rule.allowedProperties,
            blockedProperties: rule.blockedProperties,
            filters: rule.filters
        ))
    }
}

private func normalizeRule(_ rule: SdkEventRuleConfig) -> NormalizedSdkEventRule? {
    guard let eventName = rule.eventName, !eventName.isEmpty else { return nil }
    return NormalizedSdkEventRule(
        eventName: eventName,
        action: rule.action ?? .transform,
        clientIds: rule.clientIds ?? [],
        enabled: rule.enabled ?? true,
        allowedProperties: rule.allowedProperties ?? [],
        blockedProperties: rule.blockedProperties ?? [],
        filters: rule.filters ?? []
    )
}

private func findMatchingRules(
    _ rules: [NormalizedSdkEventRule],
    eventName: String
) -> [NormalizedSdkEventRule] {
    rules.filter { rule in
        if rule.eventName == eventName {
            return true
        }
        guard rule.eventName.hasSuffix("*") else {
            return false
        }
        return eventName.hasPrefix(String(rule.eventName.dropLast()))
    }
}

private func findBestRule(
    _ rules: [NormalizedSdkEventRule],
    eventName: String
) -> NormalizedSdkEventRule? {
    if let exact = rules.first(where: { $0.eventName == eventName }) {
        return exact
    }

    return rules
        .filter { $0.eventName.hasSuffix("*") && eventName.hasPrefix(String($0.eventName.dropLast())) }
        .max { lhs, rhs in lhs.eventName.dropLast().count < rhs.eventName.dropLast().count }
}

private func findBestLocalAllowRule(
    _ rules: [LocalSdkEventRule],
    eventName: String
) -> LocalSdkEventRule? {
    if let exact = rules.first(where: { $0.name == eventName }) {
        return exact
    }

    return rules
        .filter { matchesEventPattern($0.name, eventName: eventName) }
        .max { lhs, rhs in lhs.name.dropLast().count < rhs.name.dropLast().count }
}

private func matchesEventPattern(_ pattern: String, eventName: String) -> Bool {
    if pattern == eventName {
        return true
    }
    guard pattern.hasSuffix("*") else {
        return false
    }
    return eventName.hasPrefix(String(pattern.dropLast()))
}

private func filterProperties(
    _ properties: [String: Any],
    allowed: [String],
    blocked: Set<String>
) -> [String: Any] {
    var result = allowed.isEmpty
        ? clonePlainValue(properties) as? [String: Any] ?? [:]
        : pickPropertyPaths(properties, paths: allowed)

    for (key, value) in properties {
        if key.hasPrefix(internalPropertyPrefix) {
            result[key] = clonePlainValue(value)
        }
    }

    for path in blocked {
        let segments = parsePropertyPath(path)
        if segments.first?.hasPrefix(internalPropertyPrefix) == true {
            continue
        }
        removePropertyPath(&result, segments: segments)
    }

    return result
}

private func parsePropertyPath(_ path: String) -> [String] {
    path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
}

private func clonePlainValue(_ value: Any) -> Any {
    if let array = value as? [Any] {
        return array.map(clonePlainValue)
    }
    if let dictionary = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, item) in dictionary {
            result[key] = clonePlainValue(item)
        }
        return result
    }
    return value
}

private func pickPropertyPaths(_ source: [String: Any], paths: [String]) -> [String: Any] {
    var result: [String: Any] = [:]
    for path in paths {
        copyPropertyPath(source: source, target: &result, segments: parsePropertyPath(path))
    }
    return result
}

private func copyPropertyPath(source: Any, target: inout Any, segments: [String]) {
    guard let segment = segments.first else { return }
    let rest = Array(segments.dropFirst())

    if segment == "*" {
        guard let sourceArray = source as? [Any], target is [Any] else { return }
        var targetArray = target as? [Any] ?? []
        for (index, item) in sourceArray.enumerated() {
            while targetArray.count <= index {
                targetArray.append([String: Any]())
            }
            if rest.isEmpty {
                targetArray[index] = clonePlainValue(item)
                continue
            }
            guard item is [String: Any] || item is [Any] else { continue }
            var nextTarget = targetArray[index]
            if nextTarget is NSNull {
                nextTarget = item is [Any] ? [Any]() : [String: Any]()
            }
            copyPropertyPath(source: item, target: &nextTarget, segments: rest)
            targetArray[index] = nextTarget
        }
        target = targetArray
        return
    }

    if let arrayIndex = parseArrayIndex(segment) {
        guard let sourceArray = source as? [Any], target is [Any], sourceArray.indices.contains(arrayIndex) else {
            return
        }
        var targetArray = target as? [Any] ?? []
        while targetArray.count <= arrayIndex {
            targetArray.append(NSNull())
        }
        let item = sourceArray[arrayIndex]
        if rest.isEmpty {
            targetArray[arrayIndex] = clonePlainValue(item)
            target = targetArray
            return
        }
        guard item is [String: Any] || item is [Any] else {
            target = targetArray
            return
        }
        var nextTarget = targetArray[arrayIndex]
        if nextTarget is NSNull {
            nextTarget = item is [Any] ? [Any]() : [String: Any]()
        }
        copyPropertyPath(source: item, target: &nextTarget, segments: rest)
        targetArray[arrayIndex] = nextTarget
        target = targetArray
        return
    }

    guard let sourceMap = source as? [String: Any],
          let sourceValue = sourceMap[segment],
          target is [String: Any] else {
        return
    }
    var targetMap = target as? [String: Any] ?? [:]
    if rest.isEmpty {
        targetMap[segment] = clonePlainValue(sourceValue)
        target = targetMap
        return
    }
    guard sourceValue is [String: Any] || sourceValue is [Any] else {
        target = targetMap
        return
    }
    var nextTarget = targetMap[segment] ?? (sourceValue is [Any] ? [Any]() : [String: Any]())
    copyPropertyPath(source: sourceValue, target: &nextTarget, segments: rest)
    targetMap[segment] = nextTarget
    target = targetMap
}

private func copyPropertyPath(source: Any, target: inout [String: Any], segments: [String]) {
    var boxed: Any = target
    copyPropertyPath(source: source, target: &boxed, segments: segments)
    target = boxed as? [String: Any] ?? target
}

private func removePropertyPath(_ target: inout Any, segments: [String]) {
    guard let segment = segments.first else { return }
    let rest = Array(segments.dropFirst())

    if segment == "*" {
        guard var array = target as? [Any] else { return }
        if rest.isEmpty {
            array.removeAll()
            target = array
            return
        }
        for index in array.indices {
            var item = array[index]
            removePropertyPath(&item, segments: rest)
            array[index] = item
        }
        target = array
        return
    }

    if let arrayIndex = parseArrayIndex(segment) {
        guard var array = target as? [Any], array.indices.contains(arrayIndex) else { return }
        if rest.isEmpty {
            array.remove(at: arrayIndex)
            target = array
            return
        }
        var item = array[arrayIndex]
        removePropertyPath(&item, segments: rest)
        array[arrayIndex] = item
        target = array
        return
    }

    guard var dictionary = target as? [String: Any] else { return }
    if rest.isEmpty {
        dictionary.removeValue(forKey: segment)
        target = dictionary
        return
    }
    guard var child = dictionary[segment] else { return }
    removePropertyPath(&child, segments: rest)
    dictionary[segment] = child
    target = dictionary
}

private func removePropertyPath(_ target: inout [String: Any], segments: [String]) {
    var boxed: Any = target
    removePropertyPath(&boxed, segments: segments)
    target = boxed as? [String: Any] ?? target
}

private func parseArrayIndex(_ segment: String) -> Int? {
    guard let index = Int(segment), index >= 0, String(index) == segment else {
        return nil
    }
    return index
}

private func evaluateFilter(
    _ filter: SdkEventFilter,
    context: RemoteConfigContext,
    properties: [String: Any]
) -> Bool {
    guard let subject = resolveFilterSubject(filter, context: context, properties: properties),
          let comparable = toComparable(subject) else {
        return false
    }

    let subjectText = String(describing: comparable)
    let value = filter.value?.toFoundationObject()

    switch filter.operator {
    case "equals":
        guard let value else { return false }
        return subjectText == String(describing: value)
    case "not_equals":
        guard let value else { return false }
        return subjectText != String(describing: value)
    case "contains":
        guard let text = filterValueText(value) else { return false }
        return subjectText.contains(text)
    case "in":
        guard let values = value as? [Any] else { return false }
        return values.map { String(describing: $0) }.contains(subjectText)
    case "not_in":
        guard let values = value as? [Any] else { return false }
        return !values.map { String(describing: $0) }.contains(subjectText)
    case "matches_regex":
        guard let pattern = filterValueText(value) else { return false }
        return subjectText.range(of: pattern, options: .regularExpression) != nil
    case "gt", "lt", "gte", "lte":
        let comparison = (filter.type == "app_version" || filter.type == "build_number")
            ? compareVersions(subjectText, String(describing: value ?? ""))
            : compareNumbers(comparable, value)
        guard let comparison else { return false }
        if filter.operator == "gt" { return comparison > 0 }
        if filter.operator == "lt" { return comparison < 0 }
        if filter.operator == "gte" { return comparison >= 0 }
        return comparison <= 0
    default:
        return false
    }
}

private func filterValueText(_ value: Any?) -> String? {
    guard let value else { return nil }
    return String(describing: value)
}

private func resolveFilterSubject(
    _ filter: SdkEventFilter,
    context: RemoteConfigContext,
    properties: [String: Any]
) -> Any? {
    switch filter.type {
    case "platform":
        return context.platform
    case "app_version":
        return context.appVersion
    case "build_number":
        return context.buildNumber
    case "language":
        return context.language
    case "country":
        return context.country
    case "user_property":
        guard let propertyName = filter.propertyName else { return nil }
        return context.userProperties?[propertyName]
    case "event_property":
        guard let propertyName = filter.propertyName else { return nil }
        return properties[propertyName]
    default:
        return nil
    }
}

private func toComparable(_ value: Any) -> Any? {
    switch value {
    case let string as String:
        return string
    case let bool as Bool:
        return String(bool)
    case let number as NSNumber:
        return number.doubleValue
    case let int as Int:
        return Double(int)
    case let double as Double:
        return double
    case let float as Float:
        return Double(float)
    default:
        return nil
    }
}

private func compareNumbers(_ lhs: Any, _ rhs: Any?) -> Int? {
    guard let left = numberValue(lhs), let right = rhs.flatMap(numberValue) else {
        return nil
    }
    if left == right { return 0 }
    return left > right ? 1 : -1
}

private func numberValue(_ value: Any) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let int as Int:
        return Double(int)
    case let double as Double:
        return double
    case let float as Float:
        return Double(float)
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
    let count = max(left.count, right.count)

    for index in 0..<count {
        let diff = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
        if diff != 0 {
            return diff > 0 ? 1 : -1
        }
    }
    return 0
}
