# fs9kit

Mount a [9P](https://9p.io/sys/doc/9.html) filesystem on macOS. No kernel
extension, no macFUSE, no reboot into Reduced Security.

```console
$ fs9p mount tcp!myserver!564 ~/nine
fs9p: connected to tcp!myserver!564, speaking 9P2000.L
fs9p: NFS bridge listening on 127.0.0.1:53341
fs9p: mounted tcp!myserver!564 on /Users/you/nine

$ ls ~/nine
docs  src  notes.txt
```

It speaks all three dialects — **9P2000**, **9P2000.u** and **9P2000.L** — so
it reaches QEMU/virtfs shares, WSL2, `diod`, gVisor, Plan 9 servers, `u9fs`,
and the Go and Rust servers people actually run.

## Why this exists

macOS has no way to add a filesystem from user space that is both easy to
install and works on the macOS people are running today:

- **macFUSE** needs a kernel extension, which on Apple Silicon means Reduced
  Security and two reboots.
- **FSKit**, Apple's answer, only learned to mount a filesystem with no block
  device behind it in **macOS 26**, and the user has to install an app and
  flip a switch in System Settings before it will work.

So fs9kit ships two backends over one core:

| | NFSv3 loopback *(default)* | FSKit |
|---|---|---|
| macOS | 11 → 26+ | 26.0+ |
| Kernel extension | no | no |
| Code signing | none | Developer ID |
| Setup | none | install an app, toggle a switch |
| Privileges | `sudo` to mount | `sudo` to mount |

The default backend runs an NFSv3 server on `127.0.0.1` that re-exports the 9P
tree, and mounts it with the `mount_nfs` already on your Mac. It is the same
technique [FUSE-T](https://github.com/macos-fuse-t/fuse-t) and `rclone
nfsmount` use, and it gives you a real kernel VFS mount: working `mmap`,
symlinks, permissions, atomic rename.

The reasoning behind these choices, and the evidence for it, is in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Install

Requires Swift 6.0 or later — the toolchain that ships with Xcode 16 and up.

```console
$ git clone https://github.com/mkmik/fs9kit && cd fs9kit
$ swift build -c release
$ cp .build/release/fs9p /usr/local/bin/
```

Check what your machine can do:

```console
$ fs9p doctor
```

## Use

```console
fs9p mount <address> <mountpoint>   mount a 9P server
fs9p umount <mountpoint>            unmount it again
fs9p serve <directory>              export a local directory over 9P
fs9p ls <address> [path]            list a directory
fs9p cat <address> <path>           write a file to stdout
fs9p stat <address> [path]          show attributes and volume information
fs9p tree <address> [path]          print the tree
fs9p doctor                         report which backends this machine can use
```

Addresses take the Plan 9 dial-string forms and some shorthands:

```
tcp!host!564    unix!/tmp/ns/9p    host:564    host    /tmp/ns/9p
```

### Mounting

```console
$ mkdir -p ~/nine
$ fs9p mount tcp!myserver!564 ~/nine
```

`fs9p mount` runs in the foreground for the life of the mount — the process
*is* the filesystem — and unmounts on exit, so a crash leaves a dead mount
point rather than a wedged one. Add `--background` to detach once the mount is
up.

`mount_nfs` needs privileges, so fs9p runs that one step under `sudo` and says
so before it does.

Useful options:

```
--read-only          refuse writes
--version=9P2000     pin the dialect instead of negotiating
--uname=NAME         user name to present at attach
--aname=TREE         which file tree to attach to
--msize=BYTES        largest message to negotiate
--mount-option=OPT   passed through to mount_nfs
```

Pinning `--version` is worth knowing about: some servers cannot answer a
Tversion they do not understand and simply say nothing, which costs a timeout
on every connection until fs9kit gives up and offers something older.

### Serving

`fs9p serve` exports a local directory over 9P. It is mostly here so you can
try a mount without first finding a Linux box:

```console
$ fs9p serve ~/Documents --port=5640 &
$ fs9p mount 127.0.0.1:5640 ~/nine
```

### The FSKit backend

On macOS 26 and later there is a native path that does not involve a loopback
NFS server. It needs an app installed and an extension enabled by hand; see
[`macos/README.md`](macos/README.md).

## What works

Everything below is exercised by the test suite on every push, on macOS 15 and
macOS 26, and — for the parts that do not need a Mac — on Linux too.

- **Protocol**: all three dialects, verified against golden wire vectors and
  round-tripped message by message.
- **Interoperability**: the client is tested against 9P servers written by
  other people in another language — `p9ufs` from
  [hugelgupf/p9](https://github.com/hugelgupf/p9) for 9P2000.L and `export9p`
  from [knusbaum/go9p](https://github.com/knusbaum/go9p) for base 9P2000.
- **A real mount**: CI mounts a served tree through the kernel's NFS client and
  exercises it with `cat`, `cp`, `find`, `mkdir`, `mv`, `rm`, `ln -s`, `chmod`,
  `truncate`, `df` and eight concurrent readers of a 4 MiB file, comparing
  checksums against the source.

Run them yourself:

```console
$ swift test                      # unit tests
$ Scripts/interop.sh all          # against third-party servers (needs Go)
$ Scripts/e2e-mount.sh            # a real mount (macOS, needs sudo)
```

## Known limits

- **No byte-range locking over the network.** The mount uses
  `nolocks,locallocks`, so `flock` and `fcntl` locks work between processes on
  your Mac but are not visible to other clients of the same server.
- **No authentication.** `Tauth` is not implemented; the bridge binds loopback
  only, so anything that can reach `127.0.0.1` can reach the mount.
- **Base 9P2000 cannot rename across directories** — the protocol has no way to
  express it — so `mv` between directories fails with `EXDEV` on that dialect.
  9P2000.L is fine.
- **Server support varies more than the specs suggest.** Some servers implement
  neither `statfs` nor `chmod`. fs9kit substitutes plausible values for the
  former and applies what it can for the latter, rather than failing the mount.

## Layout

```
Sources/NineP         wire codec for 9P2000, 9P2000.u and 9P2000.L
Sources/NinePClient   sockets, session multiplexing, a POSIX-shaped facade
Sources/NinePServer   a 9P server, used as a test fixture and by `fs9p serve`
Sources/FS9Core       the filesystem view: nodes, fid caching, attributes
Sources/FS9NFS        XDR, ONC RPC, MOUNTv3 and NFSv3 on loopback
Sources/FS9KitAdapter the FSKit backend's logic
Sources/fs9p          the command line tool
macos/                the FSKit app and extension bundle
docs/                 decisions, research and design notes
```

## Licence

Apache 2.0. See [LICENSE](LICENSE).
