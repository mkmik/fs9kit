import Foundation
import NineP
import NinePServer

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs the bundled 9P server over a local directory.
///
/// Useful on its own, but mostly here so a macOS user can exercise a mount
/// without first finding a Linux box to serve from.
enum Serve {
    static func run(_ arguments: Arguments) throws {
        try arguments.rejectUnknown([
            "addr", "port", "unix", "read-only", "follow-symlinks", "msize", "version",
        ])
        guard let directory = arguments.positional.first else {
            throw CLIError("usage: fs9p serve <directory> [--port=N] [--read-only]")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir),
              isDir.boolValue else {
            throw CLIError("'\(directory)' is not a directory")
        }

        var options = LocalDirectoryFileSystem.Options()
        options.readOnly = arguments.has("read-only")
        options.followExternalSymlinks = arguments.has("follow-symlinks")
        let fileSystem = try LocalDirectoryFileSystem(root: directory, options: options)

        var configuration = NinePServerConfiguration()
        if let msize = arguments.int("msize") { configuration.maxMessageSize = UInt32(msize) }
        if let version = arguments.string("version") {
            guard let v = NinePVersion(rawValue: version) else {
                throw CLIError("unknown 9P version '\(version)'")
            }
            configuration.supportedVersions = [v]
        }
        var endpoints: [NinePEndpoint] = []
        if let path = arguments.string("unix") { endpoints.append(.unix(path: path)) }
        if let port = arguments.int("port") {
            endpoints.append(.tcp(host: arguments.string("addr") ?? "127.0.0.1", port: port))
        }
        if endpoints.isEmpty {
            endpoints = [.tcp(host: arguments.string("addr") ?? "127.0.0.1", port: P9.defaultPort)]
        }
        configuration.endpoints = endpoints

        let server = NinePServer(fileSystem: fileSystem, configuration: configuration)
        let bound = try server.start()
        for endpoint in bound {
            FileHandle.standardError.write(Data("serving \(directory) on \(endpoint)\n".utf8))
        }
        if options.readOnly {
            FileHandle.standardError.write(Data("(read-only)\n".utf8))
        }

        // Park until interrupted. The accept loops run on their own threads.
        installInterruptHandler { server.stop() }
        while !Interrupt.requested {
            Thread.sleep(forTimeInterval: 0.2)
        }
        server.stop()
        FileHandle.standardError.write(Data("stopped\n".utf8))
    }
}

/// A flag set from a signal handler.
///
/// Only `sig_atomic_t` writes are safe in a handler, so the handler sets a
/// global and the main thread polls it, rather than doing the teardown inline.
enum Interrupt {
    nonisolated(unsafe) static var flag: sig_atomic_t = 0
    static var requested: Bool { flag != 0 }
}

func installInterruptHandler(_ onStop: @escaping @Sendable () -> Void) {
    signal(SIGINT) { _ in Interrupt.flag = 1 }
    signal(SIGTERM) { _ in Interrupt.flag = 1 }
    // Keep a reference so the caller's cleanup is not optimised away.
    interruptCleanup = onStop
}

nonisolated(unsafe) private var interruptCleanup: (@Sendable () -> Void)?
