@preconcurrency import FSKit
import FS9KitAdapter

/// The extension's entry point.
///
/// This is the whole of the extension target: everything else lives in the
/// `FS9KitAdapter` SwiftPM library, which is also what the unit tests build
/// against. `@main` cannot live in a library, which is the only reason this
/// file exists.
@main
struct FS9KitExtensionMain: UnaryFileSystemExtension {
    /// One file system object for the process, not one per access:
    /// `containerStatus` is state that has to survive between `loadResource`
    /// and `unloadResource`.
    var fileSystem: FS9UnaryFileSystem { .shared }
}
