# The NFSv3 loopback mount backend (`FS9NFS`)

`FS9NFS` re-exports a 9P tree as an NFSv3 filesystem over a TCP socket bound to
`127.0.0.1`, so the stock `/sbin/mount_nfs` can mount it. No kernel extension,
no system extension, no entitlement, no reboot. This is the same technique
FUSE-T and `rclone nfsmount` use, and the reasoning behind choosing it is in
[`../research/mount-approaches.md`](../research/mount-approaches.md).

It also builds and runs on Linux, which is where its tests run: an in-process
NFSv3 client in `Tests/FS9NFSTests` drives the server over a real socket, so
the protocol layer is fully covered without a kernel mount anywhere.

---

## Layers

```
mount_nfs (kernel NFS client)
        │  ONC RPC / TCP, loopback
        ▼
RPCServer ── record marking, AUTH_SYS, dispatch      RPC.swift
        ├── MountProgram   (100005 v3)               MountProtocol.swift
        └── NFSProgram     (100003 v3)               NFSProtocol.swift, NFSDirectory.swift
                    │
                    ▼
              NFSExport  ── boot verifier, fsid, transfer sizes
                    │
                    ▼
               NineVFS (FS9Core)  ── 9P fids, node numbering
```

| File | Contents |
|---|---|
| `XDR.swift` | RFC 4506 encoder/decoder, big-endian, every variable-length read bounds-checked. |
| `RPC.swift` | RFC 5531 call/reply, TCP record marking, `RPCProgram`, `RPCServer`. |
| `Sockets.swift` | The handful of C calls the two platforms spell differently. |
| `FileHandles.swift` | `BootVerifier`, `NFSFileHandle`. |
| `NFSExport.swift` | What both programs share about the exported tree. |
| `NFSTypes.swift` | `nfsstat3`, `fattr3`, `wcc_data`, `sattr3`, ACCESS computation. |
| `NFSProtocol.swift` | Program dispatch and 20 of the 22 procedures. |
| `NFSDirectory.swift` | READDIR and READDIRPLUS, including cookie encoding and byte budgeting. |
| `MountProtocol.swift` | MOUNTv3. |
| `NFSMount.swift` | `NFSBridge` and the `mount_nfs` argument builder. |

## Public API

```swift
let vfs    = NineVFS(client: ninePClient)
let bridge = NFSBridge(vfs: vfs, options: NFSBridgeOptions())
let port   = try bridge.start()                 // 0 → ephemeral, reported here
let args   = bridge.mountArguments(mountPoint: "/Volumes/nine")
// … the CLI runs /sbin/mount_nfs with `args` …
bridge.stop()
```

`NFSBridge` exposes `export`, `nfs`, `mount`, `port`, `transferSize`,
`start()`, `stop()` and `mountArguments(mountPoint:extraOptions:)`.
`NFSMountCommand.options/arguments/commandLine` build the command line without
a running server. `NFSExport`, `NFSProgram`, `MountProgram`, `RPCServer`,
`RPCProgram`, `XDREncoder`/`XDRDecoder`, `RPCRecordAssembler`, `rpcFrame`,
`NFSStatus`, `NFSAccess`, `NFSFileHandle` and `BootVerifier` are public so
another transport or another program can reuse them.

**The library never runs `mount`.** Mounting needs privileges and belongs to a
process's lifecycle, not to a library; the CLI owns that step.

## Concurrency model

One thread accepts, one thread reads each connection, and every request is
handled in its own `Task`. Only the *writes* are serialised, by a per-connection
lock.

This matters: macOS keeps many calls outstanding on a single TCP connection and
matches replies by xid, not by arrival order. Serialising request handling would
turn every slow 9P round trip into a stall for the whole mount. Replies may
therefore be written in any order, which is legal and which the tests assert.

`NFSProgram` and `MountProgram` are actors; `NineVFS` underneath is an actor
too, so it is the real serialisation point for filesystem state.

## Decisions worth knowing

### File handles

