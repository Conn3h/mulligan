import os

/// One logger per subsystem area. Anything that is not the user's spoken text is logged
/// with `privacy: .public`, so the unified log is readable when diagnosing a problem.
/// Transcript text is never logged; log its length instead.
enum Log {
    private static let subsystem = "com.conn3h.sotto"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let speech = Logger(subsystem: subsystem, category: "speech")
    static let inject = Logger(subsystem: subsystem, category: "inject")
    static let dictionary = Logger(subsystem: subsystem, category: "dictionary")
    static let history = Logger(subsystem: subsystem, category: "history")
}
