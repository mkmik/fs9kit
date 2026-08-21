// Compiled only where the macOS 26 SDK is in play; see FS9UnaryFileSystem.swift
// for why the gate is spelled this way.
#if canImport(FSKit) && compiler(>=6.2)
import Foundation

/// Re-labels one of FSKit's reply handlers as `@Sendable`.
///
/// Every operation in `FSVolume.Operations` hands us a completion closure and
/// expects it to be called exactly once when the work is done. Ours is done
/// inside a `Task`, because the layers underneath are `async` — but FSKit does
/// not annotate the closures `@Sendable`, so handing one to a task is a
/// concurrency error, and `@preconcurrency` on the import does not excuse it:
/// the diagnostic is about *sending* the closure, not about its type.
///
/// The safety argument is FSKit's own contract rather than the type system's:
/// the handler is called once, from whichever thread finishes the work, which
/// is exactly what the framework is waiting for. Wrapping it makes that promise
/// explicit and keeps it in one place instead of at every call site.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

func sendable(_ body: @escaping () -> Void) -> @Sendable () -> Void {
    let box = UncheckedBox(value: body)
    return { box.value() }
}

func sendable<A>(_ body: @escaping (A) -> Void) -> @Sendable (A) -> Void {
    let box = UncheckedBox(value: body)
    return { box.value($0) }
}

func sendable<A, B>(_ body: @escaping (A, B) -> Void) -> @Sendable (A, B) -> Void {
    let box = UncheckedBox(value: body)
    return { box.value($0, $1) }
}

func sendable<A, B, C>(_ body: @escaping (A, B, C) -> Void) -> @Sendable (A, B, C) -> Void {
    let box = UncheckedBox(value: body)
    return { box.value($0, $1, $2) }
}
#endif
