// Compiled only when FS9KIT_FSKIT is defined, which the Xcode project sets and
// SwiftPM does not.
//
// `canImport(FSKit)` is not a strong enough gate: the framework exists in the
// macOS 15.4 SDK too, but there it has no FSGenericURLResource — the class that
// makes it possible to mount something with no block device behind it — and its
// protocol reply handlers are not Sendable. Compiling this against that SDK
// fails on both counts. The whole backend needs macOS 26 or later, so it is
// gated on a flag the macOS 26 build turns on rather than on the framework
// merely being present.
#if FS9KIT_FSKIT && canImport(FSKit)
import Foundation
// FSKit's protocol reply handlers are not `@Sendable`, so a witness that
// declares them `@Sendable` does not satisfy the requirement — which then makes
// the whole type fail to conform, and the extension entry point fail its
// associated-type constraint. The handlers are therefore spelled exactly as the
// framework spells them, and the import is `@preconcurrency` so that capturing
// one in a Task is a warning about Apple's annotations rather than an error in
// ours.
@preconcurrency import FSKit
import os
import FS9Core
import NineP
import NinePClient

/// The FSKit module itself: it turns the URL `mount(8)` was given into a live
/// 9P session and hands FSKit a volume.
///
/// The lifecycle it participates in, from `mount -F -t fs9kit 9p://… /Volumes/x`:
///
///  1. `mount(8)` finds the module by `FSShortName`, refuses if the user has
///     not enabled it, and builds an `FSGenericURLResource` because the
///     `Info.plist` says `FSSupportsGenericURLResources`.
///  2. **`probeResource` is skipped.** `fskitd` only probes block-device and
///     path-URL resources, so the checks a probe would do have to happen in
///     `loadResource`.
///  3. `loadResource` dials the server, attaches, and replies with an
///     `FS9Volume`.
///  4. `activate` returns the root item; the kernel mounts it.
///
/// Two undocumented rules govern step 3 and both cost a day to rediscover:
/// `containerStatus` must already be `.ready` when the reply is made, and it
/// must *not* be set to `.active` by hand — FSKit does that transition itself
/// and complains about an "unexpected container state" otherwise.
@available(macOS 26.0, *)
@objc(FS9UnaryFileSystem)
public final class FS9UnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {

    /// One instance for the whole extension process. The extension entry point
    /// is asked for `fileSystem` more than once and `containerStatus` is state
    /// that has to survive between those calls.
    public static let shared = FS9UnaryFileSystem()

    private let lock = NSLock()
    private var loadedVolume: FS9Volume?

    public override init() { super.init() }

    // MARK: - Probe

