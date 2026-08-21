# The FSKit backend

How `fs9kit` mounts a 9P server as a native macOS volume, what the code is
shaped like and why, and which FSKit bugs it is built around.

Background and every primary source: [`../research/fskit-api.md`](../research/fskit-api.md).
Why this backend exists alongside the NFS loopback one: [`../DECISIONS.md`](../DECISIONS.md).
How to build, install and run it: [`../../macos/README.md`](../../macos/README.md).

---

## 1. Shape

```
mount(8)  ──URL──▶  fskitd  ──▶  FS9KitExtension.appex
                                   │
                                   ├── FS9UnaryFileSystem   probe / load / unload
                                   ├── FS9Volume            the FSVolume.*Operations
                                   ├── FS9Item              one object per file
                                   │
                                   └── FS9KitAdapter (pure)  ── NineVFS ── NinePClient ── 9P server
```

Everything is in one SwiftPM target, `FS9KitAdapter`, split into two halves by a
single `#if canImport(FSKit)`:

| | Where | Compiles on Linux | Tested on Linux |
|---|---|---|---|
| Mount-URL parsing | `MountURL.swift` | yes | yes |
| Attribute, time, mode, identifier translation | `ItemTranslation.swift` | yes | yes |
| Errno mapping | `ErrorTranslation.swift` | yes | yes |
| Directory planning | `DirectoryPlan.swift` | yes | yes |
| Item interning | `ItemTable.swift` | yes | yes |
| Container UUID derivation | `StableUUID.swift` | yes | yes |
| FSKit glue | `FSKit/*.swift` | no | no |

The split is not tidiness. FSKit cannot be compiled anywhere but a Mac and
cannot be *run* anywhere but an interactively-configured Mac, so every decision
that can be made without it is made in a pure function that a Linux CI job
exercises. What is left in the glue is parameter shuffling: no arithmetic, no
policy, no string parsing.

The `macos/` directory adds only two Swift files — a SwiftUI container app and
a six-line `@main` — because `@main` cannot live in a library. Both targets link
the same package.

## 2. The mount URL

An FSKit module with `FSSupportsGenericURLResources` receives exactly one string
from `mount(8)`, so that string carries the address *and* the configuration:

```
9p://[user@]host[:port]/[aname][?options]
9p+unix:///path/to/socket?aname=tree
```

`MountSpec.parse` turns it into an endpoint, 9P attach credentials, session
options and VFS options. Three decisions worth recording:

**It does not use `URL(string:)`.** `9p` is not a legal RFC 3986 scheme —
schemes must begin with a letter — so a strict parser returns `nil` for
`9p://host/`. Swift's Foundation on Linux does exactly that, verified. Since the
parser here is hand-rolled it accepts what a user will actually type, and the
tests can cover forms that `URL` would refuse to represent.

**`p9://` is registered as an alias.** This is the part that cannot be worked
around from inside the extension: `mount(8)` builds the resource with
`[NSURL URLWithString:argv[0]]` *before* anything of ours runs. If Apple's
`NSURL` is as strict as swift-corelibs-foundation, `9p://…` never reaches the
module at all. `p9`, `9pfs` and the `+unix` variants are all in
`FSSupportedSchemes` and all parse identically, so there is a spelling that
works whichever way that turns out. **This must be checked on a real macOS 26
machine**; if `9p://` works, the alias costs nothing.

**An unknown query key is an error.** A user who writes `?read-only` believes
the mount is read-only. Failing the mount is better than silently mounting
read-write. `-o ro` from `mount(8)` is folded in on top and can only ever turn
read-only *on*, never off.

**The canonical target** — `9p://host:port/aname`, lowercased, with options and
credentials stripped — is the string the container UUID is derived from. It has
to be a pure function of *what is being mounted* and nothing else; see §4.

## 3. The mount lifecycle

What actually happens on `sudo mount -F -t fs9kit 9p://host/tree /Volumes/x`:

1. `mount(8)` resolves `fs9kit` through `FSShortName` to an `FSModuleIdentity`.
   Not found → `ENOENT`. Not enabled by *this user* → `EINVAL`.
2. It parses `-o …` against `FSActivateOptionSyntax`; `ro`/`rdonly` set the
   writable flag.
3. It reads the four `FSSupports*` flags **in order** and takes the first true
   one. Ours is `FSSupportsGenericURLResources`, so `argv[0]` is parsed as a URL
   and becomes an `FSGenericURLResource`.
4. **`probeResource` is skipped.** `fskitd` probes only block-device and
   path-URL resources. `loadResource` is called directly.
