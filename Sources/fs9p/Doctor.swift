import Foundation
import FS9NFS

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Reports which mount backends this machine can actually use.
///
/// The two backends fail in very different ways — one wants `sudo`, the other
/// wants an app installed and a switch flipped in System Settings — and neither
/// failure is self-explanatory when it happens mid-mount. This answers the
/// question up front.
enum Doctor {
    static func run(_ arguments: Arguments) {
        print("fs9p \(fs9pVersion)")
        print("")
        reportPlatform()
        print("")
        reportNFSBackend()
        print("")
        reportFSKitBackend()
    }

    private static func check(_ ok: Bool?, _ label: String, detail: String = "") {
        let mark = switch ok {
        case .some(true): "  ok "
        case .some(false): " no  "
        case nil: "  ?  "
        }
        print("[\(mark)] \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    private static func reportPlatform() {
        let info = ProcessInfo.processInfo.operatingSystemVersion
        #if canImport(Darwin)
        print("platform: macOS \(info.majorVersion).\(info.minorVersion).\(info.patchVersion) "
            + "on \(machineArchitecture())")
        #else
        print("platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("          the mount backends target macOS; this build can still serve, "
            + "inspect and test.")
        #endif
        print("user:     uid \(getuid()), euid \(geteuid())")
    }

    private static func machineArchitecture() -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        var size = buffer.count
        #if canImport(Darwin)
        if sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 {
            return String(cString: buffer)
        }
        #endif
        return "unknown"
    }

    // MARK: - NFS loopback

    private static func reportNFSBackend() {
        print("NFSv3 loopback backend (the default; works on macOS 11 and later)")
        let mountNFS = FileManager.default.isExecutableFile(atPath: NFSMountCommand.executable)
        check(mountNFS, "mount_nfs present", detail: NFSMountCommand.executable)

        if geteuid() == 0 {
            check(true, "privileges", detail: "running as root")
        } else {
            let sudo = FileManager.default.isExecutableFile(atPath: "/usr/bin/sudo")
            check(sudo, "sudo available",
                  detail: sudo ? "mounting will prompt for your password" : "mounting needs root")
        }

        let canBind = canBindLoopback()
        check(canBind, "can bind a loopback port")

        if mountNFS && canBind {
            print("       → this machine can mount with `fs9p mount`.")
        } else {
            print("       → not usable here.")
        }
    }

    private static func canBindLoopback() -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - FSKit

    private static func reportFSKitBackend() {
        print("FSKit backend (native; needs macOS 26 or later)")
        #if !canImport(Darwin)
        check(false, "macOS", detail: "not this platform")
        return
        #else
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let newEnough = version.majorVersion >= 26
        check(newEnough, "macOS 26 or later",
              detail: newEnough
                ? ""
                : "mounting a filesystem with no block device needs FSGenericURLResource, "
                  + "added in macOS 26")

        let framework = FileManager.default.fileExists(
            atPath: "/System/Library/Frameworks/FSKit.framework")
        check(framework, "FSKit.framework present")

        let daemon = FileManager.default.fileExists(atPath: "/usr/libexec/fskitd")
        check(daemon, "fskitd present")

        let app = FileManager.default.fileExists(atPath: "/Applications/FS9KitApp.app")
        check(app, "containing app installed", detail: "/Applications/FS9KitApp.app")

        let enabled = fskitModuleRegistered()
        check(enabled, "extension registered with pluginkit",
              detail: enabled == true
                ? "enable it in System Settings → General → Login Items & Extensions "
                  + "→ File System Extensions"
                : "build and run the app in macos/ first")

        if newEnough && framework && app && enabled == true {
            print("       → try: sudo mount -F -t fs9kit 9p://host:564/ /Volumes/nine")
        } else {
            print("       → not usable yet; see macos/README.md.")
        }
        #endif
    }

    /// Asks `pluginkit` whether anything claims the unary filesystem extension
    /// point. Registration is not the same as being *enabled* — only the user
    /// can do that, and there is no API to read it back — so this is a hint.
    private static func fskitModuleRegistered() -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/pluginkit") else { return nil }
        guard let result = try? Mount.execute(
            ["/usr/bin/pluginkit", "-m", "-p", "com.apple.fskit.unary", "-v"]) else { return nil }
        return result.outputText.lowercased().contains("fs9kit")
    }
}
