import Foundation

/// Lightweight logging utility for RAVEN.
/// All output is compiled out in Release builds via `#if DEBUG`.
/// Usage: `RavenLog.debug("🚀 [App] Started")`
enum RavenLog {
    /// Print a debug message. No-op in Release builds.
    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        print(message())
        #endif
    }
}