    /// Never called for a `9p://` mount — see the class comment — but a
    /// required protocol member, and it is what would run if the module were
    /// ever handed a path or block resource.
    public func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let url = Self.url(of: resource),
              let spec = try? MountSpec.parse(url.absoluteString) else {
            return reply(.notRecognized, nil)
        }
        // The container identifier must be identical here and on the volume, or
        // `loadResource` fails with EAGAIN: `fskitd` treats an identifier it
        // has not seen as an unknown container and closes it immediately.
        containerStatus = .ready
        reply(.usable(name: spec.volumeName, containerID: Self.containerID(for: spec)), nil)
    }

    // MARK: - Load

    public func loadResource(
        resource: FSResource, options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let url = Self.url(of: resource) else {
            Logger.fs9kit.error("loadResource: resource carries no URL")
            return reply(nil, fs9Error(errno: EINVAL))
        }

        let spec: MountSpec
        do {
            var parsed = try MountSpec.parse(url.absoluteString)
            // `mount -o ro` never reaches the URL, so fold the task options in.
            // Read-only can only be turned on this way, never off: a mount the
            // user asked to be read-only must not become writable because the
            // URL said `rw`.
            if Self.readOnlyRequested(in: options) { parsed.readOnly = true }
            spec = parsed
        } catch {
            Logger.fs9kit.error("loadResource: \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
            return reply(nil, fs9Error(error))
        }

        // Probe never ran, so this is the first and last chance to be `.ready`.
        containerStatus = .ready

        Task { [self] in
            do {
                let client = try await NinePClient.connect(
                    to: spec.endpoint,
                    credentials: spec.makeCredentials(),
                    options: spec.makeSessionOptions())
                let vfs = NineVFS(client: client, options: spec.makeVFSOptions())
                // Everything that can fail happens here, before the volume
                // exists: a throw out of `activate` wedges the resource URL
                // until `fskitd` is killed (FB24419932), and a bad host or a
                // refused attach is exactly the ordinary case.
                let statistics = (try? await vfs.statfs()) ?? FilesystemStats(
                    blockSize: 4096, totalBlocks: 0, freeBlocks: 0, availableBlocks: 0,
                    totalFiles: 0, freeFiles: 0, maximumNameLength: 255)
                let volume = FS9Volume(
                    volumeID: FSVolume.Identifier(uuid: StableUUID.uuid(for: spec.canonicalTarget)),
                    spec: spec, vfs: vfs, statistics: statistics)
                lock.withLock { loadedVolume = volume }
                Logger.fs9kit.info(
                    "attached \(spec.canonicalTarget, privacy: .public) as \(vfs.protocolVersion.rawValue, privacy: .public)")
                // Do NOT set containerStatus = .active here. FSKit moves the
                // container from notReady to active itself when this reply is
                // delivered, and setting it by hand is reported as an
                // unexpected container state.
                reply(volume, nil)
            } catch {
                Logger.fs9kit.error(
                    "attach to \(spec.canonicalTarget, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                containerStatus = .ready
                reply(nil, fs9Error(error))
            }
        }
    }

    public func unloadResource(
        resource: FSResource, options: FSTaskOptions,
        replyHandler reply: @escaping ((any Error)?) -> Void
    ) {
        // Reset to `.ready`, or mounting the same URL again fails with
        // "Resource busy" ("resource state is 5") until `fskitd` is killed —
        // FB24419932, and the usual trigger is one failed mount attempt.
        containerStatus = .ready
        lock.withLock { loadedVolume = nil }
        reply(nil)
    }

    public func didFinishLoading() {
        Logger.fs9kit.info("fs9kit module loaded")
    }

    // MARK: - Helpers

    /// The URL a resource carries.
    ///
    /// `FSGenericURLResource.url` is public on macOS 26, so the cast covers the
    /// supported path. The KVC fallback exists because `mount(8)` will hand
    /// over an `FSServerURLResource` — a private class with the same `url`
    /// property — if a future `Info.plist` ever sets `FSSupportsServerURLs`,
    /// and asking by selector cannot crash if it does not.
    static func url(of resource: FSResource) -> URL? {
        if let resource = resource as? FSGenericURLResource { return resource.url }
        if let resource = resource as? FSPathURLResource { return resource.url }
        if resource.responds(to: NSSelectorFromString("url")) {
            return (resource as AnyObject).value(forKey: "url") as? URL
        }
        return nil
    }

    /// A container identifier that is a pure function of the mount target.
    static func containerID(for spec: MountSpec) -> FSContainerIdentifier {
        FSContainerIdentifier(uuid: StableUUID.uuid(for: spec.canonicalTarget))
    }

    /// `mount(8)` passes `-o` through verbatim; `ro` and `rdonly` are the
    /// spellings it itself recognises for a read-only mount.
    static func readOnlyRequested(in options: FSTaskOptions) -> Bool {
        for option in options.taskOptions {
            let fields = Set(option.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init))
            if fields.contains("ro") || fields.contains("rdonly") { return true }
        }
        return false
    }
}

/// The extension's principal type.
///
/// `@main` cannot live in a library, so the extension target carries a
/// six-line file that declares `@main` and returns this file system; see
/// `macos/FS9KitExtension/FS9KitExtensionMain.swift`.
@available(macOS 26.0, *)
public struct FS9FileSystemExtension: UnaryFileSystemExtension {
    public init() {}
    public var fileSystem: FS9UnaryFileSystem { FS9UnaryFileSystem.shared }
}
#endif
