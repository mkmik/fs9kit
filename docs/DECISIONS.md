# Design decisions

Short records of the choices that shape this project, with the evidence behind
them. Detailed research is in [`research/`](research/).

---

## 1. Language: Swift

**Decided.** Everything — protocol, client, VFS, both mount backends, the CLI —
is Swift with no external package dependencies.

FSKit is the only native way to add a filesystem to modern macOS without a
kernel extension, and its API is Objective-C/Swift. A Rust or Go core would
therefore still need a Swift shim plus an FFI boundary in the hot path of every
`read(2)`. Projects that went that way (`FSKitBridge`, `agent-harbor`) pay for
it in build complexity.

Swift also runs on Linux, which matters more than it looks: the protocol codec,
the client, the VFS and the NFS bridge are all developed and unit-tested on
Linux, and macOS CI re-runs the same suite. Only the FSKit extension is
macOS-only.

No dependencies (not even SwiftNIO) because an FSKit app extension is easier to
build, sign and ship when it is one static Swift module over POSIX sockets.

---

## 2. Two mount backends, one core

**Decided.** `FS9Core` exposes a filesystem-shaped API over the 9P client.
Two backends sit on it:

| | NFSv3 loopback | FSKit |
|---|---|---|
| macOS versions | 11 → 26+ | **26.0+ only** |
| Kernel extension | no | no |
| Code signing | none | Developer ID (ad-hoc needs SIP off) |
| User setup | none | install app, toggle in System Settings |
| Privileges | `sudo` to mount | `sudo` to mount |
| Testable on hosted CI | **yes, end to end** | no |

### Why NFS loopback is the default

A userspace NFSv3 server on `127.0.0.1` mounted with the stock `/sbin/mount_nfs`
is the technique FUSE-T and `rclone nfsmount` use. It needs no extension, no
entitlement, no notarization and no System Settings toggle, and it produces a
real kernel VFS mount with working `mmap`, symlinks, modes and atomic rename.

Apple is still investing in the NFS client — macOS 26 *added* an NFSv4.1 client
— so this is not a deprecated path. Compare `mount_afp`, whose man page has been
removed from the SDK.

Crucially, it is the only backend that can be proven to work on every push.
See decision 4.

### Why FSKit is still worth building

It is the native, future-proof answer, and it is the one that gives a real
volume in Finder without a loopback NFS server in the picture. Mounting a
*network* filesystem — one with no block device behind it — became possible only
in macOS 26 with `FSGenericURLResource`:

    mount -F -t fs9kit p9://host:564/aname /Volumes/fs9kit

This was confirmed against Apple's own `mount(8)` source
(`apple-oss-distributions/diskdev_cmds`, `disklib/fskit_support.m`), whose
resource-selection chain — `FSSupportsBlockResources` → `FSSupportsPathURLs` →
`FSSupportsGenericURLResources` → `FSSupportsServerURLs` — first appears in the
macOS 26 line. On macOS 15.4–15.7 only block devices existed, and Apple stated
network filesystems were unsupported. That statement is now obsolete but the
version floor is real.

The `com.apple.developer.fskit.fsmodule` entitlement is *not* approval-gated; it
is available on the free developer tier.

---

## 3. Protocol dialect: 9P2000.L first, 9P2000 and 9P2000.u too

**Decided.** All three are implemented; the client offers `.L`, then `.u`, then
base, and uses whatever the server accepts.

9P2000.L is the only dialect that reaches QEMU virtfs (which refuses plain
9P2000), WSL2, gVisor, diod and every modern Go or Rust server, and it maps
one-to-one onto POSIX. Base 9P2000 costs six extra messages and one stat codec
and buys the whole Plan 9 / plan9port / `u9fs` world.

The dialect is threaded through the codec from the start, the way the Linux
kernel threads `proto_version`. Retrofitting it later would mean touching every
message.

### Wire details that are not what a naive reading suggests

- **9P2000.L carries *Linux* errno numbers**, whatever either end runs. Linux
  `ENOSYS` is 38, Darwin's is 78; Linux `ENOTEMPTY` is 39, Darwin's is 66; and at
  11 Linux says `EAGAIN` where Darwin says `EDEADLK`. `Sources/NineP/Errno.swift`
  translates both ways from a table built out of each platform's own constants.
- **`Tlopen` flags are Linux `O_*` values.** Linux `O_CREAT` is `0o100`; Darwin's
  is `0x200`.
- **`Rstat` and `Twstat` carry the stat size twice** — `n[2]` then a stat that
  itself starts with `size[2] == n-2`. This is documented in `stat(5)` BUGS. The
  decoder also accepts servers that omit the redundant outer count.
- **The `Rreaddir` `type[1]` byte is unreliable**: `p9ufs` writes the qid type
  (128) where `DT_DIR` (4) is specified. Classify from `qid.type` instead.
- **Version negotiation is inconsistent.** `u9fs` downgrades correctly, `p9ufs`
  replies `unknown`, and `export9p` answers *nothing at all*. The handshake is
  therefore bounded by a timeout.

---

## 4. Testing strategy: prove the mount, not just the protocol

**Decided.** Three tiers.

1. **Unit tests** on Linux and both macOS runners: wire codec against golden
   vectors, session multiplexing against a scripted peer, VFS behaviour, XDR and
   RPC framing. Fast, hermetic, run on every push.
2. **Interop tests** against third-party 9P servers — `hugelgupf/p9`'s `p9ufs`
   (9P2000.L) and `knusbaum/go9p`'s `export9p` (base 9P2000). Both are pure Go
   and cross-compile to `darwin/arm64`, so one `go install` covers both dialects
   on a macOS runner. This is what catches "my client only works against my
   server".
3. **End-to-end mount** on macOS runners: start a 9P server, start the NFS
   bridge, `sudo mount_nfs` it, and then exercise the mount with ordinary shell
   tools and a POSIX conformance script. This is the reality check.

A real FSKit mount **cannot** be tested on a hosted runner. A third-party FSKit
module has to be enabled by an interactive click in System Settings; that state
is per-user, and Apple's DTS has stated there is no CLI, MDM or programmatic
path. Writing `enabledModules.plist` by hand is not honoured by `fskitd`, and
`FSClient.setEnabledStateForIdentifier` needs a private entitlement. So FSKit is
covered on CI by building, signing and validating the bundle, plus unit tests of
the adapter logic — never by mounting.

Measured on the runners (2026-08-21, `macos-26` = macOS 26.5, arm64, Xcode 26.6):
SIP **disabled**, passwordless `sudo`, a real Aqua session, `/sbin/mount_nfs`
present and working, `mount -F` documented, `FSKit.framework` importable, no Go
preinstalled (`actions/setup-go` required).

SIP being off on the runners leaves a possible future avenue for exercising
FSKit there — ad-hoc signing with private entitlements is only rejected by AMFI,
which SIP relaxes — but it is fragile and is not on the critical path.

---

## 5. Node identity is ours, not the server's

**Decided.** `FS9Core` numbers files itself rather than using `qid.path` as the
inode number.

9P says qid paths are unique per server, but plenty of servers derive them from
something weaker, and both mount backends need identifiers that stay valid for
the life of a mount — NFS in particular hands file handles back for hours.
Node identifiers are allocated by the VFS, and NFS file handles additionally
carry a per-server-instance boot verifier so a restarted bridge reports
`ESTALE` instead of silently resolving a handle to the wrong file.
