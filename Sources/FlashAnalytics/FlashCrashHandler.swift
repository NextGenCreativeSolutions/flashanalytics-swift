import Foundation

/// Installs native crash handlers (ObjC exceptions + POSIX signals) and persists
/// crash reports to disk so they can be reported on the next app launch.
internal enum FlashCrashHandler {

    struct CrashReport {
        let errorClass: String
        let message: String
        let stackTrace: String
        let type: String
        let timestamp: TimeInterval
    }

    // ── Public API ────────────────────────────────────────────────────────────

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        installExceptionHandler()
        installSignalHandlers()
    }

    static func consumePending() -> [CrashReport] {
        guard let data = try? Data(contentsOf: crashFileURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        try? FileManager.default.removeItem(at: crashFileURL)
        return array.compactMap(CrashReport.init)
    }

    // ── State ─────────────────────────────────────────────────────────────────

    nonisolated(unsafe) private static var isInstalled = false
    nonisolated(unsafe) private static var previousExceptionHandler: NSUncaughtExceptionHandler?

    // ── File storage ──────────────────────────────────────────────────────────

    private static let crashFileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("flash_pending_crashes.json")
    }()

    private static func append(_ entry: [String: Any]) {
        var existing: [[String: Any]] = []
        if let data = try? Data(contentsOf: crashFileURL),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            existing = decoded
        }
        existing.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: existing) {
            try? data.write(to: crashFileURL)
        }
    }

    // ── Exception handler ─────────────────────────────────────────────────────

    private static func installExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            FlashCrashHandler.append([
                "errorClass": exception.name.rawValue,
                "message":    exception.reason ?? "",
                "stackTrace": exception.callStackSymbols.joined(separator: "\n"),
                "type":       "ios_exception",
                "timestamp":  Date().timeIntervalSince1970 * 1000,
            ])
            FlashCrashHandler.previousExceptionHandler?(exception)
        }
    }

    // ── Signal handlers ───────────────────────────────────────────────────────

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE]
        for sig in signals {
            signal(sig) { received in
                let name: String
                switch received {
                case SIGABRT: name = "SIGABRT"
                case SIGILL:  name = "SIGILL"
                case SIGSEGV: name = "SIGSEGV"
                case SIGFPE:  name = "SIGFPE"
                case SIGBUS:  name = "SIGBUS"
                case SIGPIPE: name = "SIGPIPE"
                default:      name = "SIG\(received)"
                }
                FlashCrashHandler.append([
                    "errorClass": name,
                    "message":    "Fatal signal \(name) received",
                    "stackTrace": Thread.callStackSymbols.joined(separator: "\n"),
                    "type":       "native_signal",
                    "timestamp":  Date().timeIntervalSince1970 * 1000,
                ])
                // Restore default and re-raise so the OS gets the real crash.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}

private extension FlashCrashHandler.CrashReport {
    init?(_ dict: [String: Any]) {
        guard let errorClass = dict["errorClass"] as? String else { return nil }
        self.errorClass = errorClass
        self.message    = dict["message"]    as? String ?? ""
        self.stackTrace = dict["stackTrace"] as? String ?? ""
        self.type       = dict["type"]       as? String ?? "ios_exception"
        self.timestamp  = dict["timestamp"]  as? TimeInterval ?? 0
    }
}
