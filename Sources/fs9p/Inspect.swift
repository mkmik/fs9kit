import Foundation
import NineP
import NinePClient
import FS9Core

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Commands that read a 9P server without mounting it.
///
/// These exist because the first question when a mount misbehaves is always
/// "is it the mount, or is it the server?", and the fastest way to answer that
/// is to talk to the server directly.
enum Inspect {
    static func ls(_ arguments: Arguments) async throws {
        try arguments.rejectUnknown(ConnectionOptions.flagNames.union(["long", "all"]))
        guard arguments.positional.count >= 1 else {
            throw CLIError("usage: fs9p ls <address> [path]")
        }
        let options = try ConnectionOptions(address: arguments.positional[0], arguments: arguments)
        let path = arguments.positional.count > 1 ? arguments.positional[1] : "/"

        let vfs = try await options.openVFS()
        defer { Task { await vfs.shutdown() } }

        let (node, attrs) = try await vfs.resolve(path)
        guard attrs.type == .directory else {
            try await printEntry(vfs: vfs, name: path, node: node, attrs: attrs,
                                 long: arguments.has("long"))
            return
        }
        let entries = try await vfs.readDirectoryAll(node)
        for entry in entries.sorted(by: { $0.name < $1.name }) {
            if !arguments.has("all") && entry.name.hasPrefix(".") { continue }
            if arguments.has("long") {
                let a = try await vfs.getAttributes(entry.node)
                try await printEntry(vfs: vfs, name: entry.name, node: entry.node,
                                     attrs: a, long: true)
            } else {
                print(entry.name + (entry.type == .directory ? "/" : ""))
            }
        }
    }

    private static func printEntry(
        vfs: NineVFS, name: String, node: NodeID, attrs: FileAttributes, long: Bool
    ) async throws {
        guard long else { print(name); return }
        var line = String(format: "%@ %3u %5u %5u %8@ %@ %@",
                          modeString(attrs), attrs.linkCount, attrs.uid, attrs.gid,
                          humanSize(attrs.size) as NSString,
                          formatTime(attrs.modifyTime), name)
        if attrs.type == .symlink, let target = try? await vfs.readlink(node) {
            line += " -> \(target)"
        }
        print(line)
    }

    static func cat(_ arguments: Arguments) async throws {
        try arguments.rejectUnknown(ConnectionOptions.flagNames)
        guard arguments.positional.count >= 2 else {
            throw CLIError("usage: fs9p cat <address> <path>")
        }
        let options = try ConnectionOptions(address: arguments.positional[0], arguments: arguments)
        let vfs = try await options.openVFS()
        defer { Task { await vfs.shutdown() } }

        let (node, attrs) = try await vfs.resolve(arguments.positional[1])
        guard attrs.type != .directory else { throw CLIError("that is a directory") }

        // Stream rather than buffering: a file on the far end may be larger
        // than this process wants to hold.
        var offset: UInt64 = 0
        let chunkSize = vfs.preferredIOSize
        while true {
            let chunk = try await vfs.read(node, offset: offset, count: chunkSize)
            if chunk.isEmpty { break }
            FileHandle.standardOutput.write(Data(chunk))
            offset += UInt64(chunk.count)
        }
    }

    static func stat(_ arguments: Arguments) async throws {
        try arguments.rejectUnknown(ConnectionOptions.flagNames)
        guard arguments.positional.count >= 1 else {
            throw CLIError("usage: fs9p stat <address> [path]")
        }
        let options = try ConnectionOptions(address: arguments.positional[0], arguments: arguments)
        let client = try await options.connect()
        let vfs = NineVFS(client: client, options: VFSOptions(attributeCacheDuration: 0))
        defer { Task { await vfs.shutdown() } }

        let path = arguments.positional.count > 1 ? arguments.positional[1] : "/"
        let (node, attrs) = try await vfs.resolve(path)

        print("path:        \(path)")
        print("dialect:     \(client.version.rawValue)")
        print("type:        \(attrs.type)")
        print("mode:        \(modeString(attrs)) (\(String(attrs.permissions, radix: 8)))")
        print("uid/gid:     \(attrs.uid)/\(attrs.gid)")
        print("size:        \(attrs.size) (\(humanSize(attrs.size)))")
        print("links:       \(attrs.linkCount)")
        print("fileID:      \(attrs.fileID)")
        print("accessed:    \(formatTime(attrs.accessTime))")
        print("modified:    \(formatTime(attrs.modifyTime))")
        print("changed:     \(formatTime(attrs.changeTime))")
        if attrs.type == .symlink, let target = try? await vfs.readlink(node) {
            print("target:      \(target)")
        }
        let stats = try await vfs.statfs()
        print("volume:      \(stats.totalBlocks) blocks of \(stats.blockSize)B, "
            + "\(stats.availableBlocks) available")
        print("max io:      \(client.ioSize) bytes per message")
    }

    static func tree(_ arguments: Arguments) async throws {
        try arguments.rejectUnknown(ConnectionOptions.flagNames.union(["depth"]))
        guard arguments.positional.count >= 1 else {
            throw CLIError("usage: fs9p tree <address> [path]")
        }
        let options = try ConnectionOptions(address: arguments.positional[0], arguments: arguments)
        let vfs = try await options.openVFS()
        defer { Task { await vfs.shutdown() } }

        let path = arguments.positional.count > 1 ? arguments.positional[1] : "/"
        let (root, _) = try await vfs.resolve(path)
        try await walk(vfs: vfs, node: root, prefix: "", depth: arguments.int("depth") ?? 8)
    }

    private static func walk(vfs: NineVFS, node: NodeID, prefix: String, depth: Int) async throws {
        guard depth > 0 else { return }
        let entries = try await vfs.readDirectoryAll(node).sorted { $0.name < $1.name }
        for (index, entry) in entries.enumerated() {
            let last = index == entries.count - 1
            print(prefix + (last ? "└── " : "├── ") + entry.name
                + (entry.type == .directory ? "/" : ""))
            if entry.type == .directory {
                try await walk(vfs: vfs, node: entry.node,
                               prefix: prefix + (last ? "    " : "│   "), depth: depth - 1)
            }
        }
    }
}
