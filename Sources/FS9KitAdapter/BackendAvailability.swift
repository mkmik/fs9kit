import Foundation

/// Whether the FSKit half of this module was compiled into the build.
///
/// The glue can only be built against the macOS 26 SDK, so on Linux and on
/// older macOS it is compiled out and the module contains only the translation
/// logic. That is intentional, but it is also invisible — a build with no FSKit
/// backend in it looks exactly like one that has it — so the fact is recorded
/// here, asserted by the tests, and printed by `fs9p doctor`.
public enum FSKitBackend {
    #if canImport(FSKit) && compiler(>=6.2)
    public static let isCompiledIn = true
    #else
    public static let isCompiledIn = false
    #endif

    /// Why it is absent, for a diagnostic message.
    public static var absenceReason: String? {
        guard !isCompiledIn else { return nil }
        #if !canImport(FSKit)
        return "FSKit is not available on this platform"
        #else
        return "built against an SDK older than macOS 26, which has no FSGenericURLResource"
        #endif
    }
}