21 bytes: `"9NFS"` magic, a version byte, an 8-byte per-instance boot verifier,
and the 8-byte `NodeID`. NFSv3 allows 64.

The boot verifier is the point. The kernel holds handles for the life of the
mount and has no idea when our process restarts; without it, a handle minted by
a previous instance would silently resolve to whatever file now happens to carry
that node number. Any mismatch — magic, version, length, verifier — is
`NFS3ERR_STALE`, which tells the client to forget the handle and look the file up
again. The same verifier is the WRITE/COMMIT verifier, so a client also learns to
replay its unstable writes.

### Directory cookies

NFS cookies are opaque 64-bit values the server chooses. Ours encode:

| Cookie | Meaning |
|---|---|
| `0` | start: emit `.`, `..`, then the directory from the beginning |
| `1` | `.` has been emitted |
| `2` | `..` has been emitted |
| `c` where `c & 3 == 3` | resume the 9P listing at offset `c >> 2` |

Anything else is `NFS3ERR_BAD_COOKIE` rather than a guess. The cookie verifier
is the boot verifier (an all-zero verifier is also accepted, since that is what
a client sends first), so a cookie from a previous instance is rejected instead
of resuming at a meaningless offset.

### READDIR byte budgeting

The request's `count` bounds the *whole encoded reply*, not the entry count. A
reply that overruns it is dropped by the client, which then retries with the
same cookie — forever. So the cost of each candidate entry is computed before it
is accepted:

* fixed overhead: status + the directory's `post_op_attr` + cookie verifier +
  list terminator + `eof` = 108 bytes;
* `entry3`: `4 + 8 + (4 + padded name) + 8`;
* READDIRPLUS adds `4 + 84` for `post_op_attr` and `4 + 4 + 24` for the
  `post_op_fh3`, and separately honours `dircount` for the name portion.

`eof` is set only when the 9P layer returns an empty page, which costs one extra
round trip at the end of a listing and is worth it: an early `eof` truncates
directories.

### wcc data

Every modifying procedure returns `wcc_data` — the before-image (size, mtime,
ctime) and the after-image — on success *and* on failure. macOS's client uses the
before-image to decide whether its cached pages are still valid; getting it wrong
shows up much later as "I wrote the file but reads still return the old bytes".

### FSINFO

`rtpref`/`wtpref`/`rtmax`/`wtmax`/`dtpref` come from `NineVFS.preferredIOSize`
(the negotiated 9P msize), rounded **down** to a power of two and capped at
64 KiB. Rounding down matters: a size the 9P layer cannot satisfy in one message
turns every read into two, and clients take the preferred size literally. 64 KiB
is the value macOS is known to accept; larger is worth measuring.

`FSF_LINK` and `FSF_SYMLINK` are advertised only when the negotiated 9P dialect
can deliver them — hard links need 9P2000.L, symlinks need at least 9P2000.u.
Claiming more than the dialect supports produces failures much later, in
confusing places.

### Errors

`FSError.errno → nfsstat3` is written out explicitly in `NFSStatus.init(errno:)`.
The two numberings are *mostly* the same and that is the trap:
`NFS3ERR_NAMETOOLONG` is 63 where Linux's `ENAMETOOLONG` is 36, and the
10000-range codes have no errno at all. An unrecognised errno becomes
`NFS3ERR_SERVERFAULT`, never a leaked number.

### AUTH_SYS

Credentials are decoded and recorded per request, and ACCESS is computed from
them against the file's mode/uid/gid. They are *not* enforced on the data path:
the socket is on loopback, anyone who can reach it can claim any uid, and the 9P
server behind us does its own checking. A malformed AUTH_SYS body downgrades the
call to unauthenticated rather than failing it.

## Mount options, and why

```
mount_nfs -o vers=3,tcp,port=N,mountport=N,soft,nolocks,locallocks,\
             rsize=S,wsize=S,nobrowse,noresvport 127.0.0.1:/ /mount/point
```