5. `loadResource` dials the server, negotiates a dialect, attaches, and replies
   with an `FS9Volume`.
6. `activate` returns the root `FSItem`.
7. `LiveFSMountClient` performs the real VFS mount.
8. On any failure at step 7: `deactivate`, then `unloadResource`.

Steps 4–6 carry three undocumented rules, all of which cost a day each to
rediscover, and all of which are implemented in `FS9UnaryFileSystem`:

**`containerStatus` must be `.ready` before the reply.** Because probe is
skipped, nothing else will set it. `loadResource` sets it as its first act.

**`containerStatus` must not be set to `.active` by hand.** FSKit performs the
`notReady → active` transition itself when `reply(volume, nil)` is delivered;
setting it produces "unexpected container state".

**`unloadResource` must reset it to `.ready`.** Otherwise the next mount of the
same URL fails with "Resource busy" / "resource state is 5" until `fskitd` is
killed.

And one rule about where to fail: **everything that can fail is done in
`loadResource`, before the volume object exists.** A throw out of `activate`
wedges the resource URL — every later mount of the same string fails until
`fskitd` *and* the extension are killed (FB24419932) — and the ordinary trigger
for a network filesystem is one wrong hostname. So `activate` does nothing but
hand back the root item it was given at construction time.

## 4. Identity: containers, volumes and items

**Container and volume identifiers must match and must be stable.** `fskitd`
compares the `containerID` a module reports against the one it holds; an
identifier it has not seen means "unknown container", which it closes
immediately — surfacing as `EAGAIN` from `loadResource`. A random UUID therefore
fails *every* mount. `StableUUID.uuid(for: spec.canonicalTarget)` derives a
version-5-shaped UUID from a SHA-256 of the canonical target, and the same
function produces both the container identifier and the `FSVolume.Identifier`.

SHA-256 is implemented in the package rather than taken from CryptoKit because
this path has to be testable on Linux and the project takes no dependencies. It
is checked against the published NIST vectors, including the one-million-`a`
case that catches padding bugs.

**Item identifiers are shifted clear of FSKit's reserved range.** `NineVFS`
numbers its root node 1, which is almost certainly FSKit's `.parentOfRoot`
(HFS convention: root 2, parent-of-root 1). `FS9ItemIdentifier` maps the VFS
root onto FSKit's root identifier and every other node to `node + 2`, which is a
bijection onto identifiers ≥ 4. If the reserved values turn out to be different
on a real SDK, only three constants change.

**One `FSItem` per file, for as long as the kernel holds it.** FSKit decides
what is what by object identity: two objects for one inode make the kernel treat
them as two files, and a `reclaimItem` on one frees state the other still needs.
`FS9ItemTable` interns them under a lock — an `NSLock` and not an actor, because
every caller is an FSKit reply handler that must not suspend to read a
dictionary.

## 5. Concurrency

