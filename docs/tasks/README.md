# Work breakdown

Status of each piece of fs9kit. Rationale for the shape of the project is in
[`../DECISIONS.md`](../DECISIONS.md).

## Layers

```
  fs9p (CLI)         FS9KitExtension (macOS 26+, Xcode)
        \                    /
         \                  /
      FS9NFS          FS9KitAdapter
      (NFSv3 loopback)   (FSVolume.Operations)
              \        /
             FS9Core (NineVFS: nodes, fids, attribute cache)
                  |
             NinePClient (session, tag mux, POSIX facade)
                  |
               NineP (wire codec: 9P2000 / .u / .L)

      NinePServer — reference 9P server, test fixture and `fs9p serve`
```

---

## T1 — 9P wire codec (`Sources/NineP`) — **done**

Encoder and decoder for all three dialects, dialect-aware where the wire format
differs. Golden vectors, per-dialect round trips of every message, truncation
and garbage rejection. Linux/Darwin errno translation lives here because both
the client and the server need it.

## T2 — 9P client (`Sources/NinePClient`) — **done**

POSIX sockets (TCP, Unix, inherited fd), version negotiation with fallback and a
timeout, tag multiplexing over one reader thread, Tflush on task cancellation,
fid pool, and a POSIX-shaped facade that papers over the dialects.

## T3 — Reference 9P server (`Sources/NinePServer`) — **done**

Serves an in-memory tree or a real directory over all three dialects. Exists to
be a hermetic test fixture and to back `fs9p serve`, which is useful for
debugging the client without a Linux box.

## T4 — Shared VFS (`Sources/FS9Core`) — **done**

`NineVFS`: stable node identifiers, walked-fid cache with LRU eviction, open-fid
reuse, attribute cache with a TTL, and the namespace operations both backends
need. Everything protocol-specific stops here.

## T5 — NFSv3 loopback backend (`Sources/FS9NFS`) — **done**

XDR, ONC RPC with TCP record marking, MOUNT v3 and NFS v3 bound to `127.0.0.1`,
so stock `mount_nfs` can mount the 9P tree. The default backend and the only one
that can be proven end to end on hosted CI.

## T6 — FSKit extension (`macos/`) — **built, unverified on hardware**

`FSUnaryFileSystem` + `FSVolume` over `FS9Core`, using `FSGenericURLResource` so
a URL rather than a block device can be mounted. macOS 26+. Ships as an app
extension inside a containing app.

CI builds the bundle and asserts on its `Info.plist` and entitlements, but
**cannot mount it** — a third-party FSKit module is enabled by a per-user click
in System Settings, with no CLI or MDM route. The glue itself is behind the
`FS9KIT_FSKIT` compilation condition, because the macOS 15.4 SDK also has an
FSKit and it lacks the API this needs. What still has to be checked by hand on
a real macOS 26 Mac is listed in `docs/design/fskit-backend.md`.

## T7 — CLI (`Sources/fs9p`) — **done**

`fs9p mount|umount|serve|ls|cat|doctor`. `mount` starts the NFS bridge and
invokes `mount_nfs`; `doctor` reports which backends this machine can use and
why.

## T8 — CI (`.github/workflows`) — **done**

Three tiers: unit tests everywhere; interop against `p9ufs` and `export9p`; a
real `mount_nfs` end-to-end test on macOS runners. Plus an Xcode build of the
FSKit bundle with `Info.plist`/entitlement assertions, which is as far as a
hosted runner can go.

---

## Deliberately not doing

- **macFUSE.** Needs a kernel extension, Reduced Security and two reboots on
  Apple Silicon. The whole point is to avoid it.
- **Depending on FUSE-T.** Proprietary; bundling it requires a commercial
  licence, and it puts a closed binary in the data path.
- **SMB loopback.** Roughly ten times the protocol work of NFSv3, plus auth,
  case-insensitivity and Apple's AAPL extensions.
- **WebDAV.** No partial writes, no symlinks, no modes, no xattrs.
- **File Provider.** Not a mount: it lives under `~/Library/CloudStorage`, has
  no symlink or hardlink item types, and makes files dataless.
- **NLM byte-range locking** in the NFS backend, for now. The mount uses
  `nolocks,locallocks`; locks are local to the machine.