| Option | Why |
|---|---|
| `vers=3` | We implement NFSv3 only. Without it macOS 26 may try NFSv4.1 first and fail slowly. |
| `tcp` | The record-marking layer is TCP-only, and UDP NFS has no reassembly story worth having. |
| `port=N,mountport=N` | There is no rpcbind on our loopback address, so both programs must be named explicitly. They share one port. |
| `soft` | A userspace server can exit. A hard mount would leave unkillable processes; `soft` surfaces the failure as `EIO`. |
| `nolocks,locallocks` | **We implement no NLM (lockd) at all.** `nolocks` stops the client looking for one; `locallocks` makes `flock`/`fcntl` work between processes on this machine, which is what applications on a single-client mount actually need. |
| `rsize=S,wsize=S` | Matched to what FSINFO advertises. Left unset, the client picks something the 9P layer has to split. |
| `nobrowse` | Keeps the volume out of the Finder sidebar and out of Spotlight, which would otherwise walk the whole remote tree on mount. |
| `noresvport` | We do not require a privileged source port, and requiring one would make unprivileged mounts impossible. |
| `rdonly` | Added when the export is read-only, so the kernel rejects writes before they reach us. |

## Procedure status

Fully implemented: NULL, GETATTR, SETATTR (including the ctime `guard`), LOOKUP,
ACCESS, READLINK, READ, WRITE (all three `stable_how` levels), CREATE
(UNCHECKED/GUARDED/EXCLUSIVE), MKDIR, SYMLINK, REMOVE, RMDIR, RENAME, LINK,
READDIR, READDIRPLUS, FSSTAT, FSINFO, PATHCONF, COMMIT.

MOUNTv3: NULL, MNT, DUMP, UMNT, UMNTALL, EXPORT.

Declined: **MKNOD** returns `NFS3ERR_NOTSUPP`. 9P has no portable way to create a
device node, and nothing on a macOS mount of a remote tree needs one.

## Known gaps

* **No NLM/NSM.** Hence `nolocks,locallocks`. Byte-range locks are not visible
  to other clients — which, for a loopback mount with exactly one client, is
  fine.
* **No extended attributes.** NFSv3 has none; macOS emulates them with
  AppleDouble `._` files, which the 9P server will simply see as ordinary files.
* **Exclusive-create verifiers are in memory**, keyed by node. RFC 1813 wants
  them stored with the file so a retry survives a server restart; there is
  nowhere on a 9P server to put them, and the retry window a client cares about
  is far shorter than our lifetime.
* **`link_max` is advertised as 32000** when the dialect supports hard links,
  which is a guess: 9P has no way to ask.
* **Attribute caching is `NineVFS`'s**, not ours. A tree being modified behind
  our back through another 9P client is subject to that cache's staleness window.
* **`hostname` in MOUNT DUMP comes from the AUTH_SYS machine name**, because the
  accepted socket is always `127.0.0.1` and its peer address says nothing.
* **Not verified without a kernel mount.** Everything below is exercised by the
  in-process client; what a real `mount_nfs` does with it — negotiation of
  `rsize`/`wsize`, readahead, `mmap`, whether 64 KiB transfers are accepted, how
  `soft` timeouts behave under a stalled 9P server — is for macOS CI.

## Requested upstream changes

None. `FS9Core`'s `NineVFS` covered everything this backend needs; nothing in
`Sources/NineP`, `Sources/NinePClient`, `Sources/FS9Core` or
`Sources/NinePServer` was modified.

Two things would make the backend slightly better if `FS9Core` ever grows them,
but each has a workaround in place today:

1. **A way to ask the VFS whether a directory has more entries without fetching
   a page.** `NineVFS.readDirectory` reports `atEnd` only by returning an empty
   chunk, so determining `eof` costs one extra 9P round trip per completed
   listing. Worked around by accepting that round trip.
2. **`NineVFS.setAttributes` on a symlink.** It resolves through the VFS's path
   fid, so applying a `sattr3` to a freshly created symlink could follow the
   link. SYMLINK therefore ignores the `sattr3` a client sends, which is
   harmless — the mode of a symlink is not meaningful on any filesystem we
   target.
