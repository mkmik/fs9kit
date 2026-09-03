# FSKit for a 9P network filesystem client

Research date: **2026-08-21**. Written for `fs9kit` — a 9P client that mounts on modern macOS
with **no kernel extension and no macFUSE**.

Every claim below carries a primary-source URL. Anything I could not verify from a primary
source is explicitly marked **UNCONFIRMED**.

Companion documents: [`mount-approaches.md`](./mount-approaches.md) (NFS-loopback alternative),
[`ci-feasibility.md`](./ci-feasibility.md), [`9p-protocol.md`](./9p-protocol.md).

---

## Bottom line

**Yes — a 9P network filesystem can be mounted through FSKit with no block device, on
macOS 26 (Tahoe) and later. It cannot be done on macOS 15.4–15.7.**

The mechanism is `FSGenericURLResource` (macOS 26.0+), an FSKit resource whose *only* content is
an arbitrary URL — "some sort of network address for a remote file system", in Apple's own words
([FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource)).
You declare the URL schemes you handle in `Info.plist` via `FSSupportedSchemes`, and the user
mounts with:

```sh
mount -F -t fs9kit 9p://server.example.com:564/aname /Volumes/fs9kit
```

`/sbin/mount` reads your extension's `Info.plist`, sees `FSSupportsGenericURLResources`, runs
`[NSURL URLWithString:argv[0]]` on the "device" argument and hands the resulting
`FSGenericURLResource` to your extension. This is not inference — it is literally what Apple's
open-source `mount(8)` does
([`disklib/fskit_support.m`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m)).

### Proof it works in the real world

