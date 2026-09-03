// The full stack the tests drive: an in-process 9P server over loopback TCP, a
// 9P client, the VFS, and the NFS bridge in front of it.
//
// Nothing below the NFS layer is mocked, on purpose. The bugs this backend is
// prone to — cookie accounting, wcc data, handle staleness — only appear when
// a real directory listing and a real 9P round trip are involved.
//
// Tests use it as a value with a `defer`, rather than a closure taking a body,
// so that assertions stay in the test function itself: `#expect(try await …)`
// cannot be written inside a closure literal whose effects Swift has to infer.

import Foundation
import FS9Core
import FS9NFS
import NineP
import NinePClient
import NinePServer

final class TestBridge: @unchecked Sendable {
    let fileSystem: MemoryFileSystem
    let nineServer: NinePServer
    let nineClient: NinePClient
    let vfs: NineVFS
    let bridge: NFSBridge
    let port: UInt16
    /// A connected NFS client that has already completed MOUNT.
    let client: NFSTestClient
    /// The root file handle MOUNT returned.
    let root: [UInt8]

    private var extraClients: [NFSTestClient] = []

    private init(fileSystem: MemoryFileSystem, nineServer: NinePServer, nineClient: NinePClient,
                 vfs: NineVFS, bridge: NFSBridge, port: UInt16,
                 client: NFSTestClient, root: [UInt8]) {
        self.fileSystem = fileSystem
        self.nineServer = nineServer
        self.nineClient = nineClient
        self.vfs = vfs
        self.bridge = bridge
        self.port = port
        self.client = client
        self.root = root
    }

    /// Brings the whole stack up and mounts the export.
    static func start(readOnly: Bool = false, exportPath: String = "/") async throws -> TestBridge {
        let fileSystem = MemoryFileSystem()
        let nineServer = NinePServer(fileSystem: fileSystem)
        try nineServer.start()
        guard let ninePort = nineServer.boundPort else {
            throw RPCTestError.malformed("the 9P server did not report a port")
        }
        let nineClient = try await NinePClient.connect(to: .tcp(host: "127.0.0.1", port: ninePort))
        // Attribute caching is off so a test that writes and reads attributes
        // back is testing the bridge, not the cache.
        let vfs = NineVFS(client: nineClient,
                          options: VFSOptions(attributeCacheDuration: 0, readOnly: readOnly))
        let bridge = NFSBridge(
            vfs: vfs,
            options: NFSBridgeOptions(export: NFSExportOptions(path: exportPath), port: 0))
        let port = try bridge.start()

        let client = NFSTestClient(connection: try RPCTestConnection(
            port: port,
            credentials: AuthSysCredentials(stamp: 1, machineName: "fs9kit-test",
                                            uid: 0, gid: 0, groups: [0])))
        let mounted = try await client.mountRoot(path: exportPath)
        guard mounted.status == 0 else {
            throw RPCTestError.malformed("MOUNT failed with status \(mounted.status)")
        }
        return TestBridge(fileSystem: fileSystem, nineServer: nineServer, nineClient: nineClient,
                          vfs: vfs, bridge: bridge, port: port,
                          client: client, root: mounted.handle)
    }

    /// Opens another TCP connection to the bridge, tracked so it is closed at
    /// teardown rather than leaking a socket.
    func connect(credentials: AuthSysCredentials? = AuthSysCredentials(
        stamp: 1, machineName: "fs9kit-test", uid: 0, gid: 0, groups: [0]),
        receiveBufferSize: Int32? = nil
    ) throws -> NFSTestClient {
        let extra = NFSTestClient(connection: try RPCTestConnection(
            port: port, credentials: credentials, receiveBufferSize: receiveBufferSize))
        extraClients.append(extra)
        return extra
    }

    /// Another connection, in pipelined mode: many requests may be in flight
    /// on it at once, the way the kernel's client drives one.
    func connectPipelined() throws -> NFSTestClient {
        let extra = try connect()
        extra.connection.startPipelining()
        return NFSTestClient(connection: extra.connection, pipelined: true)
    }

    /// Tears everything down. Synchronous so it can be used from `defer`, and
    /// idempotent so a test may also call it explicitly.
    func tearDown() {
        for extra in extraClients { extra.connection.close() }
        extraClients.removeAll()
        client.connection.close()
        bridge.stop()
        // Closing the 9P session releases every fid the VFS holds; the actor's
        // own `shutdown()` is async and cannot be awaited from `defer`.
        nineClient.close()
        nineServer.stop()
    }
}
