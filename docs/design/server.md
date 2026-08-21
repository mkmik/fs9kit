# The 9P server

`Sources/NinePServer/` is a 9P **server**: a test fixture for the client in
`Sources/NinePClient/`, and a thing you can point a real `mount -t 9p` at when
you need to see what the kernel actually sends. It speaks 9P2000, 9P2000.u and
9P2000.L over TCP and Unix domain sockets, using only Foundation and the C
library.

## Layers

```
NinePServer          sockets, accept loop, one thread per connection
  └── NinePConnection   size[4] framing, decode, encode, msize enforcement
        └── NinePSession   fid table, dialect, all 9P semantics
              └── NinePFileServer   the backend: a tree of files
```

Each layer is usable on its own, which is mostly a testing decision:
`NinePSession` turns a `Frame` into a `Frame` and never touches a socket, so
almost every test drives it directly and only the framing tests need a real
connection.

## The backend protocol

`NinePFileServer` is **path-addressed**. The session maps each fid to a
`FilePath` (a list of name components) and, once opened, to a
`NinePFileHandle`; the provider only ever sees whole paths and POSIX-shaped
operations — `entry`, `list`, `open`, `create`, `mkdir`, `symlink`, `readlink`,
`link`, `unlink`, `rename`, `setattr`, `statfs`, `sync`.

Two consequences fall out of that split:

- Providers never implement walk cloning, tag handling, `.`/`..` resolution or
  dialect differences. A provider is a file tree, not a protocol engine.
- Components reaching a provider are already normalised. `..` is folded by the
  session *and* clamped at the attach point, so it cannot climb out of an
  export even before the provider defends itself.

Metadata is carried by one struct, `FileEntry`, whose `mode` is a POSIX
`st_mode` with type bits. The session derives both the 9P2000 `Stat` and the
9P2000.L `LinuxAttr` from it, so a provider models the filesystem once.

Directories deliberately do **not** get a handle. Both dialects hand a listing
out in resumable chunks, and the offsets in one reply must still mean the same
thing in the next request, so the session snapshots `list()` at open time and
serves chunks from the frozen copy. That is also what makes "an offset must be
one previously returned, or 0" checkable at all.

Two providers ship:

- `MemoryFileSystem` — an in-memory tree. Deterministic on purpose: inode
  numbers start at 1 in creation order, listings are sorted by name, and
  timestamps come from an injectable clock that defaults to a fixed instant.
- `LocalDirectoryFileSystem` — exports a host directory. Every path is built by
  `realpath`-ing the parent chain and checking the result is still under the
  export root, so neither `..` nor a symlink (absolute or not) reaches outside
  it. The final component is only resolved when the operation should follow it,
  which is what lets `readlink` and `unlink` see the link rather than its
  target. `followExternalSymlinks` opts back out of the containment check.

## Dialects and errors

Tversion decodes identically in all three dialects, so a connection starts with
a dialect-agnostic codec and switches to the negotiated one for everything
after. An unrecognised member of the 9P2000 family degrades to base 9P2000, as
version(5) allows; anything else gets `unknown`. An msize below
`minimumMessageSize` also gets `unknown` rather than an agreement the server
cannot honour. Tversion restarts the connection: every fid is clunked.

Failures are one internal type, `NinePServerError`, carrying both a message and
an errno, so the session can emit whichever shape the dialect wants —
`Rlerror(errno)` for .L, `Rerror(message, errno)` for .u, `Rerror(message)` for
base 9P2000.

**Errno values on the wire are always Linux-numbered**, whatever the host runs:
`ENOTEMPTY` is 39 on Linux and 66 on Darwin, and the two even disagree at 11.
Host errors go through `LinuxErrno.fromHost` (in the `NineP` module) before
they reach a reply; errors the server raises itself use the named constants in
`LinuxErrno`, which are spelled out rather than taken from platform headers.

## Concurrency

One thread accepts on each endpoint and one thread serves each connection, with
blocking reads. Requests on a connection are processed **sequentially** under a
lock. That is a real limitation — a slow read blocks the connection — but it
makes Tflush trivially correct: by the time a Tflush is decoded, the request it
names has already been answered, so `Rflush` is always the right reply.

Providers must still be thread-safe, because several connections share one.

`stop()` shuts every socket down before closing it — closing alone would not
wake a thread already blocked in `read` — then waits for the threads to exit.

## msize

No frame the server emits exceeds the negotiated msize. Rread and Rreaddir
payloads are clamped to `msize - 11`, and the connection re-checks the encoded
size of every reply before writing it.

An incoming frame larger than msize is not simply dropped: the 3-byte header is
read for its tag, the body is discarded and the client gets `EMSGSIZE`, so the
stream stays in sync. Beyond `maxDrainBytes` the connection is closed instead —
draining an arbitrarily large frame is exactly the denial of service the msize
limit exists to prevent.

## What is deliberately missing

- **Authentication.** Tauth is refused; Tattach ignores `afid`.
- **Extended attributes.** Txattrwalk binds newfid and reports size 0 so the
  client's clunk succeeds; every other use of that fid, and Txattrcreate, is
  `EOPNOTSUPP`.
- **Real locking.** Tlock always succeeds and Tgetlock always reports "no
  conflicting lock". Nothing is recorded. Clients that lock defensively work;
  clients relying on locks for exclusion do not get it.
- **Tmknod.** Device nodes are `EOPNOTSUPP`; the provider protocol has no way
  to express them.
- **Per-connection request overlap.** See Concurrency above.
- **Permission checks.** `uname`/`n_uname` are recorded but never enforced; the
  host filesystem's own permissions are the only access control.

One note for interoperability: the `type[1]` byte of an Rreaddir entry is a
POSIX `d_type` here, which is what the specification says, but some servers
(p9ufs) write the qid type instead. A *client* must not trust it; the tests
here assert only on what this server emits.