`NineVFS` is an actor; FSKit's protocols are Objective-C completion-handler
methods. Each operation is implemented in its completion-handler form (the shape
Apple's samples and `jirafs` use), validates its arguments synchronously so the
common errors are cheap, then hands off to a `Task` that awaits the actor and
calls the reply handler.

FSKit's parameter objects — `FSFileName`, `FSDirectoryEntryPacker`,
`FSMutableFileDataBuffer`, the attribute requests — are Objective-C classes with
no `Sendable` conformance, so crossing into that `Task` needs `UncheckedBox`.
That is sound here: each object belongs to exactly one in-flight operation and
FSKit keeps it alive until the reply handler runs. Where a value can be
extracted before the hop — a name as a `String`, a `SetAttributesRequest` as an
`FS9SetAttributes` — it is, and the box is not used.

One property fights this design: `volumeStatistics` is **synchronous** and 9P
`Tstatfs` is a round trip. Blocking an FSKit thread inside a property getter is
not acceptable, so the volume keeps a snapshot refreshed in the background after
`activate`, after `createItem` and after `removeItem`. Free-space numbers are
therefore slightly stale. `supportsFastStatFS` is advertised as `false` so the
kernel does not put `statfs` on a hot path.

## 6. Reads, writes, opens

`openItem` validates the mode — a write to a read-only volume is `EROFS` here,
not `EPERM`, because `EROFS` makes the kernel stop asking while `EPERM` makes it
retry as another user — and bumps a per-item open count. `closeItem` decrements
it and, on the last close, clunks the 9P fid. Servers have finite fid tables and
a long-lived mount that never clunks will exhaust them.

`FSVolume.ItemDeactivation` is implemented with an `.always` policy for the same
reason: hearing early that nobody wants a file is worth the extra calls when the
resource being conserved is server-side state.

An empty open-mode set means read. FSKit opens a vnode for metadata with no mode
bits, and 9P has no equivalent of `O_PATH`.

`read` copies into the FSKit buffer bounded by *both* the requested length and
the buffer's own length, and returns the byte count actually copied. `write`
takes the offset FSKit supplies; nothing here relies on an append mode.

## 7. Directory enumeration

The FSKit cookie is the 9P offset, unchanged. Both sides treat zero as "start"
and neither ascribes any other meaning to the value: 9P2000.L `Rreaddir` offsets
are opaque server tokens and `FSDirectoryCookie` is an opaque `UInt64`. Biasing
them — to make room for synthesised entries, say — breaks the moment a
`telldir`-based server returns an offset near the top of the range, which they
legitimately do. The tests cover `0` and `UInt64.max`.

`.` and `..` are dropped. 9P2000.L `Treaddir` includes them; Apple's sample code
does not pack them. **UNCONFIRMED** that FSKit synthesises them — if a mount
shows no `.` or `..`, `FS9DirectoryPlanner` is the one place to change.

A chunk that contains only `.` and `..` yields no packable entries and is *not*
the end of the listing, so "finished" is read off the chunk rather than off the
planned entries.

Attributes are packed per entry only when FSKit asks for them, and a failure to
fetch one entry's attributes does not fail the listing — the entry is packed
without them.

## 8. The FSKit bugs this is built around

Ten were filed in August 2026 by someone building an SMB client as an FSKit
module. Four matter to 9P.

**FB24419825 — negative lookups are cached permanently.** Once `lookupItem`
returns `ENOENT` for a name, the kernel serves that error for the vnode's
lifetime. A file created on the server afterwards is listed by `ls` and cannot
be opened. *There is no API to say "this name exists now".* Nothing in the
module can fix it. What the design does instead: `NineVFS` keeps its attribute
TTL short so positive entries revalidate quickly, the limitation is documented
where a user will hit it, and remounting is named as the workaround. This is the
single most damaging bug for a shared filesystem and it is the reason the NFS
loopback backend remains the default.

**FB24419870 — `synchronize(flags:)` is never called on a URL-backed volume.**
`fsync(2)`, `F_FULLFSYNC`, `F_BARRIERFSYNC` and `sync(8)` all return success
without reaching the module. Durability is *reported* but never *established*.
`synchronize` is implemented anyway — it walks the open items and issues 9P
`Tfsync` — so that it works the day the bug is fixed. Until then, a caller that
needs durability over this mount does not have it.

**FB24419932 — a failed `activate` wedges the resource URL.** Covered in §3:
everything fallible happens in `loadResource`, and `unloadResource` resets
`containerStatus` so a recoverable state remains reachable without killing
`fskitd`.

**FB24419974 — no byte-range locks.** `flock(2)` and `fcntl(2)` locks stay
kernel-local and never reach the module, so they cannot coordinate between
clients. 9P2000.L has `Tlock`/`Tgetlock` and the client speaks it, but there is
nothing to drive it with. Not advertised, not emulated: a lock that silently
does not lock is worse than no lock.

Two more shape the code without being fatal:

**FB24419894 — `consumedAttributes` is never observed**, so a caller cannot tell
which attributes a `setAttributes` actually applied. `chmod` returns 0 either
way. The response is to refuse a request wholesale rather than apply it
partially and report success.

**FB24419911 — `restrictsOwnershipChanges` is not enforced by FSKit.** The
property is advertised *and* the check is implemented in `FS9SetAttributes.validated`,
which refuses an unprivileged `chown` outright. Before macOS 27's `FSContext`
there is no caller identity available, so "unprivileged" is assumed.

**FB24419773 — `renameatx_np(RENAME_SWAP)` arrives as an ordinary clobbering
rename.** The module receives no flags and cannot refuse. Nothing can be done
except not to promise atomic swap in the volume capabilities, which it does not.

## 9. Structural limits

- **macOS 26.0 or later, no exceptions.** `FSGenericURLResource` and the
  `mount(8)` branch that constructs it both first ship in the macOS 26 line.
- **Per-user enablement only.** No MDM, no pre-login, no CLI that Apple
  supports. A 9P home directory cannot be mounted before login.
- **The container app cannot be sandboxed**, because App Sandbox forbids calling
  `/sbin/mount` — which also means a self-mounting FSKit client cannot ship on
  the Mac App Store until macOS 27's `FSClient.mountSingleVolume`.
- **One resource, one volume.** `FSFileSystem` (multi-resource) is not
  implemented in FSKit; mount N times for N trees.
- **`ReadWriteOperations` is the slow path**, by Apple's own description.
- **Volumes are passive.** Before macOS 27 there is no push-invalidation API;
  the kernel re-enumerates a directory only when its mtime changes.
- **`9p+unix://` needs an extra entitlement.** A sandboxed extension cannot
  reach an arbitrary unix socket; the socket must live in an app-group
  container. Parsed and supported by the code, not reachable with the shipped
  entitlement set.

## 10. What must be verified on a real macOS 26 machine

The FSKit half of this backend has never been compiled against the real SDK. It
was type-checked on Linux against a hand-written stand-in transcribed from the
API listing in the research report, which validates the code's internal
consistency — protocol conformance, concurrency, types — but not Apple's actual
spelling. Specifically:

1. **`[NSURL URLWithString:@"9p://host/tree"]` is not nil.** If it is, `9p://`
   never reaches the module and `p9://` is the documented form. §2.
2. **`FSItem.SetAttributesRequest.isValid(_:)`** is the accessor for "did the
   caller set this field". The alternative spelling is
   `wasAttributeConsumed(_:)`. One method, `fs9Requested`, is the only user.
3. **`FSVolume.OpenModes` members.** Only `.read` and `.write` are read.
4. **`FSItem.Identifier.rootDirectory` / `.parentOfRoot` / `.invalid` raw
   values.** Three constants in `FS9ItemIdentifier`.
5. **`FSVolume.ItemDeactivationOptions.always`** exists and means what it says.
6. **`FSItem.Attributes` property names and types**, particularly that the four
   timestamps are `timespec`.
7. **Whether FSKit synthesises `.` and `..`** in a directory listing. §7.
8. **`fs_errorForPOSIXError` returns an error the VFS unwraps back to the
   errno** — check that a missing file reports `ENOENT` and not `EIO`.
9. **`extensionkit-extension` embeds into `Contents/Extensions`** with the
   XcodeGen copy phase in `macos/project.yml`.
10. **A `-o ro` mount is actually read-only**, i.e. `FSTaskOptions.taskOptions`
    contains the string this code looks for.

## 11. Requested upstream changes

`FS9Core` and `NinePClient` are owned elsewhere, so these are worked around here
rather than fixed there. In rough order of how much they cost.

**`NineVFS.readDirectory` adopts `.` and `..` as child nodes.** Every entry a
server returns is passed to `adopt(parent:name:qid:)`, including the two dot
entries that 9P2000.L `Treaddir` always includes. That creates nodes literally
named `.` and `..` in the parent's `children` map, with the parent's own qid —
so the directory becomes its own child, twice, and a later `lookup(parent:name:)`
for a *real* name can collide with one of them if a server ever reuses the qid.
It also inflates the node table by two entries per directory listed. *Requested:
skip entries named `.` and `..` in `readDirectory`.* Worked around by dropping
them again in `FS9DirectoryPlanner.plan`, which does not undo the node-table
pollution.

**`DirectoryChunk.atEnd` is only ever true for an empty chunk.** It is set from
`raw.isEmpty`, so the last full page of a directory reports `atEnd == false` and
the caller has to make one more round trip to learn it was finished. For a
network filesystem that is a wasted `Treaddir` per directory listing. *Requested:
set `atEnd` when the server's reply was short of the requested count.* Worked
around by looping until an empty chunk arrives.

**There is no explicit open.** `NineVFS` opens fids lazily inside `read`,
`write` and `readDirectory`, and exposes only `closeHandle`. So `FS9Volume.openItem`
can validate the requested mode locally — read-only volume, directory opened for
writing — but cannot surface a *server-side* refusal (`EACCES` on a file the
server will not open, a read-only export) until the first `read(2)` or
`write(2)`. POSIX callers expect that at `open(2)`. *Requested:
`NineVFS.open(_ id: NodeID, flags: OpenFlags) async throws`, matching the
existing `closeHandle`.*

**`NineVFS.rootNode` is fixed at 1.** That is the right choice for NFS, and it
is very likely FSKit's `.parentOfRoot`. *Requested: nothing — this is a genuine
conflict between two backends' conventions and shifting it in the adapter, as
`FS9ItemIdentifier` does, is the right place to resolve it.* Recorded only so
the next person does not "fix" the shift.

**`NineVFS.fsync` succeeds silently when the node has no open fid.** Correct for
a file nobody has written, indistinguishable from a file whose fid was evicted.
Not worth changing while FSKit never calls `synchronize` anyway (FB24419870),
but it means the durability contract is weaker than it reads.