| Project | What it mounts | Resource | Command |
|---|---|---|---|
| [`srz-zumix/jirafs`](https://github.com/srz-zumix/jirafs) | Jira / Confluence over HTTPS | `FSGenericURLResource` + `FSServerURLResource` | `sudo mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs/myinstance` |
| [Apple `PassthroughFS` sample](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system) (macOS 26) | An arbitrary directory | `FSPathURLResource` | `mount -t passthrough ~/Documents ~/passthrough-fs` |
| [macFUSE 5.2.0](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html) FSKit backend | anything FUSE, incl. `rclone`/`sshfs` remotes | (proxy appex) | `rclone mount -o backend=fskit …` |
| [An SMB 2/3 client as an FSKit module](https://developer.apple.com/forums/thread/842736) | SMB network shares | URL-backed volume | — |

Apple's March-2025 statement that *"Network file systems don't mount on `/dev` nodes and thus
aren't supported by FSKit"* ([thread 776322](https://developer.apple.com/forums/thread/776322))
is **obsolete**. It described FSKit as shipped in macOS 15.4.

### What is required on a user's machine

1. **macOS 26.0 or later.** (`FSGenericURLResource` is `macOS 26.0`; the `mount(8)` code path
   that constructs it first appears in `diskdev_cmds-751`, the macOS 26 line.)
2. **A containing `.app` that embeds your `.appex`**, installed where LaunchServices can see it
   (in practice `/Applications`). FSKit modules are app extensions; there is no standalone
   installer form.
3. **Code signing with a real identity.** The `com.apple.developer.fskit.fsmodule` entitlement is
   **not** a managed/approval-gated capability — Apple lists "FSKit Module" as available to
   *Apple Developer* (free), *Developer ID*, and *ADP* tiers
   ([Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)).
   Ad-hoc (`codesign -s -`) does **not** work unless the user boots with
   `amfi_get_out_of_my_way=1` (i.e. SIP down / Permissive Security).
4. **The user must enable the extension**: System Settings → General → Login Items & Extensions →
   File System Extensions → ⓘ → toggle it on. This is **per-user** and there is no supported
   system-wide or pre-login enablement
   ([thread 808594](https://developer.apple.com/forums/thread/808594)).
   `pluginkit -e use -i <bundleid>` works in practice as a CLI equivalent but is unofficial.
5. **SIP stays on. Notarization is the normal Gatekeeper requirement** for distribution outside
   the Mac App Store — nothing FSKit-specific.
6. **`sudo` for `mount -F`** in the URL-resource case (all real-world examples use it).

### Risks you should price in before committing

- **macOS 26-only.** No FSKit fallback exists for macOS 15.x. Keep the NFS-loopback backend from
  [`mount-approaches.md`](./mount-approaches.md) as the portable path.
- **Third-party FSKit modules have been reported broken on macOS 26.1/26.2**
  ([loaf#1](https://github.com/andrewgazelka/loaf/issues/1)). This is contradicted by projects
  shipping successfully in the same window, so it is likely environment-specific — but treat it
  as a real deployment hazard and test on the exact point releases you support.
- **Ten substantive FSKit bugs specific to network filesystems** were filed in August 2026
  ([thread 842736](https://developer.apple.com/forums/thread/842736)) — no byte-range locks, no
  ACLs, `synchronize(flags:)` never called on URL-backed volumes, permanently-cached negative
  lookups. See §6.
- The **`FSServerURLResource` / NetFS route is private API**. Use `FSGenericURLResource` (public)
  as the primary path.

---

## 1. API surface

### 1.1 How to read the version columns

FSKit's public debut is **macOS 15.4**. It was pulled from the final macOS 15.0 SDK
([Quinn, Oct 2024](https://developer.apple.com/forums/thread/765424)), so there is no FSKit on
15.0–15.3. Apple's framework landing page reports `introducedAt: 15.4`
(`https://developer.apple.com/tutorials/data/documentation/fskit.json`).

Three generations exist:

| Generation | macOS | Marker | Shape |
|---|---|---|---|
| V1 | 15.4 | `FSKIT_API_AVAILABILITY_V1` | `FSVolume.*Operations` protocols, block devices only |
| V2 | 26.0 | `FSKIT_API_AVAILABILITY_V2` | adds `FSPathURLResource`, `FSGenericURLResource` |
| V2.4 | 26.4 | `FSKIT_API_AVAILABILITY_V2_4` | adds `FSVolume.MountOptions` |
| V3 | 27.0 (beta) | `FSKIT_API_AVAILABILITY_V3` | `*Operations` → `*Handler` rewrite, `FSContext`, result objects, `DataCacheHandler` |

**All of the `FSVolume.*Operations` protocols are marked deprecated in macOS 27.0.** They still
work; V3 replaces them with `*Handler` equivalents that take an `FSContext` and return result
objects. Write against V1/V2 today and plan a V3 migration.

### 1.2 Class hierarchy

```
NSObject
├── FSFileSystem            (: FSFileSystemBase)   — multi-resource; NOT supported yet
├── FSUnaryFileSystem       (: FSFileSystemBase)   — one resource → one volume  [15.4]
├── FSVolume                                                                     [15.4]
├── FSItem                                                                       [15.4]
├── FSResource                                                                   [15.4]
│   ├── FSBlockDeviceResource                                                    [15.4]
│   ├── FSPathURLResource                                                        [26.0]
│   ├── FSGenericURLResource                                                     [26.0]
│   └── FSServerURLResource                              *** PRIVATE ***
├── FSEntityIdentifier                                                           [15.4]
│   ├── FSContainerIdentifier                                                    [15.4]
│   └── FSVolume.Identifier                                                      [15.4]
├── FSContainerStatus                                                            [15.4]
├── FSProbeResult                                                                [15.4]
├── FSStatFSResult                                                               [15.4]
├── FSVolume.SupportedCapabilities                                               [15.4]
├── FSItem.Attributes                                                            [15.4]
│   └── FSItem.SetAttributesRequest                                              [15.4]
├── FSItem.GetAttributesRequest                                                  [15.4]
├── FSDirectoryEntryPacker                                                       [15.4]
├── FSExtentPacker                                                               [15.4]
├── FSMutableFileDataBuffer                                                      [15.4]
├── FSFileName                                                                   [15.4]
├── FSMetadataRange                                                              [15.4]
├── FSTask                                                                       [15.4]
├── FSTaskOptions                                                                [15.4]
├── FSModuleIdentity                                                             [15.4]
├── FSClient                                                                     [15.4]
└── FSContext                                                                    [27.0 beta]
```

macOS 27 beta additionally introduces a family of result objects — `FSActivateResult`,
`FSLookupItemResult`, `FSCreateItemResult`, `FSReadFileResult`, `FSWriteFileResult`,
`FSGetAttributesResult`, `FSSetAttributesResult`, `FSEnumerateDirectoryResult`,
`FSOpenItemResult`, `FSRemoveItemResult`, `FSRenameItemResult`, `FSGetXattrResult`,
`FSSetXattrResult`, `FSListXattrsResult`, `FSPreallocateResult`, `FSSeekRegionResult`,
`FSBlockmapResult`, `FSCompleteIOResult`, `FSCheckAccessResult`, `FSDeactivateItemResult`,
`FSUpgradeItemResult`, `FSVolumeRenameResult`, `FSCreateLinkResult`, `FSCreateSymlinkResult`,
`FSReadSymlinkResult`, `FSVolumeHandlerResult`, `FSFreeSpace`, `FSCreateFileKOIOResult`,
`FSLookupItemKOIOResult`, `FSPreallocateKOIOResult` — plus `FSDataCacheError`.

> **Note on `FSMaintenanceOperations`.** No such symbol exists. The real name is
> `FSManageableResourceMaintenanceOperations`.
> **Note on `FSMetadataStore` and `FSMatchResult` "class".** `FSMetadataStore` does not exist in
> FSKit. `FSMatchResult` is an `enum`, not a class.
> **Note on `FSTaskOptions`.** It is a plain class, not a protocol.

### 1.3 Resources

```swift
// macOS 15.4
class FSResource {
    var isRevoked: Bool { get }
    func makeProxy() -> Self
    func revoke()
    init?(coder: NSCoder)
}
```

Apple: *"`FSResource` is a base class to represent the various possible sources of data for a
file system. These range from dedicated storage devices like hard drives and flash storage to
**network connections**, and beyond."*
([FSResource](https://developer.apple.com/documentation/fskit/fsresource))

```swift
// macOS 15.4
class FSBlockDeviceResource: FSResource {
    var bsdName: String { get }
    var isWritable: Bool { get }
    var blockSize: UInt64 { get }
    var blockCount: UInt64 { get }
    var physicalBlockSize: UInt64 { get }

    func read (into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func read (into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) async throws -> Int
    func read (into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int,
               completionHandler: @escaping (Int, (any Error)?) -> Void)
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws -> Int
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) async throws -> Int
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int,
               completionHandler: @escaping (Int, (any Error)?) -> Void)

    func metadataRead (into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t, length: Int) throws
    func metadataWrite(from buffer: UnsafeRawBufferPointer,        startingAt offset: off_t, length: Int) throws
    func delayedMetadataWrite(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t, length: Int) throws
    func metadataFlush() throws
    func asynchronousMetadataFlush() throws
    func metadataClear(_ rangesToClear: [FSMetadataRange], withDelayedWrites: Bool) throws
    func metadataPurge(_ rangesToPurge: [FSMetadataRange]) throws
}
```

```swift
// macOS 26.0 — "A resource that represents a path in the system file space."
class FSPathURLResource: FSResource {
    init(url URL: URL, writable: Bool)
    var url: URL { get }
    var isWritable: Bool { get }
}
```
*"The URL passed to `FSPathURLResource` may be a security-scoped URL. If the URL is a
security-scoped URL, FSKit transports it intact from a client application to your extension."*
([FSPathURLResource](https://developer.apple.com/documentation/fskit/fspathurlresource))

```swift
// macOS 26.0 — "A resource that represents an abstract URL."   ← THIS IS THE 9P ONE
class FSGenericURLResource: FSResource {
    init(url: URL)
    var url: URL { get }
}
```
*"An `FSGenericURLResource` is a completely abstract resource. The only reference to its contents
is a single URL, the contents of which are arbitrary. This URL might represent a PCI locator
string like `/pci@f0000000/usb@5`, **or some sort of network address for a remote file system**.
FSKit leaves interpretation of the URL and its contents entirely up to your implementation.
Use the `Info.plist` key `FSSupportedSchemes` to provide an array of case-insensitive URL schemes
that your implementation supports."*
([FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource))

**`FSServerURLResource` — private.** It exists in `FSKit.framework` (present as far back as the
iOS 17 dyld cache) but is not in the public SDK; it is declared in `FSKit_private.h`, which
`mount(8)` imports. Consuming it also requires conforming to the private
`FSServerURLUnaryOperations` protocol, which `fskitd` checks with `-conformsToProtocol:` before
allowing a server-URL mount. `jirafs` re-declares that protocol by name and registers conformance
at load time via `class_addProtocol`
([`JiraFileSystemURLEnabled.h`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/JiraFileSystemURLEnabled.h),
[`JiraFileSystem+ServerURL.m`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/JiraFileSystem%2BServerURL.m)).
Its shape, reverse-engineered:

```objc
@protocol FSServerURLUnaryOperations <NSObject>
@required
- (nullable id)startOpeningSessionWithTask:(FSTask *)task url:(NSURL *)url
                                   options:(nullable NSDictionary *)options
                                     error:(NSError **)outError;   // -> FSServerSessionInfoTask*
- (nullable id)startServerInfoFetchWithTask:(FSTask *)task url:(NSURL *)url
                                    options:(nullable NSDictionary *)options
                                      error:(NSError **)outError;  // -> FSServerInfoTask*
- (void)parseURL:(NSURL *)url replyHandler:(void (^)(id params, NSError *))reply;
- (void)composeURL:(id)parameters replyHandler:(void (^)(NSURL *, NSError *))reply;
- (void)closeSession:(nullable id)session replyHandler:(void (^)(NSError *))reply;
@end
```

**Do not depend on this for `fs9kit`.** It is the NetFS / "Connect to Server" integration path and
will get you rejected from the Mac App Store. `FSGenericURLResource` gives you the same mount
without private API.

### 1.4 Protocols — full signatures

#### `UnaryFileSystemExtension` — macOS 15.4

```swift
protocol UnaryFileSystemExtension: AppExtension {
    associatedtype FileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations
    var fileSystem: FileSystem { get }
}
```

#### `FSFileSystemBase` — macOS 15.4

```swift
protocol FSFileSystemBase: NSObjectProtocol {
    @NSCopying var containerStatus: FSContainerStatus { get set }               // required
    func wipe(_ resource: FSBlockDeviceResource,
              completionHandler: @escaping @Sendable ((any Error)?) -> Void)    // required
    func wipe(_ resource: FSBlockDeviceResource) async throws
}
```

#### `FSUnaryFileSystemOperations` — macOS 15.4

```swift
protocol FSUnaryFileSystemOperations: NSObjectProtocol {

    // REQUIRED
    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping @Sendable (FSProbeResult?, (any Error)?) -> Void)
    func probeResource(resource: FSResource) async throws -> FSProbeResult

    // REQUIRED
    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping @Sendable (FSVolume?, (any Error)?) -> Void)
    func loadResource(resource: FSResource, options: FSTaskOptions) async throws -> FSVolume

    // REQUIRED
    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping @Sendable ((any Error)?) -> Void)
    func unloadResource(resource: FSResource, options: FSTaskOptions) async throws

    // OPTIONAL
    optional func didFinishLoading()
}
```

#### `FSVolume.CommonOperations` — macOS 15.4

```swift
protocol CommonOperations: NSObjectProtocol {
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities { get }     // required
    var volumeStatistics: FSStatFSResult { get }                               // required
    func mount(options: FSTaskOptions) async throws                            // required
    func unmount() async                                                       // required
    func synchronize(flags: FSSyncFlags) async throws                          // required
    func reclaimItem(_ item: FSItem) async throws                              // required

    optional var enableOpenUnlinkEmulation: Bool { get }                       // macOS 26.0
    optional var requestedMountOptions: FSVolume.MountOptions { get }          // macOS 26.4
}
```

`enableOpenUnlinkEmulation` (macOS 26.0) is worth knowing about: it lets FSKit emulate
open-unlink ("delete a file that is still open") for filesystems that lack it natively — which
9P/9P2000.L does.

#### `FSVolume.PathConfOperations` — macOS 15.4

```swift
protocol PathConfOperations: NSObjectProtocol {
    var maximumLinkCount: Int { get }              // required
    var maximumNameLength: Int { get }             // required
    var restrictsOwnershipChanges: Bool { get }    // required
    var truncatesLongNames: Bool { get }           // required

    optional var maximumFileSize: UInt64 { get }
    optional var maximumFileSizeInBits: Int { get }
    optional var maximumXattrSize: Int { get }
    optional var maximumXattrSizeInBits: Int { get }
}
```

#### `FSVolume.Operations` — macOS 15.4, deprecated 27.0. **The only mandatory volume protocol.**

`protocol Operations: FSVolume.CommonOperations, FSVolume.PathConfOperations` — every member is
**required**. Async forms shown; each also has a `replyHandler:` completion variant.

```swift
func activate(options: FSTaskOptions) async throws -> FSItem              // returns the ROOT item
func deactivate(options: FSDeactivateOptions = []) async throws

func lookupItem(named name: FSFileName, inDirectory directory: FSItem)
      async throws -> (FSItem, FSFileName)

func createItem(named name: FSFileName, type: FSItem.ItemType,
                inDirectory directory: FSItem,
                attributes newAttributes: FSItem.SetAttributesRequest)
      async throws -> (FSItem, FSFileName)

func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem)
      async throws -> FSFileName

func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                        attributes newAttributes: FSItem.SetAttributesRequest,
                        linkContents contents: FSFileName)
      async throws -> (FSItem, FSFileName)

func readSymbolicLink(_ item: FSItem) async throws -> FSFileName

func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem)
      async throws

func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                named sourceName: FSFileName,
                to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                overItem: FSItem?)
      async throws -> FSFileName

func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem)
      async throws -> FSItem.Attributes         // ObjC/completion name: getAttributes(_:of:replyHandler:)

func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem)
      async throws -> FSItem.Attributes

func enumerateDirectory(_ directory: FSItem,
                        startingAt cookie: FSDirectoryCookie,
                        verifier: FSDirectoryVerifier,
                        attributes: FSItem.GetAttributesRequest?,
                        packer: FSDirectoryEntryPacker)
      async throws -> FSDirectoryVerifier
```

#### Optional volume protocols (all macOS 15.4, all deprecated 27.0)

```swift
protocol OpenCloseOperations: NSObjectProtocol {
    func openItem (_ item: FSItem, modes: FSVolume.OpenModes) async throws   // required
    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes) async throws   // required
    optional var isOpenCloseInhibited: Bool { get set }
}

protocol ReadWriteOperations: NSObjectProtocol {
    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer) async throws -> Int      // required
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int  // required
}

protocol XattrOperations: NSObjectProtocol {
    func xattr(named name: FSFileName, of item: FSItem) async throws -> Data // required
    func xattrs(of item: FSItem) async throws -> [FSFileName]                // required
    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem,
                  policy: FSVolume.SetXattrPolicy) async throws              // required
    optional func supportedXattrNames(for item: FSItem) -> [FSFileName]
    optional var xattrOperationsInhibited: Bool { get set }
}

protocol RenameOperations: NSObjectProtocol {                    // renames the VOLUME, not items
    func setVolumeName(_ name: FSFileName) async throws -> FSFileName        // required
    optional var isVolumeRenameInhibited: Bool { get set }
}

protocol PreallocateOperations: NSObjectProtocol {
    func preallocateSpace(for item: FSItem, at offset: off_t, length: Int,
                          flags: FSVolume.PreallocateFlags) async throws -> Int  // required
    optional var isPreallocateInhibited: Bool { get set }
}

protocol ItemDeactivation: NSObjectProtocol {
    func deactivateItem(_ item: FSItem) async throws                          // required
    var itemDeactivationPolicy: FSVolume.ItemDeactivationOptions { get }      // required
}

protocol AccessCheckOperations: NSObjectProtocol {
    func checkAccess(to theItem: FSItem,
                     requestedAccess access: FSVolume.AccessMask) async throws -> Bool  // required
    optional var isAccessCheckInhibited: Bool { get set }
}

protocol FSVolumeKernelOffloadedIOOperations { … }   // block-device only — see §6
```

#### `FSManageableResourceMaintenanceOperations` — macOS 15.4

```swift
protocol FSManageableResourceMaintenanceOperations: NSObjectProtocol {
    func startCheck (task: FSTask, options: FSTaskOptions) throws -> Progress   // required
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress   // required
}
```

Only reachable for block-device and path-URL resources — `mount(8)` refuses `fsck`/`newfs` for
URL resources outright ("*doesn't support Block Device or PathURL resources, can't preform
format/check task*"). Irrelevant to 9P.

**Gotcha (undocumented):** `startCheck` must complete *asynchronously*. Calling
`didCompleteWithError:` synchronously makes FSKit see "completed" before "started" over XPC and
fail with error 27503 ([OpenZFS PoC thread](https://developer.apple.com/forums/thread/828035)).

### 1.5 Supporting types you will actually use

```swift
class FSTaskOptions {                                       // macOS 15.4
    var taskOptions: [String] { get }                       // the parsed argv, e.g. ["-o", "ro"]
    func url(forOption option: String) -> URL?              // security-scoped URL for an option
}

class FSProbeResult {                                       // macOS 15.4
    static var notRecognized: FSProbeResult { get }
    static func recognized      (name: String, containerID: FSContainerIdentifier) -> Self
    static func usableButLimited(name: String, containerID: FSContainerIdentifier) -> Self
    static func usable          (name: String, containerID: FSContainerIdentifier) -> Self
    var result: FSMatchResult { get }
    var name: String? { get }
    var containerID: FSContainerIdentifier? { get }
}

enum FSMatchResult { case notRecognized, recognized, usableButLimited, usable }

class FSContainerStatus {                                   // macOS 15.4
    static var notReady: FSContainerStatus { get }          // (+ notReady(status:))
    static var blocked:  FSContainerStatus { get }          // (+ blocked(status:))
    static var ready:    FSContainerStatus { get }
    static var active:   FSContainerStatus { get }
    var state: FSContainerState { get }
    var status: (any Error)? { get }
}

class FSStatFSResult {                                      // macOS 15.4
    init(fileSystemTypeName: String)
    var blockSize, ioSize, fileSystemSubType: Int           // all get/set
    var totalBlocks, availableBlocks, freeBlocks, usedBlocks: UInt64
    var totalBytes,  availableBytes,  freeBytes,  usedBytes: UInt64
    var totalFiles, freeFiles: UInt64
    var fileSystemTypeName: String { get }
}

class FSFileName {                                          // macOS 15.4
    convenience init(string: String)
    convenience init(data: Data)
    convenience init(cString: UnsafeBufferPointer<CChar>)
    convenience init(bytes: UnsafeBufferPointer<CChar>)
    var data: Data { get }
    var string: String? { get }        // nil when the bytes are not valid UTF-8
}

class FSEntityIdentifier {                                  // macOS 15.4
    init(); init(uuid: UUID); init(uuid: UUID, qualifier: UInt64)   // + data variants
    var uuid: UUID; var qualifier: Data?
}
class FSContainerIdentifier: FSEntityIdentifier { var volumeIdentifier: FSVolume.Identifier { get } }
class FSVolume.Identifier:  FSEntityIdentifier { }

class FSDirectoryEntryPacker {                              // macOS 15.4
    func packEntry(name: FSFileName, itemType: FSItem.ItemType, itemID: FSItem.Identifier,
                   nextCookie: FSDirectoryCookie, attributes: FSItem.Attributes?) -> Bool
}

class FSMutableFileDataBuffer {                             // macOS 15.4
    var length: Int { get }
    func withUnsafeMutableBytes<R, E>(_ body: (UnsafeMutableRawBufferPointer) throws(E) -> R) throws(E) -> R
    func createMutableRawSpan() throws -> MutableRawSpan     // macOS 27.0
}

class FSTask {                                              // macOS 15.4
    func logMessage(_ message: String)
    func didComplete(error: (any Error)?)
    var cancellationHandler: (() -> (any Error)?)?           // macOS 26.0
}

class FSModuleIdentity {                                    // macOS 15.4
    var bundleIdentifier: String { get }
    var url: URL { get }
    var isEnabled: Bool { get }
}

struct FSError.Code {                                       // macOS 15.4
    moduleLoadFailed, resourceUnrecognized, resourceDamaged, resourceUnusable,
    statusOperationInProgress, statusOperationPaused, invalidDirectoryCookie
}
func fs_errorForPOSIXError(_:) / fs_errorForCocoaError(_:) / fs_errorForMachError(_:)
```

`FSItem.Attribute` flags (macOS 15.4): `uid`, `gid`, `mode`, `type`, `linkCount`, `flags`,
`size`, `allocSize`, `fileID`, `parentID`, `accessTime`, `modifyTime`, `changeTime`, `birthTime`,
`addedTime`, `backupTime`, `supportsLimitedXAttrs`, `inhibitKernelOffloadedIO`.

`FSItem.ItemType`: `unknown`, `file`, `directory`, `symlink`, `fifo`, `charDevice`,
`blockDevice`, `socket`.

`FSVolume.SupportedCapabilities` (all `Bool` get/set unless noted):
`supportsPersistentObjectIDs`, `supportsSymbolicLinks`, `supportsHardLinks`, `supportsJournal`,
`supportsActiveJournal`, `doesNotSupportRootTimes`, `supportsSparseFiles`, `supportsZeroRuns`,
`supportsFastStatFS`, `supports2TBFiles`, `supportsOpenDenyModes`, `supportsHiddenFiles`,
`doesNotSupportVolumeSizes`, `supports64BitObjectIDs`, `supportsDocumentID`,
`doesNotSupportImmutableFiles`, `doesNotSupportSettingFilePermissions`, `supportsSharedSpace`,
`supportsVolumeGroups`, and `caseFormat: FSVolume.CaseFormat`
(`.sensitive` / `.insensitive` / `.insensitiveCasePreserving`).

### 1.6 What macOS 26 added over 15.4

| Symbol | Note |
|---|---|
| `FSPathURLResource` | file-path resource, optionally security-scoped |
| `FSGenericURLResource` | **abstract URL resource — the network-FS entry point** |
| `FSTask.cancellationHandler` | lets a task respond to cancellation |
| `FSVolume.CommonOperations.enableOpenUnlinkEmulation` | FSKit emulates open-unlink for you |
| `FSVolume.MountOptions` + `requestedMountOptions` | macOS **26.4**; currently only `.readOnly` |
| `Info.plist`: `FSSupportsPathURLs`, `FSSupportsGenericURLResources`, `FSSupportedSchemes`, `FSRequiresSecurityScopedPathURLResources` | see §3 |
| Sample: [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system) | Apple's first non-block-device sample |

*(Source for the diff: [dotnet/macios wiki, FSKit macOS xcode26.0 b1](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode26.0-b1),
cross-checked against Apple's per-symbol availability metadata.)*

### 1.7 What macOS 27 (beta) adds — relevant to 9P

- `FSVolume.DataCacheHandler` — **explicit kernel cache-coherency control**, described by Apple as
  *"a generalized form of leasing"* for *"network file systems and other kinds of file systems
  where an outside actor might modify the data outside of the kernel's normal data flow"*
  ([thread 831417](https://developer.apple.com/forums/thread/831417)).
  Cache modes: `none` / `readWithCache` / `readWriteWithCache`; coherency types:
  `noCache` / `readCache` / `writeThrough` / `writeBack`; actions: `push` / `pushInvalidate` /
  `invalidate`. Downgrades are module-initiated via
  `setCacheState(for:cacheMode:coherencyType:action:)`.
  *"If a file system doesn't conform to this protocol, the kernel may still cache it. However,
  such a file system has no control over caching behavior."*
- `FSContext` threaded through every handler method (gives per-operation caller context).
- `FSClient.mountSingleVolume(resource:bundleID:options:)` — a **real programmatic mount API**,
  gated behind a new `com.apple.developer.fskit.mount` entitlement (§2.3).
- `FSClient.openFileSystemExtensionsSettings()` — opens the System Settings pane for the user.
- `FSVolumeKernelOffloadedIOOperations` deprecated.

---

## 2. Mounting

### 2.1 `mount(8)` syntax and how the resource argument is interpreted

```
mount [-dfFrkuvw] [-o options] [-t external_type] special mount_point
  -F   Forces the file system type be considered as an FSModule delivered using FSKit.
```
([`mount.8`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/mount.tproj/mount.8))

`-F` is **not strictly required**. `mount(8)` searches `/sbin/mount_<type>`,
`/usr/sbin/mount_<type>`, `/System/Library/Filesystems/<type>.fs/Contents/Resources/mount_<type>`
and `/Library/Filesystems/…`; if **no binary is found**, it falls through to FSKit automatically:

```c
if (!found_binary || force_fskit) {
    argc = 0;
    argv[argc++] = vfstype;
    mangle(optbuf_userfs, &argc, argv, MAX_MOUNT_ARGS - 3);   // the -o options
    argv[argc++] = fs_spec;                                   // <-- the "device" argument
    argv[argc++] = fs_file;                                   // <-- the mount point
    argv[argc]   = NULL;
    return_value = invoke_tool_from_fskit(mount_fs_op, flags, argc, argv);
```
([`mount.tproj/mount.c`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/mount.tproj/mount.c))

That is why Apple's own sample says `mount -t passthrough ~/Documents ~/passthrough-fs` with no
`-F`. **Use `-F` anyway** — it makes failures explicit rather than silently falling through to a
kext/binary of the same name.

**The resource argument is interpreted purely from your `Info.plist`.** From
[`disklib/fskit_support.m`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m):

```objc
NSString *argv0String = [NSString stringWithUTF8String:argv[0]];
bool acceptsBD         = attributes[@"FSSupportsBlockResources"].boolValue;
bool acceptsPath       = attributes[@"FSSupportsPathURLs"].boolValue;
bool acceptsServerURL  = attributes[@"FSSupportsServerURLs"].boolValue;
bool acceptsGenericURL = attributes[@"FSSupportsGenericURLResources"].boolValue;

if (acceptsBD) {
    theResource = [FSBlockDeviceResource proxyResourceForBSDName:argv0String isWritable:writable];
} else if (acceptsPath) {
    NSURL *url = [NSURL fileURLWithPath:argv0String];              // treated as a FILE PATH
    if (attributes[@"FSRequiresSecurityScopedPathURLResources"].boolValue)
        theResource = [FSPathURLResource secureResourceWithURL:url readonly:!writable];
    else
        theResource = [FSPathURLResource resourceWithURL:url];
} else if (acceptsGenericURL) {
    NSURL *url = [NSURL URLWithString:argv0String];                // treated as a FULL URL
    theResource = [FSGenericURLResource resourceWithURL:url];
} else if (acceptsServerURL) {
    NSURL *url = [NSURL URLWithString:argv0String];
    theResource = [FSServerURLResource resourceWithURL:url];
} else {
    warnx("Filesystem %s supports neither Block Device nor PathURL resources nor ServerURL resources.");
    return EINVAL;
}
```

So the four forms are:

| `Info.plist` flag | `<resource>` argument form | Resulting `FSResource` |
|---|---|---|
| `FSSupportsBlockResources` | BSD name — `disk4s1` or `/dev/disk4s1` | `FSBlockDeviceResource` (proxy) |
| `FSSupportsPathURLs` | a filesystem **path** — `~/Documents` | `FSPathURLResource` |
| `FSSupportsGenericURLResources` | a full **URL string** — `9p://host:564/aname` | `FSGenericURLResource` |
| `FSSupportsServerURLs` | a full **URL string** | `FSServerURLResource` (private) |

The checks are an **if/else-if chain in that exact order**, so setting more than one flag means
only the highest-priority one is ever used by `mount(8)`. For `fs9kit`: set
`FSSupportsBlockResources=false`, `FSSupportsPathURLs=false`,
`FSSupportsGenericURLResources=true`.

**Version gate.** The `acceptsGenericURL` / `acceptsServerURL` branches first appear in
`diskdev_cmds-751` (tagged 2025-10-16, the macOS 26 line). `diskdev_cmds-735`, `-737.60.1`,
`-737.100.3`, `-737.140.4` (macOS 15.x) have only the block-device and path-URL branches.
Consistent with `FSGenericURLResource` being `macOS 26.0` public API.

### 2.2 How mount options reach your extension

`mount(8)` passes the whole `-o` string through, but `FSTaskOptionsBundle` only *parses* the
short options you declare in `Info.plist`:

```xml
<key>FSActivateOptionSyntax</key>
<dict><key>shortOptions</key><string>o:</string></dict>
```

`shortOptions` is a `getopt(3)` string. `o:` means "accept `-o` with a required argument".
Apple's samples use `u:g:m:o:` (uid, gid, mode, options). If you omit `o:`, `mount -o …` is a
parse error. `mount(8)` itself also inspects the `-o` string before handing it over — `ro` /
`rdonly` / `rw` decide the `writable` flag.

Inside your extension:

```swift
for opt in options.taskOptions {          // e.g. ["-o", "ro,port=1564"]
    …
}
if let u = options.url(forOption: "somepath") { … }   // security-scoped URL for that option
```

`FSTaskOptions.url(forOption:)` is how security-scoped URLs are carried in for options that name
paths.

### 2.3 Programmatic mount APIs

| API | Status |
|---|---|
| `/sbin/mount -F …` via `posix_spawn` | **The supported way today.** Apple DTS: *"The `/sbin/mount` command is the system's primary mounting interface for applications… There is nothing wrong with calling `/sbin/mount` directly from your application."* ([thread 799283](https://developer.apple.com/forums/thread/799283)) |
| `mount(2)` syscall | SPI. *"the API that mount commands use to communicate with the kernel, NOT the API apps should use."* |
| DiskArbitration `DADiskMount` | *"once everything is working properly, DiskArb should fully support FSKit volumes. In the long term, this is the API I would recommend."* — but has had multiple blocking bugs ([thread 797485](https://developer.apple.com/forums/thread/797485)). `diskarbitrationd` itself `posix_spawn`s `/sbin/mount`. Block-device oriented; **not** a route for URL resources. |
| `FSClient.mountSingleVolume(resource:bundleID:options:)` | **macOS 27.0 beta only.** Public API, requires the `com.apple.developer.fskit.mount` entitlement. *"performs the complete workflow of resource loading, volume activation, mount point creation, and actual mounting. The system mounts the volume within the `/Volumes/` directory."* |
| macFUSE `MFMount.framework` | Third-party, XPC-based, ships in `/Library/Filesystems/macfuse.fs/Contents/Frameworks` as of [macFUSE 5.2.0](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html). Sandboxed clients need a Mach-lookup exception for `io.macfuse.mount`. |

**App Sandbox blocker.** *"Calling `/sbin/mount` is not possible with App Sandbox enabled."*
(DTS, [thread 799283](https://developer.apple.com/forums/thread/799283); tracked as FB20186709).
So: your **extension** is sandboxed (mandatory, see §3.2), but your **containing app** must
*not* be sandboxed if it is the thing invoking `mount`. `jirafs` documents exactly this — they
had to remove `com.apple.security.app-sandbox` from the host app because it blocked
`NSAppleScript … with administrator privileges`
([INSTRUCTIONS.md](https://github.com/srz-zumix/jirafs/blob/main/Documentation/INSTRUCTIONS.md)).
This also means **an FSKit 9P client that mounts itself cannot ship on the Mac App Store today**
(until `FSClient.mountSingleVolume` on macOS 27).

### 2.4 Unmounting

```sh
umount /Volumes/fs9kit
diskutil unmount /Volumes/fs9kit
diskutil unmount force /Volumes/fs9kit     # when busy
```

FSKit mounts use `noowners` semantics
([FSKitBridge README](https://github.com/debox-network/FSKitBridge)).

### 2.5 Mount point location

Apple's sample mounts at `~/passthrough-fs`; `jirafs` at `~/jirafs/<name>`. Both work. macFUSE's
wiki claims *"Using mount points outside of `/Volumes` is not supported by FSKit"*
([FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)) — this contradicts
Apple's own sample and is likely a macFUSE-specific constraint. **UNCONFIRMED** which is right in
general; prefer `/Volumes/<Name>` for Finder integration and avoid TCC-protected directories
(`~/Documents`, `~/Desktop`, `~/Downloads`) as mount targets.

---

## 3. Packaging, entitlements and code signing

### 3.1 Info.plist — complete reference

The extension point identifier is **`com.apple.fskit.fsmodule`** (not `com.apple.fskit.unary`).
Modern extensions declare it under `EXAppExtensionAttributes` / `EXExtensionPointIdentifier`
(ExtensionKit). Apple's older in-tree modules like `hfs_appex` still use the legacy
`NSExtension` / `NSExtensionPointIdentifier` form
([`hfs_appex/Info.plist`](https://github.com/apple-open-source/macos/blob/master/hfs/hfs_appex/Info.plist));
**use `EXAppExtensionAttributes` for new code** — that is what Apple's macOS 26 sample and every
third-party module use.

| Key | Type | Meaning |
|---|---|---|
| `EXExtensionPointIdentifier` | String | Must be `com.apple.fskit.fsmodule` |
| `EXExtensionPrincipalClass` | String | Only for ObjC-principal-class modules; Swift `@main` extensions omit it |
| `FSShortName` | String | **The `mount -t <this>` name.** Required. |
| `FSSupportsBlockResources` | Bool | Accept `FSBlockDeviceResource` |
| `FSSupportsPathURLs` | Bool | Accept `FSPathURLResource` (macOS 26+) |
| `FSRequiresSecurityScopedPathURLResources` | Bool | Path URLs arrive security-scoped (macOS 26+) |
| `FSSupportsGenericURLResources` | Bool | Accept `FSGenericURLResource` (macOS 26+) |
| `FSSupportedSchemes` | Array\<String\> | Case-insensitive URL schemes you handle. Documented on the [`FSGenericURLResource`](https://developer.apple.com/documentation/fskit/fsgenericurlresource) page. |
| `FSSupportsServerURLs` | Bool | Accept `FSServerURLResource` — **private**, needs `FSServerURLUnaryOperations` |
| `FSSupportsURLMounting` | Bool | Seen in `jirafs`; **UNCONFIRMED** semantics, not referenced by `mount(8)` |
| `FSSupportsKernelOffloadedIO` | Bool | Block devices only ([`msdos_appex`](https://github.com/apple-open-source/macos/blob/master/msdosfs/msdos_appex/Info.plist)) |
| `FSActivateOptionSyntax` → `shortOptions` | String | `getopt(3)` spec for `mount -o …`. **Required** — absent means "does not support mount". |
| `FSCheckOptionSyntax` → `shortOptions` | String | `getopt(3)` spec for `fsck` |
| `FSFormatOptionSyntax` → `shortOptions` | String | `getopt(3)` spec for `newfs` |
| `FSMediaTypes` | Dict | Content-hint/GPT-UUID → probe rules. Block devices only; `<dict/>` for network FS. |
| `FSPersonalities` | Dict | Display metadata: `FSName`, `FSSubType`, `FSfileObjectsAreCaseSensitive`, `FSfileObjectsAreCasePreserving`, `FSvolumeNameIsCasePreserving`, plus legacy `FSMountExecutable` / `FSFormatExecutable` / `FSRepairExecutable` for in-tree modules. |
| `FSFileSystemType` | String | Seen in `FSKitBridge`; **UNCONFIRMED** whether `mount(8)` reads it (`FSShortName` is the key that matters). |

**Apple's actual `PassthroughAppEx/Info.plist`** (from the
[downloadable sample](https://docs-assets.developer.apple.com/published/0b4283600908/BuildingAPassthroughFileSystem.zip)) —
this is the authoritative template:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EXAppExtensionAttributes</key>
	<dict>
		<key>EXExtensionPointIdentifier</key>
		<string>com.apple.fskit.fsmodule</string>
		<key>FSActivateOptionSyntax</key>
		<dict>
			<key>shortOptions</key>
			<string>u:g:m:o:</string>
		</dict>
		<key>FSCheckOptionSyntax</key>
		<dict>
			<key>shortOptions</key>
			<string>nqy</string>
		</dict>
		<key>FSFormatOptionSyntax</key>
		<dict>
			<key>shortOptions</key>
			<string>v</string>
		</dict>
		<key>FSMediaTypes</key>
		<dict/>
		<key>FSPersonalities</key>
		<dict/>
		<key>FSRequiresSecurityScopedPathURLResources</key>
		<true/>
		<key>FSShortName</key>
		<string>passthrough</string>
		<key>FSSupportsBlockResources</key>
		<false/>
		<key>FSSupportsPathURLs</key>
		<true/>
	</dict>
</dict>
</plist>
```

**Recommended `fs9kit` `Info.plist`:**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>fs9kit (9P)</string>
	<key>CFBundleIdentifier</key>
	<string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleExecutable</key>
	<string>$(EXECUTABLE_NAME)</string>
	<key>CFBundlePackageType</key>
	<string>XPC!</string>
	<key>CFBundleShortVersionString</key>
	<string>$(MARKETING_VERSION)</string>
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>

	<key>EXAppExtensionAttributes</key>
	<dict>
		<key>EXExtensionPointIdentifier</key>
		<string>com.apple.fskit.fsmodule</string>

		<!-- mount -t fs9kit -->
		<key>FSShortName</key>
		<string>fs9kit</string>

		<!-- No disk. The mount "device" argument is parsed as a URL. -->
		<key>FSSupportsBlockResources</key>
		<false/>
		<key>FSSupportsPathURLs</key>
		<false/>
		<key>FSSupportsGenericURLResources</key>
		<true/>
		<key>FSSupportedSchemes</key>
		<array>
			<string>9p</string>
			<string>9pfs</string>
		</array>

		<!-- getopt(3) spec: -o is mandatory or `mount -o ...` fails to parse. -->
		<key>FSActivateOptionSyntax</key>
		<dict>
			<key>shortOptions</key>
			<string>u:g:m:o:</string>
		</dict>

		<!-- No fsck/newfs for a network FS; mount(8) refuses them for URL resources anyway. -->
		<key>FSMediaTypes</key>
		<dict/>
		<key>FSPersonalities</key>
		<dict>
			<key>fs9kit</key>
			<dict>
				<key>FSName</key>
				<string>9P (fs9kit)</string>
				<key>FSfileObjectsAreCaseSensitive</key>
				<true/>
				<key>FSfileObjectsAreCasePreserving</key>
				<true/>
			</dict>
		</dict>
	</dict>
</dict>
</plist>
```

### 3.2 Entitlements

**Extension** (`fs9kitAppEx.entitlements`) — exactly Apple's sample plus network access:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.fskit.fsmodule</key>
	<true/>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
```

`com.apple.security.app-sandbox` is **mandatory** for an FSKit extension — Apple DTS explains it
*"isn't about restriction but acknowledging opt-in to system-defined capability declaration"*;
all ExtensionKit extensions are sandboxed by design
([OpenZFS thread](https://developer.apple.com/forums/thread/828035)).
`com.apple.security.network.client` is what lets the appex open the 9P TCP connection —
`jirafs` uses exactly this
([`jirafs-extension.entitlements`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/jirafs-extension.entitlements)).
For a Unix-socket 9P transport you would additionally need an app-group container or a file-access
entitlement (DTS: *"Sockets should be possible via app group containers or file access
entitlements"*).

**Containing app** — do **not** sandbox it if it shells out to `mount`:

```xml
<dict>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
	<!-- deliberately NOT com.apple.security.app-sandbox: blocks /sbin/mount -->
</dict>
```

#### Is `com.apple.developer.fskit.fsmodule` restricted?

**No.** Apple's [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
table lists **"FSKit Module"** as available under all three columns — *Apple Developer* (the free
tier), *Developer ID*, and *ADP* — with no "Development only" footnote and no managed-capability
marker. It is not in the approval-gated set described by
[Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/).

- **Free / personal team**: the capability is listed for the free "Apple Developer" tier.
  **UNCONFIRMED** whether the 7-day personal-team provisioning profile actually vends this
  entitlement in practice — I found no first-hand report either way. Verify before relying on it.
- **Ad-hoc (`codesign -s -`)**: **does not work by default.** OpenZFS's FSKit PoC ad-hoc-signs
  with `com.apple.developer.team-identifier = ADHOC` and
  `com.apple.application-identifier = ADHOC.<bundleid>`, and **requires the boot argument
  `amfi_get_out_of_my_way=1`** for AMFI to accept the signature
  ([thread 828035](https://developer.apple.com/forums/thread/828035)).
  That means SIP disabled (Intel) or Reduced/Permissive Security (Apple Silicon). Not shippable.
- **Unsigned**: rejected. `jirafs`: *"FSKit extensions are rejected by `fskitd` without a
  signature. Always use a signed build built with `-allowProvisioningUpdates`."*

### 3.3 Where the app must live, and enabling the extension

- The `.appex` lives at `<App>.app/Contents/Extensions/<Name>.appex`.
- Apple's sample and every third-party project install the containing app in **`/Applications`**.
  I found no documented *hard* requirement, but LaunchServices registration is what makes the
  extension discoverable and `/Applications` is the only path anyone reports working reliably.
  **UNCONFIRMED** that other locations work.
- **User enablement is required and is per-user**: System Settings → General → *Login Items &
  Extensions* → *Extensions* section → "File System Extensions" → ⓘ → toggle
  ([Apple sample instructions](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)).
- Settings live at `/Users/<user>/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`.
  Apple DTS explicitly advises **against** writing it directly (*"such files may be protected by
  MAC now or in future releases"*) and confirms **there is no global/pre-login enablement**
  ([thread 808594](https://developer.apple.com/forums/thread/808594)).
- **CLI equivalent** (unofficial but used by every project):
  ```sh
  sudo pluginkit -a /Applications/fs9kit.app/Contents/Extensions/fs9kitAppEx.appex
  sudo pluginkit -e use -i com.example.fs9kit.appex
  pluginkit -m -A -i com.example.fs9kit.appex          # verify
  ```
- **After every reinstall**, re-register — `fskitd` caches the old bundle UUID:
  ```sh
  sudo kill $(pgrep fskitd); sleep 3
  sudo pluginkit -a /Applications/fs9kit.app/Contents/Extensions/fs9kitAppEx.appex
  ```
  ([jirafs Makefile](https://github.com/srz-zumix/jirafs/blob/main/Makefile),
  [thread 788609](https://developer.apple.com/forums/thread/788609)).
- If mounts start failing with `com.apple.extensionKit.errorDomain error 2` during rapid rebuild
  cycles, LaunchServices has stale UUIDs. Fix:
  ```sh
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -R -f -u ~/Library/Developer/Xcode/Archives
  ```
  ([thread 804432](https://developer.apple.com/forums/thread/804432) — DTS confirms this is a
  system-level dev-workflow issue, not user error; FB20790194.)
- `fskit_agent(8)` is the per-user agent that *"reports FSModule availability and enablement to
  `fskitd` per user"* and *"launches FSModules at the direction of `fskitd`"*
  ([man page](https://manp.gs/mac/8/fskit_agent)). `fskitd` is the system daemon.

### 3.4 Notarization, SIP, Apple Silicon

- **Notarization**: required only in the ordinary Gatekeeper sense — a Developer-ID-signed app
  distributed outside the Mac App Store must be notarized. Nothing FSKit-specific.
- **SIP**: does **not** need to be disabled for a properly signed extension. It *does* need to be
  down (plus `amfi_get_out_of_my_way=1`) for ad-hoc-signed extensions.
- **Apple Silicon**: works at Full Security with a proper Developer ID / ADP signature. Reduced
  or Permissive Security is only needed for the ad-hoc path (boot-args require it).
- **App Store**: FSKit modules are *"compatible with Mac App Store distribution"*
  ([FSKit overview](https://developer.apple.com/documentation/fskit)) — but see §2.3: a
  self-mounting app can't be sandboxed today, so MAS shipping is blocked until macOS 27's
  `FSClient.mountSingleVolume`.
- **App updates unmount your volumes.** App-extension infrastructure terminates the appex during
  an app update/delete, silently unmounting without calling `synchronize()`. DTS workaround: keep
  a GUI-less helper process from the app running while any volume is mounted, so Finder/the
  installer refuse to replace the app ([thread 809747](https://developer.apple.com/forums/thread/809747);
  FB21287341, FB21287688, FB21305906 — the last, a system-wide disk freeze, is fixed in 26.4).

---

## 4. Lifecycle: what actually happens on `mount -F -t fs9kit 9p://… /mnt`

From [`fskit_support.m`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m):

1. `FSClient installedExtensionWithShortName:` resolves `fs9kit` → `FSModuleIdentity`.
   If not found: `ENOENT` → *"File system named fs9kit not found"*.
2. If `!module.enabled`: *"Module <id> is disabled!"* → `EINVAL`. (This is the System Settings toggle.)
3. `FSTaskOptionsBundle bundleForArguments:` parses `-o …` per `FSActivateOptionSyntax`.
4. `-o ro` / `-o rdonly` → `writable = false`; `-o rw` → `writable = true`.
5. The resource is built from the `Info.plist` flags (§2.1).
6. **`probeResource:` is called ONLY for block-device and path-URL resources.**
   ```objc
   if (acceptsBD || acceptsPath) {
       [client probeResourceSync:theResource usingBundle:module.bundleIdentifier …];
       containerID = probeResult.containerID;
   }
   ```
   For `FSGenericURLResource` / `FSServerURLResource`, **probe is skipped entirely** and
   `loadResource` is called directly. `jirafs` documents this: *"For URL-based resources
   (`jira://`), `fskitd` skips `probeResource` and calls `loadResource` directly."*
7. `[client loadResource:shortName:options:]` → your `loadResource(resource:options:replyHandler:)`
   → returns an `FSVolume`.
8. `[client activateVolume:…]` → your volume's `activate(options:)` → returns the **root `FSItem`**.
9. `LiveFSMountClient mountVolume:… on:mountPathString` performs the actual VFS mount via
   `com.apple.filesystems.UserFS.FileProvider`.
10. On failure at step 9: `deactivateVolume`, then `unloadResource`.

### Container-state gotchas (undocumented, will cost you a day)

- **The `containerID` returned by `probeResource` must exactly match the `volumeID` you construct
  the `FSVolume` with**, or `loadResource` fails with `EAGAIN`
  ([OpenZFS thread](https://developer.apple.com/forums/thread/828035)). Derive a **deterministic**
  UUID from the mount URL — a random UUID makes `fskitd` treat each attempt as an unknown
  container and close it. `jirafs` uses SHA-256(url-host) → RFC 4122 v5 UUID.
- **`containerStatus` must be `.ready` before `loadResource` replies with a volume.** Because
  probe is skipped for URL resources, you must set it in `loadResource` yourself. Then do **not**
  set it to `.active` manually — FSKit transitions `notReady → active` when you call
  `reply(volume, nil)`, and setting it yourself produces *"unexpected container state"*.
- **Reset `containerStatus = .ready` in `unloadResource`**, otherwise remounting the same URL
  fails with *"Resource busy"* / *"resource state is 5"* until you kill `fskitd`
  (also filed as FB24419932).

---

## 5. Known limitations for network filesystems

### 5.1 Structural

| Limitation | Detail |
|---|---|
| **`FSFileSystem` (multi-resource) is not implemented** | *"The current version of FSKit supports only `FSUnaryFileSystem`."* One resource → one volume. You get exactly one 9P attach per mount; mount N times for N trees. ([FSKit overview](https://developer.apple.com/documentation/fskit)) |
| **`probeResource` never runs for URL resources** | So you cannot reject a bad server URL at probe time. Validate in `loadResource` and return a POSIX error. |
| **No `fsck` / `newfs`** | `mount(8)` refuses check/format for non-BD/non-path resources. |
| **`FSVolumeKernelOffloadedIOOperations` is unusable** | DTS: *"cannot be used with virtual filesystems lacking an underlying block device. Requires passing dev node offsets into the kernel."* ([thread 799283](https://developer.apple.com/forums/thread/799283)). All I/O goes through `ReadWriteOperations`. Deprecated in macOS 27 anyway. |
| **`ReadWriteOperations` is the slow path** | DTS: *"the `FSVolumeReadWriteOperations` path has not been heavily optimized… Performance improvements are expected over time."* macFUSE concurs: *"I/O performance of FSKit volumes is not on par with volumes using the kernel extension backend."* |
| **Per-user only** | No global/pre-login enablement; can't mount a network home directory before login. |
| **App Sandbox can't invoke `mount`** | Blocks Mac App Store distribution of a self-mounting client until macOS 27. |
| **Volumes are passive** | The kernel only re-enumerates a directory when its mtime changes. `jirafs` runs a background poll that bumps mtimes to make Finder refresh. Before macOS 27 there is no push-invalidation API. |

### 5.2 Bugs specific to network modules (macOS 27.0 beta, filed Aug 2026)

From [*Ten FSKit issues found building a network file system module*](https://developer.apple.com/forums/thread/842736)
(the author was building an SMB 2/3 client as an FSKit module). All were filed with minimal
repros; none had an Apple reply at the time of writing. Directly applicable to 9P:

1. **FB24419773** — `renameatx_np(RENAME_SWAP)` silently performs a clobbering rename and returns
   success, destroying the destination. `renameItem` receives no flags, so the module cannot even
   refuse. (`RENAME_EXCL` is fine.)
2. **FB24419825** — **negative lookups are cached permanently.** Once a name returns `ENOENT`, the
   kernel serves that error for the vnode's lifetime. A file created later on the server is listed
   by `ls` but cannot be opened. There is no API to say "this name exists now". *This is the single
   most damaging bug for a shared network filesystem.*
3. **FB24419858** — data-cache grant in `FSOpenItemResult` is applied *after* the reply, so an
   invalidation issued in that window is overwritten; readers see permanently stale data.
4. **FB24419870** — **`synchronize(flags:)` is never called on a URL-backed volume.** `fsync(2)`,
   `F_FULLFSYNC`, `F_BARRIERFSYNC` and `sync(8)` all return success without reaching the module.
   Durability is reported but never established. (Measured: 5 SMB2 FLUSH via Apple's `smbfs`, 0 via
   the FSKit module.)
5. **FB24419894** — `FSItemSetAttributesRequest.consumedAttributes` is never observed;
   `wasAttributeConsumed(.changeTime)` answers incorrectly. `chmod` returns 0 whether or not you
   applied anything.
6. **FB24419911** — `restrictsOwnershipChanges = true` does not actually reject non-superuser
   `chown`; every module must enforce it itself.
7. **FB24419932** — a failed `activate` **wedges the resource URL**: every later mount of the same
   URL string fails with "Resource busy" until you kill `fskitd` *and* the extension. The ordinary
   trigger for a network module is **one wrong password**.
8. **FB24419964** — enumeration cannot report xattr presence. One cold `ls -l` of a 500-entry
   directory costs ~2,000 FSKit boundary crossings (xattr + AppleDouble `._name` lookup per entry,
   each `ENOENT` then pinned by #2).
9. **FB24419974** — **no byte-range locks.** `flock(2)` and `fcntl(2)` locks stay kernel-local and
   never reach the module, so advisory locks cannot coordinate between clients.
10. **FB24419979** — **no ACL or security-descriptor operations.** `ls -le`, `chmod +a`,
    `acl_get_file(3)` and `cp -p` with ACLs cannot work. `FSVolumeAccessCheckHandler` can only
    answer yes/no about a descriptor the module cannot supply.

For 9P specifically: #2, #4, #7 and #9 are the ones that will bite. Plan around them —
short-TTL revalidation, your own `Tflush`/`Tclunk` durability contract, defensive
`containerStatus` reset, and no reliance on POSIX locks over the mount.

### 5.3 Reported macOS 26 breakage

[`andrewgazelka/loaf` issue #1](https://github.com/andrewgazelka/loaf/issues/1) reports that
third-party FSKit extensions fail on **macOS 26.1 (25B78)** and **26.2 (25C56)** — `fskitd` logs
`Hello FSClient! entitlement no` and extension startup fails with
`com.apple.extensionKit.errorDomain Code=2`. Developer ID signing, notarization, hardened runtime,
and disabling library validation all failed to fix it. Referenced FB18230524 / FB17772372.

**Caveat:** the log line quoted (`Hello FSClient! entitlement no`) is about an *unentitled
FSClient connection*, which is also the normal state for an unprivileged client calling
`fetchInstalledExtensions` — so this may be a red herring. Multiple projects (`jirafs`, the SMB
module, OpenZFS) were demonstrably mounting in the same period. **Treat as environment-specific
but verify on your exact target point releases.**

Related, separately confirmed: Apple's built-in read-only NTFS driver blocks third-party FSKit
modules from being probed via DiskArbitration; *"FSKit modules are always relegated to fallback
status after all kext modules"* (FB18230524,
[thread 788609](https://developer.apple.com/forums/thread/788609)). Not relevant to a URL-mounted
9P filesystem, which never goes through DiskArbitration.

---

## 6. Real-world proof: `srz-zumix/jirafs`

[`jirafs`](https://github.com/srz-zumix/jirafs) mounts Jira and Confluence — pure HTTPS, no block
device, no local backing file — as read-only macOS filesystems via FSKit. It is the closest
existing analogue to `fs9kit`.

**Mount command** ([README](https://github.com/srz-zumix/jirafs/blob/main/README.md)):

```sh
mkdir -p ~/jirafs/myinstance
sudo mount -F -t jirafs -o ro jira://mycompany.atlassian.net ~/jirafs/myinstance

ls ~/jirafs/myinstance/projects/
cat ~/jirafs/myinstance/projects/PROJ/issues/PROJ-1/summary.txt

sudo diskutil unmount ~/jirafs/myinstance
```

**Info.plist** ([`jirafs-extension/Info.plist`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/Info.plist)) —
the network-FS configuration in full:

```xml
<key>EXAppExtensionAttributes</key>
<dict>
    <key>EXExtensionPointIdentifier</key>
    <string>com.apple.fskit.fsmodule</string>
    <key>FSActivateOptionSyntax</key>
    <dict><key>shortOptions</key><string>o:</string></dict>
    <key>FSShortName</key>
    <string>jirafs</string>
    <key>FSSupportedSchemes</key>
    <array><string>jira</string></array>
    <key>FSSupportsBlockResources</key>
    <false/>
    <key>FSSupportsGenericURLResources</key>
    <true/>
    <key>FSSupportsPathURLs</key>
    <false/>
    <key>FSSupportsServerURLs</key>
    <true/>
    <key>FSSupportsURLMounting</key>
    <true/>
</dict>
```

**Entitlements** ([`jirafs-extension.entitlements`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/jirafs-extension.entitlements)):

```xml
<key>com.apple.developer.fskit.fsmodule</key><true/>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>
<key>keychain-access-groups</key>
<array><string>$(AppIdentifierPrefix)com.zumix.jirafs.shared</string></array>
```

**`loadResource` / `probeResource`**
([`JiraFileSystem.swift`](https://github.com/srz-zumix/jirafs/blob/main/jirafs-extension/JiraFileSystem.swift)) —
note the three hard-won comments:

```swift
func loadResource(resource: FSResource, options: FSTaskOptions,
                  replyHandler reply: @escaping (FSVolume?, Error?) -> Void) {
    do {
        // For URL-based resources (jira://), fskitd skips probeResource and
        // calls loadResource directly. FSKit requires containerStatus == .ready
        // before it processes the reply(volume:) call, so we ensure it here.
        self.containerStatus = .ready
        let mountID = JiraFileSystem.hostname(from: resource, taskOptions: options.taskOptions)
        …
        let volume = JiraVolume(name: volumeName, dataSource: dataSource, …)
        // FSKit automatically transitions containerStatus notReady → active
        // when reply(volume, nil) is called. Do NOT set it manually here
        // or FSKit reports "unexpected container state".
        reply(volume, nil)
    } catch {
        reply(nil, FSKitError.from(error))
    }
}

func unloadResource(resource: FSResource, options: FSTaskOptions,
                    replyHandler reply: @escaping (Error?) -> Void) {
    // Reset to ready so fskitd can re-probe and re-load the same containerID
    // on a subsequent mount without needing a fskitd restart.
    self.containerStatus = .ready
    reply(nil)
}

func probeResource(resource: FSResource,
                   replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
    let mountID = JiraFileSystem.hostname(from: resource, taskOptions: [])
    …
    // Deterministic UUID keyed on the mountID so fskitd recognises the same
    // container across the probe → load state machine. Using a random UUID
    // causes EAGAIN because fskitd treats every attempt as an unknown container
    // and immediately closes it.
    let containerID = FSContainerIdentifier(uuid: JiraFileSystem.deterministicUUID(for: seedKey))
    self.containerStatus = .ready
    reply(.usable(name: name, containerID: containerID), nil)
}
```

**Extracting the URL from the resource** — a portability trick worth stealing, since it works for
both `FSGenericURLResource` (public) and `FSServerURLResource` (private) without linking either:

```swift
static func hostname(from resource: FSResource, taskOptions: [String]) -> String? {
    // FSResource may carry a URL property (non-public on some subclasses).
    // Use KVC so we don't crash if the property doesn't exist.
    if resource.responds(to: NSSelectorFromString("url")),
       let url = (resource as AnyObject).value(forKey: "url") as? URL,
       let host = url.host {
        return host
    }
    for opt in taskOptions {
        if let url = URL(string: opt), url.scheme == "jira", let host = url.host { return host }
    }
    return nil
}
```

For `fs9kit` you can just do `guard let r = resource as? FSGenericURLResource else { … }` and read
`r.url` — that is public API on macOS 26.

### Other projects worth reading

- **[Apple's `PassthroughFS`](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system)**
  ([zip](https://docs-assets.developer.apple.com/published/0b4283600908/BuildingAPassthroughFileSystem.zip)) —
  the reference for `FSPathURLResource`, a complete `FSVolume.Operations` implementation,
  and the canonical `Info.plist`/entitlements. **Read this first.**
- **[`KhaosT/FSKitSample`](https://github.com/KhaosT/FSKitSample)** — the original community sample.
  Block-device only: `mount -F -t MyFS disk18 /tmp/TestVol`, with
  `hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount dummy` to make a test device.
- **[`debox-network/FSKitBridge`](https://github.com/debox-network/FSKitBridge)** — an appex that
  proxies FSKit over localhost TCP (length-prefixed protobuf) to a Rust/C/Go/Python backend, with
  a Rust companion crate [`fskit-rs`](https://crates.io/crates/fskit-rs). **Note: it is
  block-device-based** (`FSSupportsBlockResources = true`, `FSSupportsPathURLs = false`,
  `FSSupportsGenericURLResources = false`) and requires a raw disk image, so despite the name it is
  *not* a network-FS proof. Its value is the Info.plist key inventory (it is where
  `FSSupportsServerURLs` first showed up in public code) and the out-of-process-backend pattern —
  which is a plausible architecture for `fs9kit` if the 9P core lives in Rust or Go.
- **[`blocksense-network/agent-harbor`](https://github.com/blocksense-network/agent-harbor)** —
  bridges FSKit to a Rust `FsCore` over C FFI, with an XPC control plane
  (`com.agent-harbor.fskit.control`). Extension at
  `adapters/macos/xcode/AgentFSKitExtension/`, FFI at `crates/agentfs-ffi/src/c_api.rs`.
  I could **not** clone this repo from this session, so the specifics above come from
  [DeepWiki](https://deepwiki.com/blocksense-network/agent-harbor/5.4-fskit-implementation-(macos)),
  which is AI-generated and lists at least one entitlement that does not exist
  (`com.apple.developer.file-system.fskit`). **Treat as UNCONFIRMED**; verify against source.
- **[macFUSE 5.2.0](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html)** — FSKit backend
  selected with `-o backend=fskit`; `rclone mount -o backend=fskit` mounts arbitrary network
  remotes with no kext. Known limits: mount points must be under `/Volumes`, files default to
  read/write regardless of intent, no FUSE notification API, no caller context, many mount options
  unimplemented, slower than the kext ([FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)).
- **[OpenZFS on FSKit PoC](https://developer.apple.com/forums/thread/828035)** — block-device based,
  but the DTS answers in that thread are the best public source on FSKit's sandbox model,
  async task rules, and container/volume identifier matching.
- **[`macos-fuse-t/fuse-t` #69](https://github.com/macos-fuse-t/fuse-t/issues/69)** — FSKit support
  requested, **not implemented**. fuse-t remains NFS-loopback based.

---

## 7. Copy-pasteable minimal FSKit unary filesystem (Swift)

A complete, compiling skeleton for a **read-only, URL-mounted, in-memory** filesystem. Swap the
`Backend` calls for 9P `Twalk`/`Tread`/`Tstat`. Targets **macOS 26.0**.

Layout:

```
fs9kit.app/
├── Contents/MacOS/fs9kit                    ← host app (NOT sandboxed)
└── Contents/Extensions/fs9kitAppEx.appex/
    ├── Contents/MacOS/fs9kitAppEx
    └── Contents/Info.plist                  ← §3.1
```

### `fs9kitAppEx.swift` — extension entry point

```swift
import Foundation
import FSKit

@main
struct Fs9kitAppEx: UnaryFileSystemExtension {
    typealias FileSystem = FSUnaryFileSystem & FSUnaryFileSystemOperations
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations { Fs9kitFileSystem() }
}
```

### `Fs9kitFileSystem.swift` — `FSUnaryFileSystemOperations`

```swift
import Foundation
import FSKit
import CryptoKit
import os

extension Logger {
    static let fs9kit = Logger(subsystem: "com.example.fs9kit", category: "default")
}

/// Current errno as a POSIXError, for bridging Darwin calls.
var posixErrno: POSIXError { POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL) }

@objc(Fs9kitFileSystem)
final class Fs9kitFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, @unchecked Sendable {

    private var resource: FSGenericURLResource?

    override init() { super.init() }

    // MARK: probe

    /// NOTE: for FSGenericURLResource, mount(8)/fskitd SKIP this and call loadResource directly.
    /// Implement it anyway — it is a required protocol member.
    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let url = Self.url(of: resource) else {
            return reply(.notRecognized, nil)
        }
        // The containerID MUST be stable across probe → load, and MUST match the
        // FSVolume.Identifier used to construct the volume, or loadResource gets EAGAIN.
        let containerID = FSContainerIdentifier(uuid: Self.stableUUID(for: url.absoluteString))
        self.containerStatus = .ready
        reply(.usable(name: Self.volumeName(for: url), containerID: containerID), nil)
    }

    // MARK: load / unload

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSGenericURLResource else {
            Logger.fs9kit.error("loadResource: not an FSGenericURLResource")
            return reply(nil, POSIXError(.EINVAL))
        }
        let url = urlResource.url
        guard let scheme = url.scheme?.lowercased(), scheme == "9p" || scheme == "9pfs" else {
            return reply(nil, POSIXError(.EINVAL))
        }

        // -f means "force load without creating a volume" (for format). We don't format.
        var readOnly = false
        for opt in options.taskOptions {
            if opt.contains("-f") { return reply(nil, POSIXError(.ENOTSUP)) }
            let fields = Set(opt.split(separator: ",").map(String.init))
            if fields.contains("ro") || fields.contains("rdonly") { readOnly = true }
        }

        // Probe is skipped for URL resources, so ensure .ready here.
        // Do NOT set .active — FSKit transitions notReady → active on reply(volume, nil).
        self.containerStatus = .ready
        self.resource = urlResource

        do {
            let backend = try NinePBackend(url: url)          // <-- your 9P client: Tversion/Tattach
            let volume = Fs9kitVolume(
                volumeID: FSVolume.Identifier(uuid: Self.stableUUID(for: url.absoluteString)),
                volumeName: FSFileName(string: Self.volumeName(for: url)),
                backend: backend,
                readOnly: readOnly)
            Logger.fs9kit.info("mounted \(url.absoluteString, privacy: .public)")
            reply(volume, nil)
        } catch {
            self.resource = nil
            self.containerStatus = .ready
            reply(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping ((any Error)?) -> Void) {
        // Reset to .ready or the next mount of the same URL fails with "Resource busy"
        // (fskitd: "resource state is 5") until fskitd is killed.
        self.containerStatus = .ready
        self.resource = nil
        reply(nil)
    }

    func didFinishLoading() { Logger.fs9kit.info("fs9kit module loaded") }

    // MARK: helpers

    /// Works for FSGenericURLResource and (via KVC) for private URL-bearing resources.
    static func url(of resource: FSResource) -> URL? {
        if let r = resource as? FSGenericURLResource { return r.url }
        if resource.responds(to: NSSelectorFromString("url")) {
            return (resource as AnyObject).value(forKey: "url") as? URL
        }
        return nil
    }

    static func volumeName(for url: URL) -> String { url.host ?? "fs9kit" }

    /// RFC 4122 v5-style name-based UUID. Stability matters: a random UUID makes
    /// fskitd treat each mount attempt as an unknown container and close it.
    static func stableUUID(for key: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        b[6] = (b[6] & 0x0f) | 0x50
        b[8] = (b[8] & 0x3f) | 0x80
        return UUID(uuid: (b[0], b[1], b[2],  b[3],  b[4],  b[5],  b[6],  b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
```

### `Fs9kitItem.swift` — `FSItem` subclass

```swift
import Foundation
import FSKit

final class Fs9kitItem: FSItem {
    let fid: UInt32                 // 9P fid / qid.path
    let itemID: FSItem.Identifier
    var name: String
    var itemType: FSItem.ItemType
    var parent: Fs9kitItem?

    init(fid: UInt32, itemID: UInt64, name: String,
         type: FSItem.ItemType, parent: Fs9kitItem?) {
        self.fid = fid
        self.itemID = FSItem.Identifier(rawValue: itemID) ?? .invalid
        self.name = name
        self.itemType = type
        self.parent = parent
        super.init()
    }
}
```

### `Fs9kitVolume.swift` — the volume

```swift
import Foundation
import FSKit
import os

final class Fs9kitVolume: FSVolume, @unchecked Sendable {

    let backend: NinePBackend
    let readOnly: Bool
    let rootItem: Fs9kitItem

    private var itemCache: [UInt64: Fs9kitItem] = [:]
    private let cacheQueue = DispatchQueue(label: "com.example.fs9kit.itemcache")

    init(volumeID: FSVolume.Identifier, volumeName: FSFileName,
         backend: NinePBackend, readOnly: Bool) {
        self.backend  = backend
        self.readOnly = readOnly
        self.rootItem = Fs9kitItem(fid: backend.rootFid, itemID: 1, name: "/",
                                   type: .directory, parent: nil)
        super.init(volumeID: volumeID, volumeName: volumeName)
    }

    // MARK: - FSVolume.PathConfOperations

    var maximumLinkCount: Int         { 1 }        // 9P2000.L: no hard links by default
    var maximumNameLength: Int        { 255 }
    var restrictsOwnershipChanges: Bool { true }   // NOTE: FSKit does NOT enforce this (FB24419911)
    var truncatesLongNames: Bool      { false }
    var maximumFileSizeInBits: Int    { 64 }
}

// MARK: - FSVolume.Operations (required)

extension Fs9kitVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let c = FSVolume.SupportedCapabilities()
        c.supportsSymbolicLinks   = true
        c.supportsHardLinks       = false
        c.supportsPersistentObjectIDs = true
        c.supports64BitObjectIDs  = true
        c.supports2TBFiles        = true
        c.supportsSparseFiles     = false
        c.supportsHiddenFiles     = true
        c.supportsFastStatFS      = false          // statfs is a network round trip
        c.doesNotSupportImmutableFiles = true
        c.doesNotSupportSettingFilePermissions = readOnly
        c.caseFormat = .sensitive                  // 9P servers are typically case-sensitive
        return c
    }

    var volumeStatistics: FSStatFSResult {
        let r = FSStatFSResult(fileSystemTypeName: "fs9kit")
        let s = backend.statfs()                   // 9P2000.L Tstatfs, or synthesised
        r.blockSize      = s.blockSize
        r.ioSize         = s.ioSize                // msize - header; tune this
        r.totalBlocks    = s.totalBlocks
        r.availableBlocks = s.availableBlocks
        r.freeBlocks     = s.freeBlocks
        r.usedBlocks     = s.totalBlocks - s.freeBlocks
        r.totalFiles     = s.totalFiles
        r.freeFiles      = s.freeFiles
        return r
    }

    func activate(options: FSTaskOptions,
                  replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        // Return the ROOT item. Any error thrown here wedges the resource URL
        // until fskitd restarts (FB24419932) — fail early in loadResource instead.
        reply(rootItem, nil)
    }

    func deactivate(options: FSDeactivateOptions = [],
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        backend.close()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        backend.close()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        // WARNING: on a URL-backed volume this is currently NEVER called (FB24419870).
        // Do not rely on it for durability.
        do { try backend.fsyncAll(); reply(nil) } catch { reply(error) }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let it = item as? Fs9kitItem else { return reply(POSIXError(.EINVAL)) }
        if it !== rootItem {
            cacheQueue.sync { _ = itemCache.removeValue(forKey: it.itemID.rawValue) }
            backend.clunk(it.fid)                  // 9P Tclunk
        }
        reply(nil)
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        guard let dir = directory as? Fs9kitItem, dir.itemType == .directory else {
            return reply(nil, nil, POSIXError(.ENOTDIR))
        }
        guard let n = name.string else { return reply(nil, nil, POSIXError(.EINVAL)) }
        do {
            // WARNING: an ENOENT here is cached by the kernel for the vnode's lifetime
            // (FB24419825). A file created on the server afterwards will list but not open.
            let e = try backend.walk(from: dir.fid, name: n)
            let item = cacheQueue.sync { () -> Fs9kitItem in
                if let cached = itemCache[e.qidPath] { return cached }
                let fresh = Fs9kitItem(fid: e.fid, itemID: e.qidPath, name: n,
                                       type: e.type, parent: dir)
                itemCache[e.qidPath] = fresh
                return fresh
            }
            reply(item, FSFileName(string: n), nil)
        } catch {
            reply(nil, nil, error)
        }
    }

    func getAttributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard let it = item as? Fs9kitItem else { return reply(nil, POSIXError(.EINVAL)) }
        do {
            let st = try backend.getattr(it.fid)   // 9P2000.L Tgetattr
            let a = FSItem.Attributes()
            // Finder needs ALL of these populated or the volume will not appear.
            a.type       = it.itemType
            a.fileID     = it.itemID
            a.parentID   = it.parent?.itemID ?? FSItem.Identifier.parentOfRoot
            a.uid        = st.uid
            a.gid        = st.gid
            a.mode       = st.mode
            a.flags      = 0
            a.linkCount  = st.nlink
            a.size       = st.size
            a.allocSize  = st.blocks * 512
            a.accessTime = st.atime
            a.modifyTime = st.mtime
            a.changeTime = st.ctime
            a.birthTime  = st.btime
            reply(a, nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        guard !readOnly else { return reply(nil, POSIXError(.EROFS)) }
        // 9P2000.L Tsetattr. NOTE: consumedAttributes is never observed by FSKit (FB24419894),
        // so callers cannot tell which attributes you actually applied.
        reply(nil, POSIXError(.ENOTSUP))
    }

    func enumerateDirectory(_ directory: FSItem,
                            startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        guard let dir = directory as? Fs9kitItem, dir.itemType == .directory else {
            return reply(FSDirectoryVerifier(0), fs_errorForPOSIXError(ENOTDIR))
        }
        do {
            // 9P2000.L Treaddir; the 9P offset maps onto FSDirectoryCookie.
            var offset = cookie.rawValue
            while true {
                let batch = try backend.readdir(fid: dir.fid, offset: offset)
                if batch.isEmpty { break }
                for e in batch {
                    offset = e.nextOffset
                    if e.name == "." || e.name == ".." { continue }
                    var attrs: FSItem.Attributes? = nil
                    if attributes != nil { attrs = try? self.attributes(for: e) }
                    let ok = packer.packEntry(
                        name: FSFileName(string: e.name),
                        itemType: e.type,
                        itemID: FSItem.Identifier(rawValue: e.qidPath) ?? .invalid,
                        nextCookie: FSDirectoryCookie(offset),
                        attributes: attrs)
                    if !ok { return reply(FSDirectoryVerifier(0), nil) }   // buffer full
                }
            }
            reply(FSDirectoryVerifier(0), nil)
        } catch {
            reply(FSDirectoryVerifier(0), error)
        }
    }

    func readSymbolicLink(_ item: FSItem,
                          replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        guard let it = item as? Fs9kitItem else { return reply(nil, POSIXError(.EINVAL)) }
        do { reply(FSFileName(string: try backend.readlink(it.fid)), nil) }
        catch { reply(nil, error) }
    }

    // --- Read-only stubs. Implement these for a writable 9P mount. ---

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, POSIXError(readOnly ? .EROFS : .ENOTSUP))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, POSIXError(.ENOTSUP))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        reply(nil, nil, POSIXError(readOnly ? .EROFS : .ENOTSUP))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem,
                    replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(POSIXError(readOnly ? .EROFS : .ENOTSUP))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        // WARNING: RENAME_SWAP is indistinguishable from a clobbering rename here — you
        // receive no flags (FB24419773). A naive implementation silently destroys data.
        reply(nil, POSIXError(readOnly ? .EROFS : .ENOTSUP))
    }

    private func attributes(for e: NinePDirEntry) throws -> FSItem.Attributes {
        let a = FSItem.Attributes()
        a.type = e.type
        a.fileID = FSItem.Identifier(rawValue: e.qidPath) ?? .invalid
        return a
    }
}

// MARK: - FSVolume.OpenCloseOperations (optional)

extension Fs9kitVolume: FSVolume.OpenCloseOperations {
    func openItem(_ item: FSItem, modes: FSVolume.OpenModes,
                  replyHandler reply: @escaping ((any Error)?) -> Void) {
        guard let it = item as? Fs9kitItem else { return reply(POSIXError(.EINVAL)) }
        do { try backend.open(it.fid, modes: modes); reply(nil) } catch { reply(error) }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes,
                   replyHandler reply: @escaping ((any Error)?) -> Void) {
        reply(nil)   // keep the fid; reclaimItem clunks it
    }
}

// MARK: - FSVolume.ReadWriteOperations (optional)

extension Fs9kitVolume: FSVolume.ReadWriteOperations {
    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard let it = item as? Fs9kitItem else { return reply(0, POSIXError(.EINVAL)) }
        do {
            var got = 0
            try buffer.withUnsafeMutableBytes { raw in
                got = try backend.read(fid: it.fid, offset: UInt64(offset),
                                       count: min(length, raw.count), into: raw)
            }
            reply(got, nil)
        } catch {
            reply(0, error)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        guard !readOnly else { return reply(0, POSIXError(.EROFS)) }
        guard let it = item as? Fs9kitItem else { return reply(0, POSIXError(.EINVAL)) }
        do { reply(try backend.write(fid: it.fid, offset: UInt64(offset), data: contents), nil) }
        catch { reply(0, error) }
    }
}
```

### Build, install, enable, mount

```sh
# Build a SIGNED extension. Unsigned appexes are rejected by fskitd.
xcodebuild -project fs9kit.xcodeproj -scheme fs9kit -configuration Release \
           -allowProvisioningUpdates build

sudo cp -R build/Release/fs9kit.app /Applications/

# Re-register after every reinstall — fskitd caches the old bundle UUID.
sudo kill $(pgrep fskitd) 2>/dev/null; sleep 3
sudo pluginkit -a /Applications/fs9kit.app/Contents/Extensions/fs9kitAppEx.appex
sudo pluginkit -e use -i com.example.fs9kit.appex
pluginkit -m -A -i com.example.fs9kit.appex          # verify

# ...or enable via the UI:
#   System Settings → General → Login Items & Extensions
#   → Extensions → File System Extensions → ⓘ → toggle "fs9kit"

mkdir -p /Volumes/fs9kit    # or ~/mnt/fs9kit
sudo /sbin/mount -F -t fs9kit -o ro 9p://127.0.0.1:5640/ /Volumes/fs9kit

ls /Volumes/fs9kit
mount | grep fs9kit

sudo /usr/sbin/diskutil unmount /Volumes/fs9kit
```

### Debugging

```sh
log stream --info --debug \
  --predicate 'subsystem == "com.example.fs9kit" OR process CONTAINS "fskitd" OR process CONTAINS "fskit_agent"'

log show --last 10m --style compact \
  --predicate 'subsystem CONTAINS "fs9kit" OR process CONTAINS "fskitd"' | tail -80
```

Error decoder:

| Symptom | Cause |
|---|---|
| `File system named fs9kit not found` | Extension not registered, or `FSShortName` mismatch |
| `Module <id> is disabled!` | Not enabled in System Settings / `pluginkit -e use` |
| `Filesystem fs9kit supports neither Block Device nor PathURL resources nor ServerURL resources` | No `FSSupports*` flag set true — or you're on macOS 15.x, where the GenericURL branch does not exist |
| `Filesystem fs9kit does not support operation mount` | `FSActivateOptionSyntax` missing from `Info.plist` |
| `loadResource: … EAGAIN` / *"unexpected container state"* | `containerStatus` not `.ready`, or probe's `containerID` ≠ volume's `volumeID` |
| `Resource busy` / *"resource state is 5"* | A previous `activate` failed. Reset `containerStatus = .ready` in `unloadResource`; kill `fskitd` to recover |
| `com.apple.extensionKit.errorDomain error 2` | Stale LaunchServices UUID — `lsregister -R -f -u`, or restart `fskitd` |
| Volume mounts but is invisible in Finder | `getAttributes` is not returning every requested attribute — especially `modifyTime` ([thread 784055](https://developer.apple.com/forums/thread/784055)) |
| `Unable to invoke task` under plain `sudo mount -F` | Known: root execution of `mount -F` does not always find FSKit modules ([thread 788609](https://developer.apple.com/forums/thread/788609)); `SUDO_UID` handling in `fskit_support.m` is meant to address this |

---

## 8. Recommendation for `fs9kit`

Keep the **NFSv3 loopback bridge** from [`mount-approaches.md`](./mount-approaches.md) as the
default backend: it works on macOS 11–27, needs no entitlement, no System Settings toggle, no
signing identity, and runs in CI on GitHub-hosted runners.

Add **FSKit as a second backend, gated on macOS 26.0+**, using `FSGenericURLResource` with a
`9p://` scheme. It buys real VFS semantics without a loopback NFS hop, better Finder integration,
and a path to Apple's cache-coherency APIs in macOS 27. Budget for the ten network-FS bugs in
§5.2 — in particular design around permanently-cached negative lookups (#2) and the absence of
`synchronize` (#4) and byte-range locks (#9).

Do **not** use `FSServerURLResource` / `FSServerURLUnaryOperations`. Private API, App Store
poison, and `FSGenericURLResource` does the same job in public.

---

## Sources

**Apple primary**
- [FSKit framework](https://developer.apple.com/documentation/fskit)
- [Building a passthrough file system](https://developer.apple.com/documentation/fskit/building-a-passthrough-file-system) · [sample zip](https://docs-assets.developer.apple.com/published/0b4283600908/BuildingAPassthroughFileSystem.zip)
- [FSResource](https://developer.apple.com/documentation/fskit/fsresource) · [FSPathURLResource](https://developer.apple.com/documentation/fskit/fspathurlresource) · [FSGenericURLResource](https://developer.apple.com/documentation/fskit/fsgenericurlresource) · [FSBlockDeviceResource](https://developer.apple.com/documentation/fskit/fsblockdeviceresource)
- [FSUnaryFileSystem](https://developer.apple.com/documentation/fskit/fsunaryfilesystem) · [FSUnaryFileSystemOperations](https://developer.apple.com/documentation/fskit/fsunaryfilesystemoperations) · [FSVolume](https://developer.apple.com/documentation/fskit/fsvolume) · [UnaryFileSystemExtension](https://developer.apple.com/documentation/fskit/unaryfilesystemextension)
- [FSClient](https://developer.apple.com/documentation/fskit/fsclient) · [FSTaskOptions](https://developer.apple.com/documentation/fskit/fstaskoptions) · [FSProbeResult](https://developer.apple.com/documentation/fskit/fsproberesult)
- [`com.apple.developer.fskit.fsmodule`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- [Supported capabilities (macOS)](https://developer.apple.com/help/account/reference/supported-capabilities-macos) · [Provisioning with managed capabilities](https://developer.apple.com/help/account/reference/provisioning-with-managed-capabilities/)
- [`fskit_agent(8)`](https://manp.gs/mac/8/fskit_agent)

**Apple open source**
- [`diskdev_cmds/disklib/fskit_support.m`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/disklib/fskit_support.m) — resource construction, probe/load/activate/mount sequence
- [`diskdev_cmds/mount.tproj/mount.c`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/mount.tproj/mount.c) · [`mount.8`](https://github.com/apple-oss-distributions/diskdev_cmds/blob/main/mount.tproj/mount.8) — `-F` and the auto-fallback
- [`msdosfs/msdos_appex/Info.plist`](https://github.com/apple-open-source/macos/blob/master/msdosfs/msdos_appex/Info.plist) · [`hfs/hfs_appex/Info.plist`](https://github.com/apple-open-source/macos/blob/master/hfs/hfs_appex/Info.plist) — Apple's own module plists

**Apple Developer Forums**
- [799283 — Mounting FSKit with FSPathURLResource](https://developer.apple.com/forums/thread/799283) — `/sbin/mount` is the supported API; App Sandbox blocker (FB20186709); KOIO limits
- [842736 — Ten FSKit issues found building a network file system module](https://developer.apple.com/forums/thread/842736)
- [831417 — FSKit and Network File Systems?](https://developer.apple.com/forums/thread/831417) — `DataCacheHandler` is for network FS
- [828035 — OpenZFS on FSKit — Proof of Concept](https://developer.apple.com/forums/thread/828035) — ad-hoc signing, sandbox rationale, container/volume ID matching
- [808594 — Enable FSKit module globally pre-login](https://developer.apple.com/forums/thread/808594) — per-user only
- [809747 — Safely updating an FSKit module via the Mac App Store](https://developer.apple.com/forums/thread/809747)
- [804432 — Failure to mount an FSKit volume *sometimes*](https://developer.apple.com/forums/thread/804432) — LaunchServices UUID staleness
- [797485 — Mount an FSKit volume](https://developer.apple.com/forums/thread/797485) — DiskArbitration status
- [788609 — FSKit module mount fails with permission errors](https://developer.apple.com/forums/thread/788609) — FB18230524, pluginkit re-registration
- [784055 — How to mount custom FSKit-based file system in Finder?](https://developer.apple.com/forums/thread/784055) — required attributes for Finder
- [776322 — FSKit](https://developer.apple.com/forums/thread/776322) — the (now obsolete) "network FS not supported" statement
- [765424 — Porting VFS kext to FSKit](https://developer.apple.com/forums/thread/765424) — FSKit absent from the 15.0 SDK

**Third-party implementations**
- [`srz-zumix/jirafs`](https://github.com/srz-zumix/jirafs) — network FS over `FSGenericURLResource`
- [`KhaosT/FSKitSample`](https://github.com/KhaosT/FSKitSample)
- [`debox-network/FSKitBridge`](https://github.com/debox-network/FSKitBridge) · [`fskit-rs`](https://crates.io/crates/fskit-rs)
- [`blocksense-network/agent-harbor`](https://github.com/blocksense-network/agent-harbor) (details UNCONFIRMED)
- [macFUSE 5.2.0](https://macfuse.github.io/2026/04/09/macfuse-5.2.0.html) · [FUSE Backends wiki](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)
- [`andrewgazelka/loaf` #1](https://github.com/andrewgazelka/loaf/issues/1) · [`macfuse/macfuse` #1132](https://github.com/macfuse/macfuse/issues/1132) · [`macos-fuse-t/fuse-t` #69](https://github.com/macos-fuse-t/fuse-t/issues/69)

**API dumps**
- [dotnet/macios wiki — FSKit macOS xcode16.3 b1](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode16.3-b1) (the 15.4 surface)
- [dotnet/macios wiki — FSKit macOS xcode26.0 b1](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode26.0-b1) (the 26.0 diff)
- [dotnet/macios wiki — FSKit macOS xcode16.3 b2](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode16.3-b2)
</content>
</invoke>
