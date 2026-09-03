# Mounting a user-space filesystem on modern macOS without a kext

Research date: **2026-08-21**. Target platforms: **macOS 15 Sequoia (15.4+)** and **macOS 26 Tahoe**.
Use case: a **9P client** (`fs9kit`) that mounts a remote 9P server as a real POSIX filesystem.

Every claim is linked to a primary source or explicitly marked **UNCONFIRMED**.
Companion document: [`ci-feasibility.md`](./ci-feasibility.md) (GitHub Actions specifics).

---

## Recommendation

**Ship two backends behind one internal VFS interface.**

### Primary (today, and the only thing that works everywhere): NFSv3 loopback bridge

Implement a **pure-Swift NFSv3 + MOUNTv3 server bound to `127.0.0.1`**, translating NFS
procedures onto 9P operations, and mount it with the stock client:

```sh
mount_nfs -o vers=3,tcp,port=$P,mountport=$P,noresvport,nolocks,locallocks,nobrowse,soft,intr \
          localhost:/ /path/to/mnt
```

Why this is the primary:

- **No kext, no system extension, no System Settings toggle, no entitlement, no notarization
  requirement.** It is an ordinary TCP server plus a stock `/sbin/mount_nfs` invocation.
- **Works on macOS 11 through 26.** `mount_nfs` is still shipped in macOS 26.5
  ([manp.gs mount_nfs(8)](https://manp.gs/mac/8/mount_nfs)) and Apple is *investing* in the NFS
  client, not deprecating it — macOS 26 shipped a brand-new **NFSv4.1 client**
  ([NFS Manager version history](https://www.bresink.com/osx/143439/Docs-en/pgs/0420-History.html)).
- **Real VFS semantics.** You get the kernel page cache, working `mmap`, `rename`, symlinks,
  POSIX modes and ownership — things FUSE-style `direct_io` paths and File Provider cannot give.
- **Fully exercisable in CI on GitHub-hosted macOS runners.** Already proven — see
  [`ci-feasibility.md` §5.3](./ci-feasibility.md).
- **Proven design.** It is exactly what FUSE-T and `rclone nfsmount` do
  ([rclone nfsmount](https://rclone.org/commands/rclone_nfsmount/),
  [fuse-t wiki](https://github.com/macos-fuse-t/fuse-t/wiki)).

### Secondary / future-facing: FSKit — but understand it is effectively **macOS 26+ only**

FSKit is the native, Apple-blessed answer and where `fs9kit` should land long-term, **but**:

- On **macOS 15.4–15.x, FSKit cannot mount a network filesystem at all.** The only
  `FSResource` implementation was `FSBlockDeviceResource`; Apple stated plainly that
  *"network file systems don't mount on `/dev` nodes and thus aren't supported by FSKit"*
  ([Apple Developer Forums 776322](https://developer.apple.com/forums/thread/776322)).
- **macOS 26 added `FSGenericURLResource` and `FSPathURLResource`**, gated behind
  `FSKIT_API_AVAILABILITY_V2` = macOS 26.0+
  ([dotnet/macios FSKit xcode26.0 API diff](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode26.0-b1)).
  Apple DTS confirmed this is the intended path for non-block-device filesystems
  ([Apple Developer Forums 799283](https://developer.apple.com/forums/thread/799283)).
- Deployment friction is real and unavoidable: the user must **install an app containing an
  `.appex`** and **flip a switch** in *System Settings → General → Login Items & Extensions →
  File System Extensions*. Apple DTS has said on the record there is **no** MDM, CLI, or
  programmatic way to enable it globally ("**No.**" —
  [Apple Developer Forums 808594](https://origin-devforums.apple.com/forums/thread/808594)).
- FSKit **cannot be exercised on a GitHub-hosted runner** for exactly that reason
  ([`ci-feasibility.md`](./ci-feasibility.md)).

### Explicitly rejected

- **macFUSE** — kext. On Apple Silicon it still needs Reduced Security + *"Allow user management
  of kernel extensions from identified developers"* + two reboots
  ([macFUSE Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)).
- **FUSE-T as a dependency** — proprietary; *"For commercial use or/and bundling with commercial
  software the software vendor has to obtain a commercial license"*
  ([License.txt](https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt)). Also reported
  broken on Tahoe. Treat it as prior art, not a dependency.
- **WebDAV, SMB loopback, File Provider** — see the matrix; each fails on POSIX fidelity,
  complexity, or both.

### Concrete plan

1. Keep `Sources/NineP` + `Sources/NinePClient` transport- and host-agnostic (already true).
2. Define `Sources/FS9Core` — a small VFS-shaped protocol (`lookup/getattr/read/write/readdir/
   create/remove/rename/symlink/readlink/setattr/statfs`) implemented once on top of 9P
   (fid management, walk caching, `Tclunk` hygiene).
3. `Sources/FS9NFS` — ONC RPC/XDR + MOUNTv3 + NFSv3 over TCP on `127.0.0.1`, driving `FS9Core`.
   Ship a `fs9kit mount` CLI that starts it and spawns `mount_nfs`. **This is the shipping path
   and the CI path.**
4. `FS9KitExtension` — an `FSUnaryFileSystem` appex over `FSGenericURLResource`/`FSPathURLResource`
   on macOS 26+, driving the same `FS9Core`. Gate it `@available(macOS 26.0, *)`. Validate
   manually / on a self-hosted runner.

---

## Decision matrix

Legend: **A** = kext/sysext approval needed, **R** = root/sudo needed, **S** = signing /
entitlement / notarization burden, **CI** = automatable on a GitHub-hosted macOS runner.

| # | Approach | A: kext / approval | R: root | S: signing & entitlements | macOS versions | Performance | POSIX fidelity | Impl. effort | CI |
|---|---|---|---|---|---|---|---|---|---|
| 1 | **FSKit** (`FSUnaryFileSystem`) | No kext, **but** user must install an app and toggle *File System Extensions* per-user | Mount usually works non-root; `sudo mount -F` is *broken* | Sandbox + `com.apple.developer.fskit.fsmodule`; Developer ID + notarization for distribution; Swift-only entry point | **26+ for a network FS**; 15.4+ block-device only | Moderate; macFUSE: *"not on par with the kernel extension backend"* | Best of the kext-free options: real VFS, xattr/hardlink/pathconf protocols | High (Swift appex + host app + XPC-ish plumbing) | **No** |
| 2 | **NFSv3 loopback** (own server + `mount_nfs`) | **None** | Not required in principle (`resvport` is opt-in); sudo is simplest and is free in CI | **None** | 11 → 26 (`mount_nfs` present in 26.5) | Good; RPC round-trips + `rsize/wsize`; page cache & readahead work | Very good: symlinks, modes, `rename`, `mmap`. Weak: xattrs via AppleDouble `._` files; hardlinks need real inode identity; locking needs NLM or `-o locallocks` | Medium (XDR + ~21 NFS procs + 5 MOUNT procs) | **Yes — proven** |
| 3 | **SMB loopback** (own SMB2/3 server + `mount_smbfs`) | None | Not required | None | 11 → 26 | Decent; SMB2 is chattier to implement well | Mixed: case-insensitivity, AAPL extensions needed for POSIX-ish behavior, auth handshake required | High (SMB2/3 + NTLM/session setup is much bigger than NFSv3) | Likely, **UNCONFIRMED** |
| 4 | **WebDAV** (`mount_webdav` + local server) | None | Not required | None | 11 → 26 (`mount_webdav` still shipped) | Poor; whole-file cache, no partial writes | Poor: no symlinks, no hardlinks, no xattrs, no POSIX modes; read-only if server lacks `LOCK` | Low | Yes, but pointless |
| 5 | **macFUSE** (kext backend) | **Yes** — Reduced Security + kext approval + 2 reboots | Installer needs root | Kext signing (Apple-issued kext cert) | 12 → 26 | Best I/O of all options | Highest | N/A (dependency) | **No** |
| 5b | macFUSE **FSKit backend** (`-o backend=fskit`) | Same toggle as #1 | No | Same as #1 | 15.4+; kext-free "entirely in user space on macOS 26" | Below kext backend | Mount point **must be under `/Volumes`**; files open r/w only; no notifications | N/A (dependency) | **No** |
| 6 | **File Provider** (`NSFileProviderReplicatedExtension`) | App + extension, per-user domain registration | No | Sandbox + File Provider entitlements; `com.apple.developer.fileprovider.testing-mode` for deterministic tests | 11+ (replicated: 12/13+) | Sync-shaped, not stream-shaped | **Not a mount.** Lives under `~/Library/CloudStorage`, dataless/materialize-on-read, inaccurate link counts, no symlink/hardlink item types | High | **No** |
| 7 | **Virtualization.framework / virtiofs** | N/A | N/A | N/A | 13+ | N/A | N/A | N/A | No |
| 8 | **NetFS plugin** (`/Library/Filesystems/NetFSPlugins`) | No kext, but **no public API** | Installs into `/Library` | Unclear | all | N/A | **N/A — it is a mount *helper*, not a filesystem** | N/A | No |
| 9 | **`mount_9p`** (Apple's built-in 9P client) | None | Unknown | None | shipped since ~10.15 | Kernel-speed | Full kernel VFS | Zero — *if it were usable* | No |

Note on #9: this is the tantalizing one and it does not work out. See §8.3.

---

## 1. FSKit (macOS 15.4+ / 26)

*Another agent covers the API surface. This section is deployment- and constraint-focused.*

**What it is.** Apple's user-space filesystem framework, introduced in **macOS 15.4**, the
supported replacement for filesystem kexts. A filesystem is an **ExtensionKit app extension**
(`.appex`) with a **Swift** entry point, embedded in a host app
([Apple Developer Forums 776322](https://developer.apple.com/forums/thread/776322)).

### (a) Approval / deployment friction — the decisive issue

There is no kext and no `systemextensionsctl` dance, but there **is** a mandatory user gesture:

> *System Settings → General → Login Items & Extensions → File System Extensions* → info button →
> toggle the module on.
> — [Apple Developer Forums 776322](https://developer.apple.com/forums/thread/776322)

Corroborated in the wild: rclone users report the toggle is *"greyed out unless you switch view to
'By Category'"* ([rclone forum](https://forum.rclone.org/t/macos-rclone-mount-with-fuse-t-via-fskit/53608)).

Enablement is **per-user and cannot be automated**. Apple DTS, asked whether FSKit modules can be
enabled globally: **"No."** — *"FSKit is based on app extensions, and app extensions are
fundamentally scoped to a given user."* Programmatically editing `enabledModules.plist` was
explicitly discouraged as an implementation detail that may become MAC-protected
([Apple Developer Forums 808594](https://origin-devforums.apple.com/forums/thread/808594)).

`pluginkit -e use -p com.apple.fskit.fsmodule -i <bundle-id>` is used in the wild
([FSKitBridge](https://github.com/debox-network/FSKitBridge)) but PlugInKit election and FSKit's
own enabled-module list are not the same thing — see [`ci-feasibility.md`](./ci-feasibility.md).
Treat CLI enablement as **UNCONFIRMED / unreliable**.

**So: yes, the end user must install an app and flip a switch in System Settings.** For a
developer-tool audience that is acceptable; for a `brew install`-and-go CLI it is not.

### (b) root

Mounting is `mount -F -t <MyFS> <resource> <mountpoint>`. Non-root mounting works for
URL/disk-image resources; notably **`sudo mount -F` fails** with `mount: Unable to invoke task`
because the FSKit task is per-user, and mounting a physical device as a normal user hits
`POSIX Error 13` unless you `chown` the `/dev/rdisk*` node
([Apple Developer Forums 788609](https://developer.apple.com/forums/thread/788609)). For a
network FS backed by a URL resource, none of the block-device pain applies.

### (c) Signing / entitlements

- `com.apple.security.app-sandbox` (mandatory)
- [`com.apple.developer.fskit.fsmodule`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule)
- Developer ID signing + notarization for distribution outside the App Store.

Whether the FSKit entitlement requires an explicit request/approval from Apple is
**UNCONFIRMED** — the documentation page does not say so, and third parties (macFUSE, fuse-t,
FSKitBridge) ship it, which suggests it is freely available with a paid developer account.

### (d) Versions — the blocker for a 9P client

| macOS | FSKit status for a *network* filesystem |
|---|---|
| 15.0–15.3 | No FSKit |
| 15.4–15.x | FSKit exists but **`FSBlockDeviceResource` is the only `FSResource`** → block devices only. Apple: *"Network file system don't mount on `/dev` nodes and thus aren't supported by FSKit."* ([776322](https://developer.apple.com/forums/thread/776322)) |
| 26.0+ | **`FSGenericURLResource` / `FSPathURLResource`** added under `FSKIT_API_AVAILABILITY_V2` ([xcode26.0 API diff](https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode26.0-b1)). Apple DTS on a virtual FS over a path: *"That's exactly the kind of thing FSPathURLResource is intended to support."* ([799283](https://developer.apple.com/forums/thread/799283)) |

Practical proof that FSKit can now back a network-ish filesystem: **fuse-t 1.2.1+ added an
`-o backend=fskit` mode on macOS 26+**, and **macFUSE 5.2/5.3 added an FSKit backend**
([macFUSE FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends),
[macfuse.github.io](https://macfuse.github.io/)).

**Stability caveat:** third-party FSKit extensions were reported outright broken on macOS
**26.1 and 26.2** — `fskitd` rejecting unprivileged clients with
`Failed to start instance` / `Hello FSClient! entitlement no`, affecting even Apple's own
`FSKitSample` ([loaf#1](https://github.com/andrewgazelka/loaf/issues/1)). Apple DTS in 2025:
*"more bugs have been found so you're going to need to wait for more fixes."* Whether this is
fixed in 26.4/26.5/26.6 is **UNCONFIRMED**; fuse-t users report success on 26.4, which suggests
it is at least partly resolved.

### (e) Performance

macFUSE, comparing its own two backends, states flatly: *"I/O performance of FSKit volumes is not
on par with volumes using the kernel extension backend"*
([FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)). Apple has published no
throughput numbers and declined to give limits when asked
([766793](https://developer.apple.com/forums/thread/766793)). For a 9P client the network is
almost certainly the bottleneck anyway.

### (f) POSIX fidelity

The best of the kext-free options: FSKit has first-class protocols for xattrs
(`xattrOf:named:`, `setXattrOf:named:value:how:`, `FSVolumeLimitedXattrOperations`), pathconf
including `maximumLinkCount`, and macOS 26 added `enableOpenUnlinkEmulation`.

### (g) Effort

High. Swift-only appex, a host app, code signing, and a per-user enablement UX story.

### (h) CI

**No.** The System Settings toggle is interactive, per-user, and GitHub runners are ephemeral.

### Other FSKit constraints worth knowing

- macFUSE reports FSKit mount points are **restricted to `/Volumes`**
  ([FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)) — yet Apple's own
  forum example mounts to `/tmp/TestVol`. Contradictory; **UNCONFIRMED**, likely a macFUSE-side
  restriction rather than an FSKit one.
- FSKit volumes mounted from the terminal **do not automatically appear in Finder** ([776322](https://developer.apple.com/forums/thread/776322)).
- **No process attribution** — FSKit does not expose the requesting PID (no FUSE `fuse_in_header`
  equivalent) ([766793](https://developer.apple.com/forums/thread/766793)).
- Sandboxed apps still cannot invoke `/sbin/mount`; Apple asked for bugs on an
  "App Sandbox compliant, non-block FS mount API" (FB20186709) ([799283](https://developer.apple.com/forums/thread/799283)).

---

## 2. NFS loopback — the FUSE-T technique

### 2.1 How it works

Run a userspace NFS server bound to `127.0.0.1:$P`, then have the **stock macOS kernel NFS
client** mount it. The kernel does the VFS work; your process answers RPCs.

FUSE-T describes exactly this: *"when a filesystem issues a mount API call, libfuse launches a
FUSE-T NFS server that exposes a local TCP port to the macOS mount process and another
communication channel to libfuse"*
([fuse-t wiki](https://github.com/macos-fuse-t/fuse-t/wiki)).

### 2.2 Is `mount_nfs` still there in macOS 26? Is the NFS client deprecated?

**Yes it is there; no it is not deprecated — the opposite.**

- `mount_nfs(8)` is documented for **macOS 26.5** ([manp.gs](https://manp.gs/mac/8/mount_nfs)),
  and `mount_nfs.8` ships in the current Xcode SDK man pages
  ([keith.github.io/xcode-man-pages](https://keith.github.io/xcode-man-pages/mount_nfs.8.html)).
- macOS 26 shipped a **new NFSv4.1 client**, and 26.1 let clients choose between v4.0 and v4.1
  ([NFS Manager version history](https://www.bresink.com/osx/143439/Docs-en/pgs/0420-History.html)).
  Apple is actively developing this code.
- Compare AFP, which *has* been removed: `mount_afp.8` is **absent** from the current SDK man
  pages, while `mount_nfs.8`, `mount_smbfs.8`, `mount_webdav.8`, `mount_ftp.8` and `mount_apfs.8`
  are all present (checked 2026-08-21).

### 2.3 NFSv3 or NFSv4?

**Use NFSv3.** Reasons:

- `mount_nfs`'s default is *"try version 3 first, and fall back to version 2"* — v3 is the
  best-trodden path ([mount_nfs(8)](https://keith.github.io/xcode-man-pages/mount_nfs.8.html)).
- NFSv3 is a tiny, stateless protocol: **~21 procedures** plus **MOUNTv3's 5**. You can skip
  rpcbind/portmap entirely by passing explicit `port=` and `mountport=`.
- Prior art is all NFSv3: [`willscott/go-nfs`](https://github.com/willscott/go-nfs) (powers
  `rclone serve nfs` / `rclone nfsmount`), [`nfsserve`](https://crates.io/crates/nfsserve) (Rust),
  and its `zerofs_nfsserve` / `huggingface` / `xetdata` forks.

FUSE-T instead uses **NFSv4** (plus SMB3 and FSKit) —
[README](https://github.com/macos-fuse-t/fuse-t): *"NFSv4, SMB3, and FSKit backend support"*.
NFSv4's advantage is **named attributes → real xattrs**; its cost is a far larger, stateful
protocol (compound ops, state IDs, delegations, leases). Note that macOS's NFSv4 client still
**defaults to AppleDouble for xattrs anyway** ([nfs(5)](https://keith.github.io/xcode-man-pages/nfs.5.html)),
which erases much of that advantage. And fuse-t's NFS backend is reported to *panic* on Tahoe
(see [`ci-feasibility.md` §5.3](./ci-feasibility.md)).

### 2.4 Does mounting need root?

**Probably not, and it does not matter in CI.**

- `resvport` (binding a privileged source port) is **opt-in**, and the man page says only:
  *"root permission is required to mount using `resvport` mount option"*
  ([mount_nfs(8)](https://keith.github.io/xcode-man-pages/mount_nfs.8.html)). The default is an
  unprivileged port.
- XNU's `mount_common()` has no blanket `suser()` gate; it explicitly handles the non-root case
  (*"For non-root users, silently enforce MNT_NOSUID and MNT_NODEV"*) —
  [`bsd/vfs/vfs_syscalls.c`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c).
- `rclone nfsmount` defaults to **no sudo** and offers `--sudo` as an opt-in
  ([rclone nfsmount](https://rclone.org/commands/rclone_nfsmount/)).
- Consistent with macOS letting the console user mount SMB/WebDAV volumes from Finder without an
  admin prompt.

**UNCONFIRMED:** whether an unprivileged `mount_nfs` succeeds on a *specific* macOS 26 build with
a user-owned mount point. Pass `-o noresvport` explicitly and fall back to `sudo`.
GitHub runners have passwordless sudo, so CI is unaffected
([GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).

### 2.5 Mount options that matter

Verified against [mount_nfs(8)](https://keith.github.io/xcode-man-pages/mount_nfs.8.html) and
[mount(8)](https://keith.github.io/xcode-man-pages/mount.8.html):

| Option | Why |
|---|---|
| `vers=3` | pin the version; do not let it negotiate |
| `tcp` | UDP is the default transport historically; you want TCP |
| `port=$P`, `mountport=$P` | serve NFS and MOUNT on one port; no rpcbind needed |
| `noresvport` | default, but be explicit → no root needed to bind the source port |
| `nolocks,locallocks` | *"perform all file locking operations locally on the NFS client (in the VFS layer) instead of on the NFS server"* — gives you working `flock`/`fcntl` without implementing NLM |
| `nobrowse` | `mount(8)`: *"the mount point should not be visible via the GUI"* — keeps it out of Finder/Desktop |
| `soft`,`intr` | so a wedged server yields `EINTR`/`EIO` instead of an unkillable `ls`. **Critical in CI.** |
| `rsize=`,`wsize=` | tune to your 9P `msize` |
| `actimeo=`, `ac{reg,dir,rootdir}{min,max}=` | attribute-cache tuning; `0` disables caching |
| `nfc`/`nfd` | Unicode normalization — set deliberately, macOS and 9P servers disagree |

There is **no `allow_other`** — that is a FUSE concept. NFS access is governed by the server's
own auth (AUTH_SYS uid/gid) plus normal VFS permission checks. Since the server is bound to
`127.0.0.1`, **any local user can reach it** — that is a real, accepted security tradeoff of this
whole family of approaches (it is FUSE-T's too). Mitigate by checking the peer credentials of the
accepted socket (`LOCAL_PEERCRED` / `SO_PEERCRED`-equivalent via `getsockopt`) and rejecting
foreign uids. **UNCONFIRMED** whether the kernel NFS client's socket passes that check cleanly.

Reference command lines in the wild:

```sh
# rclone (cmd/nfsmount/nfsmount.go)
mount -o port=$P -o mountport=$P -o tcp localhost:/ $MNT
# and it unmounts with: diskutil umount force $MNT   (macOS-specific)

# nfsserve (Rust)
mount_nfs -o nolocks,vers=3,tcp,rsize=131072,actimeo=120,port=11111,mountport=11111 localhost:/ demo
```

Sources: [rclone `cmd/nfsmount/nfsmount.go`](https://github.com/rclone/rclone/blob/master/cmd/nfsmount/nfsmount.go),
[nfsserve](https://crates.io/crates/nfsserve).

### 2.6 POSIX fidelity

| Feature | NFSv3 loopback | Notes |
|---|---|---|
| symlinks | ✅ | `SYMLINK`/`READLINK` are core NFSv3 procedures; maps cleanly onto 9P `Tsymlink`/`Treadlink` (9P2000.L) or the `.u` extension |
| permissions / ownership | ✅ | `sattr3` mode/uid/gid; AUTH_SYS credentials |
| rename | ✅ | atomic `RENAME` |
| **mmap** | ✅ | NFS is a real VFS with the unified buffer cache. This is a genuine advantage over FUSE `direct_io` and over WebDAV/File Provider |
| hardlinks | ⚠️ | `LINK` exists, but requires stable, distinct 64-bit `fileid`s. `go-nfs` explicitly gives up here: *"hard linking not supported due to opaque inode handling"* ([go-nfs README](https://github.com/willscott/go-nfs)). If 9P QIDs give you stable identity you can do better |
| locking | ⚠️ | NFSv3 locking is out-of-band (NLM/`rpc.lockd`). **Use `-o nolocks,locallocks`** and let the client handle it locally. FUSE-T does not do better: *"file locks (flock, lockf, fcntl) bypass FUSE calls"* ([fuse-t wiki](https://github.com/macos-fuse-t/fuse-t/wiki)) |
| xattrs | ❌ (emulated) | NFSv3 has no xattrs. macOS emulates them with **AppleDouble `._` files** on the server ([nfs(5)](https://keith.github.io/xcode-man-pages/nfs.5.html)). Your server sees ordinary `._foo` files; you can pass them through to 9P or synthesize them |
| atime/mtime independence | ⚠️ | FUSE-T: *"access and modification times cannot be set separately"* — an NFS-client behaviour that *"always modifies both"* ([fuse-t wiki](https://github.com/macos-fuse-t/fuse-t/wiki), [rclone nfsmount](https://rclone.org/commands/rclone_nfsmount/)) |
| inode width | ✅ | NFSv3 `fileid3` is 64-bit. The "32-bit inode" folklore is an NFSv2 artifact. **UNCONFIRMED** whether macOS's client truncates anywhere |
| `ioctl`, `fallocate`, `bmap` | ❌ | Not expressible. FUSE-T lists the same gaps |
| FS change notifications | ❌ | No `kqueue`/FSEvents push. FUSE-T: *"notifications for NFS and FSKit backends"* unsupported |

### 2.7 Performance

Middling but usable. Real-world signals:

- fuse-t + ntfs-3g measured at ~20 MB/s vs ~700–800 MB/s for macFUSE
  ([fuse-t#89](https://github.com/macos-fuse-t/fuse-t/issues/89)) — an extreme case (local NVMe),
  irrelevant when your backend is a network 9P server.
- rclone users hit pathological cases where `nfsmount` was ~15× slower than `mount` via fuse-t
  ([rclone#8814](https://github.com/rclone/rclone/issues/8814)) — attributed to VFS-cache
  interaction, not the NFS transport per se.

Levers: `rsize`/`wsize`, attribute-cache timeouts (`actimeo`), READDIRPLUS (`rdirplus`), and
batching 9P walks. Tune deliberately.

### 2.8 Known hazards

- **`mount_nfs(8)` CAVEATS:** *"An NFS server shouldn't loopback-mount its own exported file
  systems because it's fundamentally prone to deadlock."* This targets the kernel `nfsd`
  re-exporting itself. A userspace server whose own working set never lives on the mount is much
  safer — but under memory pressure the classic writeback deadlock is still theoretically
  reachable. Keep the server's allocations off the mount; consider `mlock`-ing hot paths.
- **Idle-timeout bug:** macOS 15+ has a reported TCP-stack defect where NFS connections idle for
  **>300 s** wedge ([NFS Manager notes](http://www.bresink.com/osx/143439/issues.html)). That
  report is about macOS acting as *server*; whether the client side is affected is
  **UNCONFIRMED**. Cheap insurance: a keepalive NULL RPC or short `actimeo`.
- **A hard mount that mounts but never serves hangs `ls` forever.** Always `soft,intr`, always
  use a wall-clock readiness deadline in tests (see [`ci-feasibility.md`](./ci-feasibility.md)).
- **macOS 26 "Network Volumes" TCC.** Tahoe added a privacy gate on network volumes — apps need
  user consent, surfaced in *System Settings → Privacy & Security*
  ([eclecticlight: Privacy: Which folders are protected in Tahoe?](https://eclecticlight.co/2026/04/15/privacy-which-folders-are-protected-in-tahoe/)).
  FUSE-T's README already warns: *"check that your terminal application has 'Network Volumes'
  access enabled in System Settings under Privacy & Security"*
  ([fuse-t README](https://github.com/macos-fuse-t/fuse-t)). **This is a real new deployment
  friction for the NFS-loopback approach on Tahoe** — an NFS mount is a *network volume*, so
  every consuming app may get a consent prompt. Exact scope on 26.x is **UNCONFIRMED**; test it.
- **Unmount** on macOS: prefer `diskutil umount force` over `umount -f`, as rclone does.

### 2.9 FUSE-T, specifically

| | |
|---|---|
| What | Kext-less libfuse-compatible layer; `libfuse-t.dylib`/`.a` in `/usr/local`, servers in `/Library/Application Support/fuse-t` |
| Backends | **NFSv4** (default), **SMB3**, **FSKit** (macOS 26+); selected via `-o backend=[nfs\|smb\|fskit]` |
| Minimum macOS | macOS 13+ (**UNCONFIRMED**, from release metadata) |
| Install | `brew install macos-fuse-t/homebrew-cask/fuse-t`, or a `.pkg`; uninstall needs `sudo` |
| Mount as root? | Not required for mounting; installation is a root pkg install |
| License | **Proprietary.** *"For commercial use or/and bundling with commercial software the software vendor has to obtain a commercial license from the FUSE-T authors."* The bundled libfuse is LGPL. The NFS/SMB servers are **not** open source; the author walked back an open-source promise ([HN discussion](https://news.ycombinator.com/item?id=38775579)) |
| Unsupported | file locks (`flock`/`lockf`/`fcntl`) bypass FUSE calls; `IOCTL`, `BMAP`, `FALLOCATE`; notifications on NFS/FSKit backends; volume icons on network drives |
| Caveats | call sequence differs from osxfuse; attribute caching is **client-side only** (values returned by the filesystem are ignored); atime and mtime cannot be set separately |
| Mount options | `-r`, `-volname`, `-nonamedattr`, `-noattrcache`, `-rwsize`, `-nobrowse`, `-nfc`, `-nomtime`, `-location`, `-d` |
| Tahoe status | NFS backend reported panicking on macOS 26 (`go-nfsv4 panic`, `SMB EOF`) — see [`ci-feasibility.md` §5.3](./ci-feasibility.md) |

Sources: [wiki](https://github.com/macos-fuse-t/fuse-t/wiki), [README](https://github.com/macos-fuse-t/fuse-t),
[License.txt](https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt).

**Verdict:** excellent prior art, unacceptable as a dependency. The licensing alone rules it out
for anything that might ship commercially, and it is a closed binary sitting in your data path.

### 2.10 Other userspace-NFS options

- **[`willscott/go-nfs`](https://github.com/willscott/go-nfs)** — pure-Go NFSv3, powers
  `rclone serve nfs`. Self-described *"minimally tested"*; no hardlinks; uid/gid needs the
  `Sys()` escape hatch.
- **[`nfsserve`](https://crates.io/crates/nfsserve)** (Rust) and forks `zerofs_nfsserve`,
  `huggingface/nfsserve`, `xetdata/nfsserve`; also `nfs3_server`. *"An incomplete but very
  functional implementation of an NFSv3 server in Rust"*, built precisely because
  *"FUSE is annoying to users on Mac and Windows"*.
- **nfs-ganesha on macOS** — a Darwin build exists ("BSDBASED" build type derived from the
  FreeBSD path) but it is awkward: Apple's `ld` lacks `--version-script=`, URCU/GSS include-path
  fixes, kqueue-based epoll emulation
  ([ganesha devel list](https://lists.nfs-ganesha.org/archives/list/devel@lists.nfs-ganesha.org/thread/EFQZG64LKMEI2RB56EOEO6QMP4A25NCM/)).
  Vastly oversized for this job (it targets v3/v4/v4.1/pNFS).
- **[tightloop.io: Userspace file systems on Mac](https://tightloop.io/userspace-filesystems/index.html)**
  — a survey that reached the same conclusion: SFTP→NFS loopback via `nfsserve`, with FSKit as
  the future.

**For `fs9kit`, which is pure Swift with no dependencies, writing the NFSv3+MOUNTv3 server in
Swift is the coherent choice** and keeps the SPM package dependency-free. XDR is trivial; the
procedure set is small; the existing `Sources/NineP/ByteOrder.swift` already gives you the
primitives (albeit little-endian — NFS/XDR is big-endian).

---

## 3. SMB loopback

**Has anyone done it? Yes — FUSE-T ships an SMB3 backend** (`-o backend=smb`)
([fuse-t README](https://github.com/macos-fuse-t/fuse-t)). So it is demonstrably possible: run a
userspace SMB2/3 server on loopback and `mount_smbfs //user@127.0.0.1/share /mnt`.
`mount_smbfs.8` is present in the current SDK man pages.

**Tradeoffs vs NFSv3:**

- **Auth.** SMB requires a session setup (NTLMv2 or anonymous/guest), optional signing, and
  credentials plumbing via `.nsmbrc`/`nsmb.conf`. Much more machinery than AUTH_SYS.
- **Finder refuses loopback SMB mounts to your own Mac** — the CLI path (`mount_smbfs`) is the
  only one. **UNCONFIRMED** whether this restriction has changed in 26.
- **Case sensitivity.** SMB shares present as case-insensitive by default on macOS; a 9P server
  is almost certainly case-sensitive. That mismatch causes real bugs.
- **POSIX fidelity** requires implementing Apple's **AAPL create-context extensions** to get
  UNIX modes, symlinks, and resource-fork/xattr behaviour; otherwise you get Windows semantics.
- **Complexity.** SMB2/3 is an order of magnitude more protocol than NFSv3.
- fuse-t's SMB backend is reported failing with `SMB EOF` on Tahoe (see [`ci-feasibility.md`](./ci-feasibility.md)).

**Verdict:** a legitimate third fallback if NFS is ever removed, but strictly worse than NFSv3
on every axis that matters here. Do not build it now.

---

## 4. WebDAV

`mount_webdav(8)` **is still shipped** (present in current SDK man pages). It is the easiest to
implement and the worst to live with.

- **No partial writes.** macOS's `webdavfs` caches whole files locally; there is no standard for
  partial WebDAV writes, and implementations that detect no support **mount read-only**.
- **Read-only fallback baked into the man page:** for Class 1 servers without `LOCK`,
  *"the `rdonly` option will be set even if it was not specified."*
- **No symlinks, no hardlinks, no xattrs, no POSIX modes, no ownership.** WebDAV has no vocabulary
  for them.
- **Cache correctness bugs** have historically plagued it (`NSURLCache` ignoring byte ranges).
- Actively regressing: WebDAV sharing broke for users on **macOS 15.4**
  ([UTM#7122](https://github.com/utmapp/UTM/issues/7122)).

**Verdict:** unusable for a general-purpose 9P mount. Only relevant if you wanted a read-mostly
browse view.

---

## 5. macFUSE (excluded — for the record)

Current release **5.3.3 (2026-07-04)**, macOS 12+, Intel + Apple Silicon
([macfuse.github.io](https://macfuse.github.io/)).

**Why excluded — the kext backend install flow on Apple Silicon**
([Getting Started](https://github.com/macfuse/macfuse/wiki/Getting-Started)):

1. "Enable System Extensions…" + password
2. Shut down, hold power → Startup Security Utility
3. **Reduced Security** + **"Allow user management of kernel extensions from identified developers"**
4. Reboot
5. Approve the kext, reboot again

Two reboots and a downgrade of the machine's security posture. Non-starter for a distributable tool.

**But note:** macFUSE 5.2+ added an **FSKit backend** (`-o backend=fskit`) which needs *"no kernel
extension or any security configuration changes in Recovery Mode"*, and its 5.2.0 release added an
**XPC-based mounting API** that removes `fork()`/`exec()` and enables fully sandboxed filesystems
([FUSE Backends](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)). Its documented FSKit-backend
limits are a good preview of what `fs9kit`'s own FSKit backend will hit: **mount points under
`/Volumes` only**, files open **read/write only**, no notification API, no `fuse_context_t`, most
mount options unimplemented, and lower I/O performance.

---

## 6. File Provider (`NSFileProviderReplicatedExtension`)

**Does it produce a real POSIX mount usable from the shell? No.**

- Content lives under **`~/Library/CloudStorage/<Provider>-<Domain>`** on the internal drive —
  there is no `mount(2)`, no `mount` entry, no choosing the location
  ([TidBITS](https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/)).
- It is a **replication/sync** model, not a passthrough: items can be **dataless (dehydrated)**,
  materialized on demand when a process reads them. Directory listings **do not report accurate
  link counts**.
- The item model (`NSFileProviderItem`) has no symlink or hardlink item type. On macOS a
  `contentType` is mandatory.
- Shell tools hit this in practice — e.g.
  [claude-code#40783](https://github.com/anthropics/claude-code/issues/40783), "File read failure
  on macOS FileProvider-backed paths".
- Requires an app + extension, per-user domain registration, and sandbox/File Provider
  entitlements. Deterministic testing needs
  [`com.apple.developer.fileprovider.testing-mode`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fileprovider.testing-mode)
  plus `NSFileProviderDomain.testingModes`.
- The [tightloop survey](https://tightloop.io/userspace-filesystems/index.html) rejects it for the
  same reason: *"lacks support for partial file reads, streaming, and on-demand directory creation."*

**Verdict: not viable for a 9P client.** It is a cloud-sync UX, not a filesystem. Same
per-user-app-install friction as FSKit, with far worse POSIX semantics.

---

## 7. Virtualization.framework / virtiofs "in reverse"

Not applicable, as suspected. `VZVirtioFileSystemDeviceConfiguration` shares a **host** directory
**into a guest**; the host is the FUSE *server* and the guest is the client
([virtiofs docs](https://virtio-fs.gitlab.io/), [Lima mounts](https://lima-vm.io/docs/config/mount/)).
There is no host-side API to mount a guest-provided or arbitrary virtiofs/9P export on the host.

(A contrived workaround — run a Linux VM, mount 9P inside it, re-export to the host over NFS —
is strictly worse than just running the NFS server natively.)

---

## 8. Everything else

### 8.1 NetFS / `NetFSPlugin` — a mount helper, not a filesystem

`/System/Library/Filesystems/NetFSPlugins` holds `.fs` bundles for SMB, NFS, WebDAV, FTP, etc.,
and third-party plugins can be dropped in `/Library/Filesystems/NetFSPlugins`.

**But a NetFS plugin does not implement a filesystem.** The `NetFSMountInterface_V1` vtable is
`CreateSessionRef`, `OpenSession`, `CloseSession`, `ParseURL`, `CreateURL`, `EnumerateShares`,
`GetServerInfo`, `Mount`, `GetMountInfo`, `Cancel`
([NetFSPlugin.h](https://jenkins.heirloomcomputing.com/downloads/MacOSX10.8.sdk/System/Library/Frameworks/NetFS.framework/Headers/NetFSPlugin.h)).
It parses a URL, authenticates, enumerates shares, and then calls `mount(2)` — **the actual I/O is
done by an existing kernel VFS**. It is the plumbing behind Finder's "Connect to Server…".

There is also **no public/supported API**: *"there was no official nor unofficial documentation
about this API for third-party developers"*; the SMB/AFP/HTTP plugins were open-sourced and serve
as the only reference.

**So a NetFS plugin cannot be the 9P filesystem.** It could, in principle, be a *nicety on top of*
the NFS-loopback backend — a `9p://host/aname` URL handler that starts your bridge and mounts it,
so Finder's "Connect to Server…" works. That is polish, not a mount mechanism, and it depends on a
private API. **Not recommended.**

`mount_ftp.8` is still present in the SDK; `URLMount`/`NetFS` remain the mechanism. AFP is gone
(`mount_afp.8` absent; Apple removed AFP *serving* in Big Sur and has been deprecating the client
since Sequoia 15.5).

### 8.2 `mount_apfs`, `nullfs`, `bindfs`, `mount_devfs`

- `mount_apfs(8)` mounts APFS volumes/snapshots — nothing to do with a network FS.
- `nullfs` exists in XNU but is not a supported user-facing mount type on macOS (used internally
  for the iOS simulator / shared cache). **UNCONFIRMED** whether any `mount_nullfs` is reachable;
  in any case it is a passthrough of a *local* directory, not a protocol client.
- `bindfs` is a FUSE filesystem — it *needs* one of the mechanisms above, it is not one.
- `mount_devfs` — no man page in the SDK; irrelevant.

None of these help.

### 8.3 `/sbin/mount_9p` — macOS ships a 9P client, and you still cannot use it

This is the most interesting dead end. macOS ships **`mount_9p(8)`**, present in the current
Xcode SDK man pages, copyright Apple 2019:

```
NAME
     mount_9p — mount a 9P volume
SYNOPSIS
     mount_9p [-r] fs_tag
```

([mount_9p(8)](https://keith.github.io/xcode-man-pages/mount_9p.8.html))

The **only** argument is `fs_tag` — a **virtio device tag**. This is the guest-side client for
Apple's Virtualization.framework directory sharing: a macOS VM running under `Virtualization`
mounts the host's shared directory by tag. There is no host, no port, no path, no socket.
`mount_virtiofs(8)` is its successor and has the same shape.

So although macOS contains a real, kernel-speed 9P VFS, it is only reachable through a
`VZVirtio*` device inside a VM guest. On a bare-metal Mac there is no way to present a TCP 9P
server as an `fs_tag`. **UNCONFIRMED** at the kext/IOKit level whether a fake virtio provider
could be synthesized — but that would require a kext, which defeats the entire exercise.

Worth a one-line probe on a dev machine anyway (`man mount_9p; ls /sbin/mount_9p; sysctl -a | grep -i 9p`)
just to confirm the VFS is not registered on bare metal.

---

## 9. Sources

FSKit
- <https://developer.apple.com/forums/thread/776322> — FSKit overview, block-device-only, network FS unsupported, System Settings enablement
- <https://developer.apple.com/forums/thread/799283> — `FSPathURLResource` for non-block FS; sandbox mount API gap (FB20186709)
- <https://origin-devforums.apple.com/forums/thread/808594> — no global/MDM/programmatic enablement ("No.")
- <https://developer.apple.com/forums/thread/788609> — mount permissions, `sudo mount -F` failure
- <https://developer.apple.com/forums/thread/766793> — `reclaimItem`, no process attribution
- <https://github.com/dotnet/macios/wiki/FSKit-macOS-xcode26.0-b1> — `FSGenericURLResource`/`FSPathURLResource` are macOS 26.0 (`FSKIT_API_AVAILABILITY_V2`)
- <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule>
- <https://github.com/andrewgazelka/loaf/issues/1> — third-party FSKit broken on macOS 26.1/26.2
- <https://github.com/KhaosT/FSKitSample>, <https://github.com/debox-network/FSKitBridge>
- <https://deepwiki.com/blocksense-network/agent-harbor/5.4-fskit-implementation-(macos)>
- <https://eclecticlight.co/2024/06/26/how-file-systems-can-change-in-sequoia-with-fskit/>

macFUSE / FUSE-T
- <https://macfuse.github.io/> — 5.3.3, FSKit backend, kext-free on macOS 26
- <https://github.com/macfuse/macfuse/wiki/FUSE-Backends> — backend comparison and FSKit limits
- <https://github.com/macfuse/macfuse/wiki/Getting-Started> — Apple Silicon kext approval flow
- <https://github.com/macos-fuse-t/fuse-t> — README: NFSv4/SMB3/FSKit; Network Volumes TCC note
- <https://github.com/macos-fuse-t/fuse-t/wiki> — mount options, unsupported features, caveats
- <https://github.com/macos-fuse-t/fuse-t/blob/main/License.txt> — commercial license required
- <https://github.com/macos-fuse-t/fuse-t/issues/89> — performance report
- <https://news.ycombinator.com/item?id=38775579> — licensing controversy

NFS
- <https://keith.github.io/xcode-man-pages/mount_nfs.8.html>, <https://manp.gs/mac/8/mount_nfs> (macOS 26.5)
- <https://keith.github.io/xcode-man-pages/nfs.5.html> — AppleDouble xattr emulation
- <https://keith.github.io/xcode-man-pages/mount.8.html> — `nobrowse`
- <https://www.bresink.com/osx/143439/Docs-en/pgs/0420-History.html> — macOS 26 NFSv4.1 client
- <http://www.bresink.com/osx/143439/issues.html> — macOS 15+ 300 s idle defect; xattr cross-protocol incompatibility
- <https://rclone.org/commands/rclone_nfsmount/>, <https://rclone.org/commands/rclone_serve_nfs/>
- <https://github.com/rclone/rclone/blob/master/cmd/nfsmount/nfsmount.go> — exact mount/umount commands
- <https://github.com/rclone/rclone/issues/8814> — macOS nfsmount performance pathology
- <https://github.com/willscott/go-nfs> — Go NFSv3; no hardlinks
- <https://crates.io/crates/nfsserve> — Rust NFSv3 + macOS mount line
- <https://lists.nfs-ganesha.org/archives/list/devel@lists.nfs-ganesha.org/thread/EFQZG64LKMEI2RB56EOEO6QMP4A25NCM/> — Ganesha Darwin build
- <https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c> — non-root mount handling

Other
- <https://jenkins.heirloomcomputing.com/downloads/MacOSX10.8.sdk/System/Library/Frameworks/NetFS.framework/Headers/NetFSPlugin.h> — NetFS plugin vtable
- <https://keith.github.io/xcode-man-pages/mount_9p.8.html> — Apple's 9P client (virtio `fs_tag` only)
- <https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension>
- <https://tidbits.com/2023/03/10/apples-file-provider-forces-mac-cloud-storage-changes/>
- <https://eclecticlight.co/2026/04/15/privacy-which-folders-are-protected-in-tahoe/> — Tahoe Network Volumes consent
- <https://tightloop.io/userspace-filesystems/index.html> — independent survey reaching the same conclusion
- <https://docs.github.com/en/actions/reference/runners/github-hosted-runners> — passwordless sudo
