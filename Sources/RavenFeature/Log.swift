import os

/// This repo's `os.Logger` categories, all under the shared Ainkrad
/// subsystem so a user's whole install filters as one stream in Console.app.
///
/// The subsystem is spelled out here rather than taken from the SDK's
/// `AinkradLog` because this repo's AinkradAppKit pin (6cd1599) predates
/// that type. Switch to `AinkradLog.logger(app:area:)` whenever this pin
/// next moves forward.
enum Log {
    private static let subsystem = "com.ainkrad.app"
    static let imap = Logger(subsystem: subsystem, category: "raven.imap")
    static let smtp = Logger(subsystem: subsystem, category: "raven.smtp")
    static let sync = Logger(subsystem: subsystem, category: "raven.sync")
    static let store = Logger(subsystem: subsystem, category: "raven.store")
    static let auth = Logger(subsystem: subsystem, category: "raven.auth")
    static let mime = Logger(subsystem: subsystem, category: "raven.mime")
}
