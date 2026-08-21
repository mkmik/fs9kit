# 9P Protocol Reference for a Swift Client (`fs9kit`)

Status: research reference, written to be sufficient to implement the wire codec
without consulting other documents. All wire layouts marked **[verified]** were
checked by byte-level probing of live servers (see [Appendix C](#appendix-c-verification-log)).

Primary sources: Plan 9 `intro(5)`/`stat(5)` (via the 9P2000 RFC draft),
[9P2000.u RFC draft](https://ericvh.github.io/9p-rfc/rfc9p2000.u.html),
[diod `protocol.md`](https://github.com/chaos/diod/blob/master/protocol.md) (the de-facto 9P2000.L spec),
Linux `include/net/9p/9p.h`, `net/9p/protocol.c`, `net/9p/client.c`,
and [Linux `Documentation/filesystems/9p.rst`](https://docs.kernel.org/filesystems/9p.html).

---

## Recommendations

### 1. Implement **9P2000.L** first, with **9P2000** (base) as a secondary dialect

| | verdict |
|---|---|
| **9P2000.L** | **Implement first.** It is what every modern producer speaks: Linux `v9fs`, QEMU virtfs, WSL2's Plan9 server, gVisor, diod, `hugelgupf/p9`, `rs9p`. It maps 1:1 onto POSIX/`FileManager` semantics (`getattr`/`setattr`/`readdir`/`mkdir`/`symlink`/`rename`/`unlinkat`/`statfs`/`fsync`/`lock`), returns numeric errnos, and needs no stat-marshalling gymnastics. |
| **9P2000** (base) | **Implement second.** Small incremental cost (~6 extra messages, one `stat` codec). Required to talk to `u9fs`, plan9port `exportfs`/`9pserve`, 9front, `knusbaum/go9p`, `docker/go-p9p`, `droyo/styx`, `Harvey-OS/ninep` — i.e. essentially the entire Plan 9-native world. |
| **9P2000.u** | **Do not implement as a primary target; add opportunistically.** It is base 9P2000 plus four stat fields, one `Tcreate` field, one `Rerror` field and one `Tattach`/`Tauth` field. Once base 9P2000 exists, `.u` is ~50 lines of conditional codec. Its only unique value is talking to QEMU virtfs configured with `-o version=9p2000.u`, older `lionkov/go9p` servers, and `py9p`. |

Concretely: build one codec whose `encode`/`decode` take a `dialect` enum
(`.base`, `.dotU`, `.dotL`) — this is exactly how the Linux kernel does it
(`proto_version` + the `?` conditional-field marker in `p9pdu_readf`), and it
costs almost nothing versus writing `.L` alone.

### 2. CI interop fixture on macOS/arm64 GitHub Actions

**Primary: `hugelgupf/p9`'s `p9ufs` (Go, 9P2000.L).** Verified to cross-compile
cleanly for `darwin/arm64` with the stock Go toolchain, zero cgo, zero
Homebrew, one command:

```bash
go install github.com/hugelgupf/p9/cmd/p9ufs@latest      # v0.4.1, builds for darwin/arm64
"$(go env GOPATH)/bin/p9ufs" -root "$FIXTURE_DIR" 127.0.0.1:5640
```

**Secondary: `knusbaum/go9p`'s `export9p` (Go, 9P2000 base).** Same story, gives
you base-dialect coverage:

```bash
go install github.com/knusbaum/go9p/cmd/export9p@latest
"$(go env GOPATH)/bin/export9p" -dir "$FIXTURE_DIR" -address 127.0.0.1:5641
```

Between those two, one `go install` step covers both dialects you plan to ship,
with no C toolchain and no `brew` dependency. Add **`u9fs`** (C, 9P2000, builds
with a bare `make`, `__APPLE__`-aware) as an optional third fixture if you want a
*non-Go, canonical Plan 9* implementation to test against — it needs an inetd
shim (`brew install socat`) because it serves on stdin/stdout.

**Rejected:** `diod` (Linux-only: `_GNU_SOURCE`, `sys/prctl.h`, munge),
`rs9p`/`rust-9p` (**verified broken** on `aarch64-apple-darwin` — `nix::sys::statfs`
returns `u32` on Darwin where the code expects `u64`; 5 compile errors, trivially
patchable but not out-of-the-box), `plan9port` (**no longer in homebrew-core or
homebrew-cask** — source build only), `docker/go-p9p` (client `9pr` only, no
server binary; `@latest` currently fails module resolution on Go < 1.25).

### 3. Things that will bite you, decided up front

1. **9P2000.L error codes are *Linux* errno numbers on the wire**, not host errnos.
   `ENOSYS` is 38 on Linux but 78 on Darwin; `EAGAIN` is 11 vs 35; `ENOTEMPTY` 39
   vs 66. You **must** ship a Linux-errno → `POSIXError`/`Errno` mapping table.
   [Verified]: `p9ufs` returns `Rlerror ecode=38` for unsupported `Tstatfs`.
2. **`Rstat`/`Twstat` carry the stat blob's size twice.** `Rstat` is
   `tag[2] n[2] stat[n]`, and `stat` itself begins with `size[2]` where
   `n == size + 2`. [Verified] against `knusbaum/go9p`: outer `n=63`, inner `size=61`.
3. **`Rreaddir` dirent `type[1]` is not reliable.** It is meant to be a Linux
   `DT_*` value, but `hugelgupf/p9` puts the *qid type byte* there
   ([verified]: `128` = `QTDIR` for a directory, where `DT_DIR` is `4`).
   Always classify from `qid.type & QTDIR`, never from the dirent type byte.
4. **`Tstatfs` is optional in practice.** `p9ufs` answers `ENOSYS`. Treat a
   failing `statfs` as non-fatal.
5. **Directory fids must be opened before reading.** `Treaddir`/`Tread` on a
   fid that has not seen `Tlopen`/`Topen` fails.
6. **msize is not always clamped.** `p9ufs` echoed a requested 1 MiB verbatim;
   `u9fs` clamps to 8216; `export9p` clamps to 65535. Always use
   `min(requested, Rversion.msize)` and re-derive read/write chunk sizes from it.
7. **Version-string downgrade differs per server.** The spec says a server that
   does not know `9P2000.x` should reply with the longest prefix it does support
   (i.e. `9P2000`). `u9fs` does this correctly (`9P2000.u` → `9P2000`);
   `hugelgupf/p9` does *not* (`9P2000.u` → `unknown`); `knusbaum/go9p` **hangs**
   on `9P2000.u` (no reply at all). Your negotiation loop needs a timeout and
   must handle both `unknown` and silence.

---

## 1. Base 9P2000

### 1.1 Encoding rules

* All integers are **unsigned little-endian**. Sizes: 1, 2, 4, 8 bytes.
  There are no signed fields anywhere in the protocol.
* No alignment, no padding. Fields are packed back to back.
* **String** `s`: `len[2]` followed by exactly `len` bytes of **UTF-8**, with
  **no NUL terminator**. The NUL character is illegal inside 9P strings.
  `len` counts bytes, not runes. Max string length is therefore 65535 bytes.
* **Byte-count-prefixed data** `data[count]`: preceded by a `count[4]`.
* **qid**: fixed 13 bytes, see §1.3.
* Every message is:

```
size[4] type[1] tag[2] <body...>
```

`size` **includes itself**, so `size == 4 + 1 + 2 + len(body)` and the minimum
legal `size` is 7. Read `size` first, then read `size - 4` more bytes; the whole
message is then in hand. There is no other framing, on any transport.

Swift codec sketch:

```swift
// header is always 7 bytes
struct Header { var size: UInt32; var type: UInt8; var tag: UInt16 }
// body length == size - 7
```

* **Maximum message size** is the negotiated `msize` (§1.6). A message larger
  than `msize` is a protocol error; servers may drop the connection.

### 1.2 Message type codes

T-messages are even, R-messages are `T+1`. Base 9P2000 occupies 100–127.

| Code | Message | Code | Message |
|-----:|---------|-----:|---------|
| 100 | `Tversion` | 101 | `Rversion` |
| 102 | `Tauth`    | 103 | `Rauth` |
| 104 | `Tattach`  | 105 | `Rattach` |
| 106 | *(`Terror`, illegal — never sent)* | 107 | `Rerror` |
| 108 | `Tflush`   | 109 | `Rflush` |
| 110 | `Twalk`    | 111 | `Rwalk` |
| 112 | `Topen`    | 113 | `Ropen` |
| 114 | `Tcreate`  | 115 | `Rcreate` |
| 116 | `Tread`    | 117 | `Rread` |
| 118 | `Twrite`   | 119 | `Rwrite` |
| 120 | `Tclunk`   | 121 | `Rclunk` |
| 122 | `Tremove`  | 123 | `Rremove` |
| 124 | `Tstat`    | 125 | `Rstat` |
| 126 | `Twstat`   | 127 | `Rwstat` |

Type 106 is reserved and unused: 9P has no `Terror`. Any T-message may be
answered with `Rerror` (107) instead of its matching R-message — with the sole
exception of `Tversion`, which is always answered by `Rversion`.

### 1.3 qid — 13 bytes

```
qid = type[1] version[4] path[8]
```

* `path[8]` — the server's unique identifier for the file. Two files are the
  same file iff their `path` (and `type`) are equal. Think inode number.
* `version[4]` — bumped every time the file's contents change. Used for caching.
* `type[1]` — high 8 bits of the file mode (see `DM*` in §1.5):

| Name | Value | Meaning |
|---|---:|---|
| `QTDIR`      | `0x80` | directory |
| `QTAPPEND`   | `0x40` | append-only |
| `QTEXCL`     | `0x20` | exclusive use (one client at a time) |
| `QTMOUNT`    | `0x10` | mounted channel (Plan 9 internal) |
| `QTAUTH`     | `0x08` | authentication file (from `Tauth`) |
| `QTTMP`      | `0x04` | not backed up / temporary |
| `QTSYMLINK`  | `0x02` | symbolic link — **9P2000.u / .L only** |
| `QTLINK`     | `0x01` | hard link — **9P2000.u only**, rarely used |
| `QTFILE`     | `0x00` | plain file (the absence of all other bits) |

`QTFILE` is `0`, so test with masks: `isDir = (qid.type & 0x80) != 0`.

### 1.4 Open mode bits (`Topen`/`Tcreate` `mode[1]`)

The low two bits are an *enumeration*, not a bitfield:

| Name | Value | Meaning |
|---|---:|---|
| `OREAD`   | `0x00` | open for read |
| `OWRITE`  | `0x01` | open for write |
| `ORDWR`   | `0x02` | open for read and write |
| `OEXEC`   | `0x03` | open for execute (read, but check execute perm) |
| `OTRUNC`  | `0x10` | or'ed in: truncate on open |
| `OCEXEC`  | `0x20` | or'ed in: close on exec (client-side only in Plan 9; also seen as `OREXEC`) |
| `ORCLOSE` | `0x40` | or'ed in: remove the file when the fid is clunked |
| `OAPPEND` | `0x80` | or'ed in (Linux `p9.h` only; not in classic Plan 9 `open(5)`) |
| `OEXCL`   | `0x1000` | `Tcreate` only: fail if the file exists |

Only `mode[1]` is on the wire in base 9P2000, so `OEXCL` (0x1000) cannot be
expressed in `Topen`/`Tcreate` there — it is a `create(2)` library flag.
Mask sent on the wire is `mode & 0xFF`. (Linux's `P9L_MODE_MASK = 0x1FFF`
covers the 9P2000.L `Tlopen flags[4]` case.)

### 1.5 Stat and file mode bits

File `mode[4]` = permission bits (low 9, standard Unix `rwxrwxrwx`) plus flags
in the top byte:

| Name | Value | qid bit |
|---|---:|---|
| `DMDIR`       | `0x80000000` | `QTDIR` |
| `DMAPPEND`    | `0x40000000` | `QTAPPEND` |
| `DMEXCL`      | `0x20000000` | `QTEXCL` |
| `DMMOUNT`     | `0x10000000` | `QTMOUNT` |
| `DMAUTH`      | `0x08000000` | `QTAUTH` |
| `DMTMP`       | `0x04000000` | `QTTMP` |
| `DMSYMLINK`   | `0x02000000` | `QTSYMLINK` — **.u/.L** |
| `DMLINK`      | `0x01000000` | `QTLINK` — **.u** |
| `DMDEVICE`    | `0x00800000` | — **.u** |
| `DMNAMEDPIPE` | `0x00200000` | — **.u** |
| `DMSOCKET`    | `0x00100000` | — **.u** |
| `DMSETUID`    | `0x00080000` | — **.u** |
| `DMSETGID`    | `0x00040000` | — **.u** |
| `DMSETVTX`    | `0x00010000` | — **.u** (sticky) |

Permission bits: owner `rwx` = bits 8,7,6 (`0o700`), group = bits 5,4,3
(`0o070`), other = bits 2,1,0 (`0o007`). Note `qid.type == UInt8(mode >> 24)`.

**stat wire structure** [verified]. The Linux kernel decodes it with the format
string `"wwdQdddqssss?sugu"`, which expands to:

| Field | Size | Notes |
|---|---:|---|
| `size`   | 2 | byte count of *everything after this field* |
| `type`   | 2 | server/kernel use; 0 from Unix servers |
| `dev`    | 4 | server/kernel use; 0 from Unix servers |
| `qid`    | 13 | `type[1] version[4] path[8]` |
| `mode`   | 4 | `DM*` bits + permissions |
| `atime`  | 4 | seconds since Unix epoch (**32-bit — Y2038**) |
| `mtime`  | 4 | seconds since Unix epoch |
| `length` | 8 | file size in bytes; 0 for directories by convention |
| `name`   | s | file name; `"/"` for the server root |
| `uid`    | s | owner **name** (string!) |
| `gid`    | s | group name |
| `muid`   | s | name of last modifier |
| *(9P2000.u only, from here on)* | | |
| `extension` | s | symlink target / `"b major minor"` for devices |
| `n_uid`  | 4 | numeric uid hint |
| `n_gid`  | 4 | numeric gid hint |
| `n_muid` | 4 | numeric uid of last modifier |

So a base-9P2000 stat entry occupies `2 + size` bytes total, and
`size == 47 + len(name) + len(uid) + len(gid) + len(muid)` (where each `len`
already includes the 2-byte string prefix... concretely:
`size = 2+4+13+4+4+8 = 35` fixed bytes plus the four length-prefixed strings).

**The `Rstat` / `Twstat` double-size quirk** [verified]:

```
Rstat  tag[2] n[2]        stat[n]      -- and stat[0..1] is itself size[2], n == size + 2
Twstat tag[2] fid[4] n[2] stat[n]      -- same
```

Kernel format strings: `Rstat` is read as `"wS"` (a discarded `w`, then the
`S`tat struct), `Twstat` is written as `"dwS"`. Verified against
`knusbaum/go9p`: `n = 63`, inner `size = 61`. **Do not omit the outer `n`.**

By contrast, a directory `Tread` returns *bare concatenated stat entries* with
**no** outer wrapper — each entry is just `size[2] ...body...` [verified].

**"Don't touch" values in `Twstat`**: leave a field unchanged by sending

* zero-length string (`len = 0`) for `name`/`uid`/`gid`/`muid`/`extension`
* all-ones for integers: `type = 0xFFFF`, `dev = 0xFFFFFFFF`,
  `qid.type = 0xFF`, `qid.version = 0xFFFFFFFF`, `qid.path = 0xFFFFFFFFFFFFFFFF`,
  `mode = 0xFFFFFFFF`, `atime = 0xFFFFFFFF`, `mtime = 0xFFFFFFFF`,
  `length = 0xFFFFFFFFFFFFFFFF`, and `n_uid`/`n_gid`/`n_muid = 0xFFFFFFFF`.

`length` set to a real value = truncate/extend. Setting `mode` changes
permissions. Setting `name` renames (within the same directory). Setting `gid`
changes group.

**Special case**: a `Twstat` in which *every* field is a don't-touch value is a
request to **flush the file's contents to stable storage** (`fsync`), answered
by `Rwstat`.

### 1.6 Message-by-message reference

Notation: `field[n]` = fixed n-byte little-endian integer; `field[s]` = string;
`n*(x)` = `n` repetitions.

#### version — negotiate protocol and message size

```
Tversion tag[2] msize[4] version[s]
Rversion tag[2] msize[4] version[s]
```

* `tag` **must** be `NOTAG = 0xFFFF`.
* Must be the first message on a connection. Sending it again resets the
  connection: all fids are clunked, all outstanding requests are flushed.
* `msize` is the maximum size of *any* message including the `size[4]` field
  itself. The client proposes; the server replies with a value **≤** the
  proposal; the client must then use the server's value.
* `version` is `"9P2000"`, `"9P2000.u"` or `"9P2000.L"`. If the server does not
  support the requested version it should reply with the longest supported
  prefix (dropping everything from the first `.`), or the literal string
  `"unknown"` if it supports nothing. On `"unknown"` the client must not
  continue. (See "things that will bite you" #7 — real servers vary.)
* An `Rerror` is **never** a legal reply to `Tversion`.

#### auth — establish an authentication fid

```
Tauth tag[2] afid[4] uname[s] aname[s]                 (base 9P2000)
Tauth tag[2] afid[4] uname[s] aname[s] n_uname[4]      (9P2000.u and .L)
Rauth tag[2] aqid[13]
```

* `afid` is a new fid the client picks; it becomes a special file that the
  client reads/writes to run the authentication protocol.
* `aqid.type` will have `QTAUTH` set.
* If the server requires **no** authentication it replies `Rerror`
  (e.g. `"u9fs: authentication not required"`); the client then passes
  `afid = NOFID` to `Tattach`. This is by far the common case: neither the Linux
  kernel client, nor `hugelgupf/p9`, nor `knusbaum/go9p` implement `Tauth`
  at all. **A macOS client can skip `Tauth` entirely for v1.**

#### attach — bind a fid to a file tree

```
Tattach tag[2] fid[4] afid[4] uname[s] aname[s]                (base 9P2000)
Tattach tag[2] fid[4] afid[4] uname[s] aname[s] n_uname[4]     (9P2000.u and .L)
Rattach tag[2] qid[13]
```

[verified] against the kernel's `p9_client_rpc(clnt, P9_TATTACH, "ddss?u", ...)`
— the `?` marks "only when proto is `.u` or `.L`".

* `fid` becomes the root of the attached tree; must be currently unused.
* `afid` = `NOFID` (`0xFFFFFFFF`) when there is no authentication.
* `uname` — the user name to act as. `n_uname` — the numeric uid; send
  `0xFFFFFFFF` ("unspecified") if you only have a name. Servers should prefer
  `n_uname` when it is not `~0`.
* `aname` — which of possibly several trees to attach. Conventions:
  * Plan 9 / `u9fs` / `9pserve`: usually `""` (the single exported tree).
  * `diod`: **the exported path**, e.g. `aname=/home/bob`.
  * QEMU virtfs / `trans=virtio`: the **mount tag**, matched against
    `-device virtio-9p-pci,mount_tag=...`.
  * WSL2: `aname` selects the distro's root.
  * `hugelgupf/p9`'s `p9ufs`: ignored (root comes from the `-root` flag).
  Send `""` unless you know better; make it a client parameter.
* `Rattach.qid` is the root directory's qid (`QTDIR` set).

#### error

```
Rerror tag[2] ename[s]              (base 9P2000)
Rerror tag[2] ename[s] errno[4]     (9P2000.u)
Rlerror tag[2] ecode[4]             (9P2000.L — different message, code 7)
```

Base 9P has **only free-form strings**. There is no code. Canonical strings
emitted by `u9fs` (a good corpus to pattern-match against, though you should not
depend on exact text):

```
"authentication failed"                                    "not a directory"
"fid unknown or out of range"                              "not a member of proposed group"
"bad offset in directory read"                             "only owner can change group in wstat"
"bad use of fid"                                           "permission denied"
"wstat can't convert between files and directories"        "no access to special file"
"file or directory already exists"                         "i/o count too large"
"fid already in use"                                       "unknown group" / "unknown user"
"bogus wstat buffer"
```

`u9fs` also forwards `strerror(errno)` text, e.g. `"No such file or directory"`
[verified]. Plan 9 servers commonly emit lowercase strings such as
`"file does not exist"`, `"file exists"`, `"permission denied"`,
`"directory entry not found"`, `"file is not a directory"`.

Practical advice: expose the raw string on the Swift error type, and do
best-effort substring matching to derive an `Errno` (`"does not exist"`/`"No such"`
→ `ENOENT`, `"permission denied"` → `EACCES`, `"exists"` → `EEXIST`,
`"not a directory"` → `ENOTDIR`, `"not empty"` → `ENOTEMPTY`).

#### flush — abort an outstanding request

```
Tflush tag[2] oldtag[2]
Rflush tag[2]
```

* Requests that the server abandon the in-flight request whose tag is `oldtag`.
* The server may still answer the original request normally; the client must
  handle either the original R-message or nothing.
* When `Rflush` arrives, the client may reuse `oldtag`. **Before** `Rflush`
  arrives, `oldtag` is still in use.
* Multiple `Tflush`es may target the same `oldtag`; they must be answered in
  order, and the original message's reply (if any) precedes all of them.
* A `Tflush` for a tag the server does not know is answered immediately with
  `Rflush`.
* A `Tflush` is never answered with `Rerror`.
* Flushing is what you wire `Task.cancel()` to in Swift structured concurrency.

#### walk — traverse the file tree, and/or clone a fid

```
Twalk tag[2] fid[4] newfid[4] nwname[2] nwname*(wname[s])
Rwalk tag[2] nwqid[2] nwqid*(wqid[13])
```

* `nwname == 0` is a **clone**: `newfid` becomes a second reference to the same
  file as `fid`. Reply carries `nwqid == 0`. This is how you get a spare fid to
  open without losing your directory handle.
* `nwname` **must be ≤ 16** (`MAXWELEM`). Longer paths require multiple `Twalk`s.
* `fid` must not be open (no `Topen`/`Tcreate`/`Tlopen`/`Tlcreate` on it yet).
  `newfid` must be unused, unless `newfid == fid` (allowed: walk in place).
* Each `wname` must be a single path element: no `/`, no embedded NUL. `".."`
  is legal and means parent; `".."` at the server root is a no-op. `"."` is
  **not** generally supported — do not send it.
* **Partial walk semantics** (this is the subtle bit):
  * If `nwqid == nwname`, the walk fully succeeded and `newfid` now refers to
    the last element.
  * If `0 < nwqid < nwname`, the walk stopped early. **`newfid` is NOT
    established** and `fid` is unchanged. The reply is `Rwalk`, not `Rerror`.
  * If the **first** element fails, the server returns `Rerror` (or `Rlerror`)
    instead of an `Rwalk` with `nwqid == 0` [verified against `u9fs`: walking a
    nonexistent name yields `Rerror "No such file or directory"`].
  * Therefore: only treat the walk as successful when `nwqid == nwname`, and
    only consider `newfid` allocated in that case (or in the clone case).
* Every element except the last must be a directory the user can search (`x`).

#### open

```
Topen tag[2] fid[4] mode[1]
Ropen tag[2] qid[13] iounit[4]
```

* Prepares an existing file for I/O. The fid must not already be open.
* `mode` per §1.4.
* Opening a directory is only legal with `OREAD` (no writing, no truncation).
* `iounit`: if non-zero, the maximum number of bytes guaranteed to be
  transferred in a single `Tread`/`Twrite` without the server splitting the
  operation. If zero, use `msize - 24` for reads/writes (the `IOHDRSZ = 24`
  constant in Linux). Both `p9ufs` and `u9fs` returned `iounit = 0` [verified].

#### create

```
Tcreate tag[2] fid[4] name[s] perm[4] mode[1]                 (base 9P2000)
Tcreate tag[2] fid[4] name[s] perm[4] mode[1] extension[s]    (9P2000.u)
Rcreate tag[2] qid[13] iounit[4]
```

* `fid` must be a fid for a **directory**, opened for nothing (not yet opened),
  and the user must have `w` on it. On success **`fid` is mutated in place** to
  refer to the newly created file, already open with `mode`. There is no
  separate `newfid`.
* `perm` carries `DM*` bits + permissions. `DMDIR` set ⇒ make a directory
  (and then `mode` must be `OREAD`). `.u` adds `DMSYMLINK`, `DMDEVICE`,
  `DMNAMEDPIPE`, `DMSOCKET` and uses `extension` to carry the payload
  (`"target"` for symlink, `"b 1 2"` / `"c 1 2"` for devices).
* Effective permissions: for a plain file `perm & (~0o666 | (dirperm & 0o666))`;
  for a directory `perm & (~0o777 | (dirperm & 0o777))`.
* `Tcreate` on an existing name is an error (there is no O_EXCL/O_CREAT split).
* The owner is the attach user; the group is inherited from the directory.

#### read

```
Tread tag[2] fid[4] offset[8] count[4]
Rread tag[2] count[4] data[count]
```

* `count` in the reply may be less than requested; `count == 0` means EOF.
* `count` must be ≤ `msize - 11` (`Rread` header is `size[4] type[1] tag[2]
  count[4]` = 11 bytes). Practically, use `min(iounit ?: msize - 24, want)`.
* **Directories**: the reply is an integral number of **stat entries**
  (§1.5 layout, each with its own `size[2]` prefix, concatenated, no wrapper)
  [verified]. A partial entry is never returned.
* **Directory offsets are opaque cursors, not byte positions you may choose.**
  The `offset` of a `Tread` on a directory must be either `0` or exactly
  `previous_offset + previous_returned_count`. Any other value is an error
  (`"bad offset in directory read"`). You cannot seek into the middle of a
  directory. In Swift, model directory enumeration as a sequential cursor.
* Reading at or past EOF returns `count == 0`.

#### write

```
Twrite tag[2] fid[4] offset[8] count[4] data[count]
Rwrite tag[2] count[4]
```

* `count` must be ≤ `msize - 23` (`Twrite` header is 4+1+2+4+8+4 = 23 bytes;
  Linux uses `P9_IOHDRSZ = 24` as a conservative bound).
* `Rwrite.count` may be less than requested — loop.
* Writing to a directory is illegal.
* On a file opened with `OAPPEND`/`DMAPPEND`, `offset` is ignored.

#### clunk — release a fid

```
Tclunk tag[2] fid[4]
Rclunk tag[2]
```

* The fid becomes invalid whether or not an error is returned. Never retry.
* If the file was opened with `ORCLOSE`, it is removed now.

#### remove

```
Tremove tag[2] fid[4]
Rremove tag[2]
```

* Removes the file **and clunks the fid**, again regardless of outcome.
  Never send `Tclunk` after `Tremove`.
* Requires `w` on the *parent* directory.

#### stat / wstat

```
Tstat tag[2] fid[4]
Rstat tag[2] n[2] stat[n]          -- note the double size, §1.5
Twstat tag[2] fid[4] n[2] stat[n]
Rwstat tag[2]
```

* `Tstat` requires no particular permission on the file, only that you could
  walk to it.
* `Twstat` changes: name (rename in place), length (truncate), mode, mtime, gid.
  Only the owner (or group leader, for `gid`) may change most things.
  `atime`, `muid`, `qid`, `type`, `dev` cannot be changed — send don't-touch.
* Changing the `DMDIR` bit is illegal ("wstat can't convert between files and
  directories").
* All-don't-touch = `fsync` (§1.5).

### 1.7 Fids, tags and lifecycle

**fid** — a client-chosen 32-bit handle for a file on the server. The client is
the sole allocator; the server never invents one. `NOFID = 0xFFFFFFFF` is
reserved and means "no fid".

Lifecycle:

```
Tattach(fid=root)  →  fid is a directory handle
Twalk(fid, newfid, names…)  →  newfid is a handle to some descendant
Topen/Tlopen(newfid, mode)  →  newfid is now an open file; I/O allowed
Tread/Twrite(newfid, …)
Tclunk(newfid)  →  newfid is free again
```

Rules that matter:

* A fid is either **unopened** (walkable, statable, creatable-into) or **open**
  (readable/writable, no longer walkable). You cannot walk from an open fid.
* Clone (`Twalk` with `nwname == 0`) is the standard way to keep a durable
  directory handle and get a throwaway to open.
* Allocate fids from a monotonically-increasing counter with a free list;
  never reuse a fid until its `Rclunk` (or `Rremove`) arrives.
* On `Tversion` the entire fid space is reset.
* A safe client keeps a `Set<UInt32>` of in-flight fids and asserts uniqueness.

**tag** — a client-chosen 16-bit request identifier that matches R to T.
`NOTAG = 0xFFFF` is reserved for `Tversion`. Tags may be reused as soon as the
reply arrives. Multiple requests may be outstanding concurrently and servers may
answer **out of order**, so the client needs a `[UInt16: Continuation]` map.
9P2000 has no ordering guarantee except that `Tflush` responses are ordered
relative to the request they flush.

### 1.8 msize negotiation, iounit and chunking

```
requested = 1 << 20                       // pick something generous
send Tversion(msize: requested, version: "9P2000.L")
effective = min(requested, Rversion.msize)
maxRead   = iounit != 0 ? iounit : effective - 24   // P9_IOHDRSZ
maxWrite  = iounit != 0 ? iounit : effective - 24
maxReaddir= effective - 24                          // P9_READDIRHDRSZ = 24
```

Observed values [verified]: `hugelgupf/p9` echoes the request unchanged (1 MiB
granted), `u9fs` clamps to 8216, `knusbaum/go9p` clamps to 65535, Linux `v9fs`
defaults to 8 KiB (`trans=tcp`) and up to 512 KiB (`trans=virtio`).

Always allocate the receive buffer to `effective`, and reject any inbound
`size` > `effective` as a protocol violation.

---

## 2. 9P2000.u — the Unix extension (brief)

`.u` is base 9P2000 with the *same* message codes and *same* semantics, plus
these deltas. Negotiate with `version = "9P2000.u"`.

| Where | Base 9P2000 | 9P2000.u |
|---|---|---|
| `stat` | `… muid[s]` | `… muid[s] extension[s] n_uid[4] n_gid[4] n_muid[4]` |
| `Tcreate` | `fid[4] name[s] perm[4] mode[1]` | `fid[4] name[s] perm[4] mode[1] extension[s]` |
| `Rerror` | `ename[s]` | `ename[s] errno[4]` |
| `Tattach` | `fid[4] afid[4] uname[s] aname[s]` | `… aname[s] n_uname[4]` |
| `Tauth` | `afid[4] uname[s] aname[s]` | `… aname[s] n_uname[4]` |

Notes:

* The published RFC draft's "Changed Messages" table omits `n_uname` from
  `Tattach`/`Tauth`, but every real implementation includes it. The Linux kernel
  encodes `Tattach` as `"ddss?u"` — the `?` means "the following field is present
  only for `.u` and `.L`". **Follow the implementations, not the draft.**
* `n_uid`/`n_gid`/`n_muid`/`n_uname` use `0xFFFFFFFF` for "unspecified".
  A server should populate both string and numeric forms; a client should prefer
  the numeric form when it is not `~0`.
* `errno[4]` is "a hint of the underlying UNIX error number". It is **not
  authoritative** and its numbering is whatever the server's platform uses —
  the draft explicitly says clients should give preference to the string.
* New `DM*` bits (`DMSYMLINK 0x02000000`, `DMLINK 0x01000000`,
  `DMDEVICE 0x00800000`, `DMNAMEDPIPE 0x00200000`, `DMSOCKET 0x00100000`,
  `DMSETUID 0x00080000`, `DMSETGID 0x00040000`, `DMSETVTX 0x00010000`) and the
  matching qid bits `QTSYMLINK 0x02`, `QTLINK 0x01`.
* `extension[s]` payload format:
  * symlink → the link target path
  * block device → `"b major minor"`; char device → `"c major minor"`
  * named pipe / socket → empty
  * regular file/dir → empty
* There is **no** extended-attribute support in `.u` (that arrives in `.L`).
* Version negotiation: a `.u`-unaware server should reply `"9P2000"` to a
  `"9P2000.u"` request (that is the documented use of the `.` suffix), and the
  client must then degrade to base.

---

## 3. 9P2000.L — the Linux dialect (full detail)

Negotiate with `version = "9P2000.L"`. This is a **different message set**, not
a superset: `Topen`, `Tcreate`, `Tstat`, `Twstat` and `Rerror` are all
*replaced*. What survives from base 9P2000 is exactly:

`Tversion`, `Tflush`, `Twalk`, `Tread`, `Twrite`, `Tclunk`, `Tremove`
— plus the **9P2000.u forms** of `Tauth` and `Tattach` (i.e. with `n_uname[4]`).

Everything else is `.L`-specific. `Tstat`/`Twstat`/`Topen`/`Tcreate` **must not**
be used on a `.L` connection (diod and QEMU will reject them).

### 3.1 Message code table

| Code | Message | Code | Message |
|-----:|---------|-----:|---------|
| 6 | *(`Tlerror`, unused)* | 7 | **`Rlerror`** |
| 8 | `Tstatfs` | 9 | `Rstatfs` |
| 12 | `Tlopen` | 13 | `Rlopen` |
| 14 | `Tlcreate` | 15 | `Rlcreate` |
| 16 | `Tsymlink` | 17 | `Rsymlink` |
| 18 | `Tmknod` | 19 | `Rmknod` |
| 20 | `Trename` | 21 | `Rrename` |
| 22 | `Treadlink` | 23 | `Rreadlink` |
| 24 | `Tgetattr` | 25 | `Rgetattr` |
| 26 | `Tsetattr` | 27 | `Rsetattr` |
| 30 | `Txattrwalk` | 31 | `Rxattrwalk` |
| 32 | `Txattrcreate` | 33 | `Rxattrcreate` |
| 40 | `Treaddir` | 41 | `Rreaddir` |
| 50 | `Tfsync` | 51 | `Rfsync` |
| 52 | `Tlock` | 53 | `Rlock` |
| 54 | `Tgetlock` | 55 | `Rgetlock` |
| 70 | `Tlink` | 71 | `Rlink` |
| 72 | `Tmkdir` | 73 | `Rmkdir` |
| 74 | `Trenameat` | 75 | `Rrenameat` |
| 76 | `Tunlinkat` | 77 | `Runlinkat` |
| 100 | `Tversion` | 101 | `Rversion` |
| 102 | `Tauth` | 103 | `Rauth` |
| 104 | `Tattach` | 105 | `Rattach` |
| 108 | `Tflush` | 109 | `Rflush` |
| 110 | `Twalk` | 111 | `Rwalk` |
| 116 | `Tread` | 117 | `Rread` |
| 118 | `Twrite` | 119 | `Rwrite` |
| 120 | `Tclunk` | 121 | `Rclunk` |
| 122 | `Tremove` | 123 | `Rremove` |

Codes 10, 11, 28, 29, 34–39, 42–49, 56–69, 78–99 are unassigned. Codes 106/107
(`Rerror`) and 112–115, 124–127 exist in the enum but are **not** used on a
`.L` connection.

### 3.2 Full field layouts

All layouts below are the message **body**, i.e. what follows `size[4] type[1]`.
Every body begins with `tag[2]`. Verified against the Linux kernel's
`p9_client_rpc` format strings (`d`=4, `w`=2, `b`=1, `q`=8, `s`=string,
`u`/`g`=4 (uid/gid), `Q`=qid[13], `T`=walk names, `R`=walk qids, `D`=count+data,
`A`=getattr struct, `I`=setattr struct, `S`=stat struct).

```
Rlerror      tag[2] ecode[4]
             -- ecode is a LINUX errno number. See §3.7.

Tstatfs      tag[2] fid[4]
Rstatfs      tag[2] type[4] bsize[4] blocks[8] bfree[8] bavail[8]
                    files[8] ffree[8] fsid[8] namelen[4]
             -- kernel reads "ddqqqqqqd". type is the f_type magic
                (e.g. 0x01021997 V9FS_MAGIC, 0xEF53 EXT4). 52 bytes of body
                after the tag.

Tlopen       tag[2] fid[4] flags[4]
Rlopen       tag[2] qid[13] iounit[4]
             -- flags are LINUX open(2) flags, see §3.3.

Tlcreate     tag[2] fid[4] name[s] flags[4] mode[4] gid[4]
Rlcreate     tag[2] qid[13] iounit[4]
             -- creates a regular file in the directory `fid` and, as in base
                9P, MUTATES `fid` to refer to the new open file.
                mode = permission bits (Linux st_mode perms); gid = owning group.

Tsymlink     tag[2] fid[4] name[s] symtgt[s] gid[4]
Rsymlink     tag[2] qid[13]
             -- `fid` is the parent directory and is NOT mutated.

Tmknod       tag[2] dfid[4] name[s] mode[4] major[4] minor[4] gid[4]
Rmknod       tag[2] qid[13]
             -- mode includes the S_IFMT type bits (S_IFBLK 0o060000,
                S_IFCHR 0o020000, S_IFIFO 0o010000, S_IFSOCK 0o140000)
                or'ed with permissions.

Trename      tag[2] fid[4] dfid[4] name[s]
Rrename      tag[2]
             -- rename the file `fid` into directory `dfid` under `name`.
                Superseded by Trenameat; servers may answer ENOTSUPP.

Treadlink    tag[2] fid[4]
Rreadlink    tag[2] target[s]

Tgetattr     tag[2] fid[4] request_mask[8]
Rgetattr     tag[2] valid[8] qid[13] mode[4] uid[4] gid[4] nlink[8] rdev[8]
                    size[8] blksize[8] blocks[8]
                    atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8]
                    ctime_sec[8] ctime_nsec[8] btime_sec[8] btime_nsec[8]
                    gen[8] data_version[8]
             -- kernel reads "qQdugqqqqqqqqqqqqqqq". Body after tag is
                8 + 13 + 4 + 4 + 4 + 8*15 = 153 bytes. [verified: len 153]
             -- `mode` is a LINUX st_mode (S_IFDIR 0o040000 etc.), NOT DM* bits.
             -- `valid` echoes which fields the server actually filled in; it
                may be a subset of request_mask. Ignore fields whose bit is 0.
             -- btime/gen/data_version are almost never supported; expect them
                to be absent from `valid` and zero.

Tsetattr     tag[2] fid[4] valid[4] mode[4] uid[4] gid[4] size[8]
                    atime_sec[8] atime_nsec[8] mtime_sec[8] mtime_nsec[8]
Rsetattr     tag[2]
             -- kernel writes "d" + "ddugqqqqq". NOTE valid is 4 bytes here
                (it is 8 bytes in getattr). Fields whose bit is clear in
                `valid` are ignored by the server (send 0).

Txattrwalk   tag[2] fid[4] newfid[4] name[s]
Rxattrwalk   tag[2] size[8]
             -- name == "" clones `fid` into `newfid` as a handle over the
                *list* of xattr names (NUL-separated), size = total bytes.
                name != "" gives a handle over that one attribute's value.
                Then use Tread on `newfid`, then Tclunk. No Tlopen needed.

Txattrcreate tag[2] fid[4] name[s] attr_size[8] flags[4]
Rxattrcreate tag[2]
             -- turns `fid` into a write handle for xattr `name`. The client
                must then Twrite exactly attr_size bytes and Tclunk.
                flags: 0 = create-or-replace, 1 = XATTR_CREATE (fail if exists),
                2 = XATTR_REPLACE (fail if absent).

Treaddir     tag[2] fid[4] offset[8] count[4]
Rreaddir     tag[2] count[4] data[count]
             -- `fid` MUST have been Tlopen'd first. [verified: readdir on an
                unopened fid returns Rlerror]
             -- data is a packed sequence of dirents (§3.4).

Tfsync       tag[2] fid[4] datasync[4]
Rfsync       tag[2]
             -- datasync != 0 means fdatasync(2) semantics.

Tlock        tag[2] fid[4] type[1] flags[4] start[8] length[8]
                    proc_id[4] client_id[s]
Rlock        tag[2] status[1]
             -- kernel writes "dbdqqds". POSIX record locks (fcntl F_SETLK).
             -- length == 0 means "to end of file".

Tgetlock     tag[2] fid[4] type[1] start[8] length[8] proc_id[4] client_id[s]
Rgetlock     tag[2] type[1] start[8] length[8] proc_id[4] client_id[s]
             -- kernel writes "dbqqds", reads "bqqds". F_GETLK equivalent.
             -- note: no `flags` field, unlike Tlock.

Tlink        tag[2] dfid[4] fid[4] name[s]
Rlink        tag[2]
             -- hard-link the file `fid` into directory `dfid` as `name`.
                NOTE the argument order: directory FIRST.

Tmkdir       tag[2] dfid[4] name[s] mode[4] gid[4]
Rmkdir       tag[2] qid[13]
             -- `dfid` is not mutated; no fid is produced for the new dir.

Trenameat    tag[2] olddirfid[4] oldname[s] newdirfid[4] newname[s]
Rrenameat    tag[2]
             -- kernel writes "dsds". Servers may answer ENOTSUPP; fall back
                to Trename.

Tunlinkat    tag[2] dirfid[4] name[s] flags[4]
Runlinkat    tag[2]
             -- kernel writes "dsd". flags == 0 to unlink a file,
                flags == AT_REMOVEDIR (0x200) to remove a directory.
                Servers may answer ENOTSUPP; fall back to Tremove
                (walk to the child, then Tremove that fid).
```

Inherited-from-base messages on a `.L` connection keep their base layouts:
`Tversion`, `Tflush`, `Twalk`/`Rwalk`, `Tread`/`Rread`, `Twrite`/`Rwrite`,
`Tclunk`, `Tremove`; `Tattach`/`Tauth` use the `.u` (with `n_uname[4]`) form.

### 3.3 `Tlopen` / `Tlcreate` flags (Linux `open(2)` values, octal)

| Name | Octal | Hex |
|---|---:|---:|
| `O_RDONLY`   | `0o0`       | `0x0` |
| `O_WRONLY`   | `0o1`       | `0x1` |
| `O_RDWR`     | `0o2`       | `0x2` |
| `O_NOACCESS` | `0o3`       | `0x3` |
| `O_CREAT`    | `0o100`     | `0x40` |
| `O_EXCL`     | `0o200`     | `0x80` |
| `O_NOCTTY`   | `0o400`     | `0x100` |
| `O_TRUNC`    | `0o1000`    | `0x200` |
| `O_APPEND`   | `0o2000`    | `0x400` |
| `O_NONBLOCK` | `0o4000`    | `0x800` |
| `O_DSYNC`    | `0o10000`   | `0x1000` |
| `FASYNC`     | `0o20000`   | `0x2000` |
| `O_DIRECT`   | `0o40000`   | `0x4000` |
| `O_LARGEFILE`| `0o100000`  | `0x8000` |
| `O_DIRECTORY`| `0o200000`  | `0x10000` |
| `O_NOFOLLOW` | `0o400000`  | `0x20000` |
| `O_NOATIME`  | `0o1000000` | `0x40000` |
| `O_CLOEXEC`  | `0o2000000` | `0x80000` |
| `O_SYNC`     | `0o4000000` | `0x100000` |

**These are the x86/Linux ABI values, not Darwin's.** Darwin's `O_CREAT` is
`0x200`, `O_TRUNC` is `0x400`, `O_EXCL` is `0x800`, `O_APPEND` is `0x8`, etc.
A Swift client **must** translate `Darwin.O_*` → the table above before putting
them on the wire. Define your own `P9OpenFlags: OptionSet` with the Linux
values; never pass `Darwin.O_RDWR | Darwin.O_CREAT` through.

Practical note: servers commonly whitelist flags. `rs9p`'s `unpfs`, for example,
masks incoming flags down to `O_WRONLY|O_RDONLY|O_RDWR|O_CREAT|O_TRUNC` because
the Linux client leaks `O_DIRECT`. Send only what you need.

### 3.4 `Rreaddir` dirent wire format

```
dirent = qid[13] offset[8] type[1] name[s]
```

Kernel: `p9pdu_readf(..., "Qqbs", &qid, &d_off, &d_type, &name)`.

* `offset` is the **cursor to pass to the next `Treaddir`** to continue after
  this entry. It is opaque — never compute it yourself. Pass `0` to start.
  End of directory is signalled by `Rreaddir.count == 0`.
* Entries are packed with no padding; `data` may end exactly on an entry
  boundary (a server never returns a partial dirent).
* `type` is nominally a Linux `DT_*` value:
  `DT_UNKNOWN 0`, `DT_FIFO 1`, `DT_CHR 2`, `DT_DIR 4`, `DT_BLK 6`, `DT_REG 8`,
  `DT_LNK 10`, `DT_SOCK 12`, `DT_WHT 14`.
  **But `hugelgupf/p9` writes the qid type byte instead** [verified: `128`
  (= `QTDIR`) for a directory, `0` for a regular file]. Derive the type from
  `qid.type & QTDIR` / `QTSYMLINK`, and only use the dirent `type` byte as a
  hint when it holds a plausible `DT_*` value.
* `"."` and `".."` are normally included by POSIX-backed servers. Filter them
  client-side.
* Size a `Treaddir` request as `count = msize - 24` (`P9_READDIRHDRSZ`).

### 3.5 `P9_GETATTR_*` request/valid mask bits (`request_mask[8]`, `valid[8]`)

| Name | Value |
|---|---:|
| `P9_GETATTR_MODE`         | `0x0000000000000001` |
| `P9_GETATTR_NLINK`        | `0x0000000000000002` |
| `P9_GETATTR_UID`          | `0x0000000000000004` |
| `P9_GETATTR_GID`          | `0x0000000000000008` |
| `P9_GETATTR_RDEV`         | `0x0000000000000010` |
| `P9_GETATTR_ATIME`        | `0x0000000000000020` |
| `P9_GETATTR_MTIME`        | `0x0000000000000040` |
| `P9_GETATTR_CTIME`        | `0x0000000000000080` |
| `P9_GETATTR_INO`          | `0x0000000000000100` |
| `P9_GETATTR_SIZE`         | `0x0000000000000200` |
| `P9_GETATTR_BLOCKS`       | `0x0000000000000400` |
| `P9_GETATTR_BTIME`        | `0x0000000000000800` |
| `P9_GETATTR_GEN`          | `0x0000000000001000` |
| `P9_GETATTR_DATA_VERSION` | `0x0000000000002000` |
| `P9_GETATTR_BASIC`        | `0x00000000000007ff` (mode…blocks — everything a `stat(2)` needs) |
| `P9_GETATTR_ALL`          | `0x0000000000003fff` |

(In the kernel header these are spelled `P9_STATS_MODE`, `P9_STATS_NLINK`, … ,
`P9_STATS_BASIC`, `P9_STATS_ALL` — same values.)

Use `P9_GETATTR_BASIC` for a normal `stat`. Requesting `ALL` is harmless
[verified: `p9ufs` answered `valid = 0x3fff` for a `request_mask = 0x3fff`].
Always check `valid` before trusting a field.

Note `P9_GETATTR_INO` covers `qid.path`, which is always present anyway.

### 3.6 `P9_SETATTR_*` mask bits (`valid[4]`)

| Name | Value |
|---|---:|
| `P9_SETATTR_MODE`      | `0x00000001` |
| `P9_SETATTR_UID`       | `0x00000002` |
| `P9_SETATTR_GID`       | `0x00000004` |
| `P9_SETATTR_SIZE`      | `0x00000008` |
| `P9_SETATTR_ATIME`     | `0x00000010` |
| `P9_SETATTR_MTIME`     | `0x00000020` |
| `P9_SETATTR_CTIME`     | `0x00000040` |
| `P9_SETATTR_ATIME_SET` | `0x00000080` |
| `P9_SETATTR_MTIME_SET` | `0x00000100` |

Semantics mirror `utimensat`:

* `ATIME` alone = set atime to **now** (server clock).
* `ATIME | ATIME_SET` = set atime to the supplied `atime_sec`/`atime_nsec`.
* Same pattern for mtime.
* `CTIME` alone asks the server to update ctime (there is no `ctime_sec` field
  to set it to a specific value).
* `SIZE` = truncate/extend to `size`.
* Fields whose bit is clear must still be present on the wire — send zeros.
* `valid == 0` is a legal no-op [verified against `p9ufs`: `Rsetattr` returned].

### 3.7 Errors: `Rlerror ecode[4]` is a **Linux** errno

There is no string. `ecode` is a positive Linux errno number. Because the
numbering diverges from Darwin above 34, a mapping table is mandatory. The
divergent ones you will actually hit:

| Name | Linux | Darwin |
|---|---:|---:|
| `EAGAIN` / `EWOULDBLOCK` | 11 | 35 |
| `EDEADLK`     | 35 | 11 |
| `ENAMETOOLONG`| 36 | 63 |
| `ENOLCK`      | 37 | 77 |
| `ENOSYS` / `ENOTSUPP` | 38 | 78 |
| `ENOTEMPTY`   | 39 | 66 |
| `ELOOP`       | 40 | 62 |
| `ENOMSG`      | 42 | 91 |
| `EOVERFLOW`   | 75 | 84 |
| `ENOTSOCK`    | 88 | 38 |
| `EOPNOTSUPP`  | 95 | 102 |
| `ECONNRESET`  | 104 | 54 |
| `ETIMEDOUT`   | 110 | 60 |
| `ESTALE`      | 116 | 70 |
| `EDQUOT`      | 122 | 69 |

Values **1–34 are identical** on Linux and Darwin (`EPERM 1`, `ENOENT 2`,
`EIO 5`, `EBADF 9`, `EACCES 13`, `EEXIST 17`, `EXDEV 18`, `ENODEV 19`,
`ENOTDIR 20`, `EISDIR 21`, `EINVAL 22`, `EMFILE 24`, `EFBIG 27`, `ENOSPC 28`,
`ESPIPE 29`, `EROFS 30`, `EMLINK 31`, `EPIPE 32`, `ERANGE 34`), so a table
covering 35–133 plus pass-through below 35 is sufficient.

Servers answer `ENOSYS` (38) for messages they do not implement — treat that as
"feature absent", not "connection broken". [verified: `p9ufs` → `Tstatfs` = 38.]

### 3.8 Locking constants

`Tlock type[1]` / `Tgetlock type[1]` / `Rgetlock type[1]`:

| Name | Value |
|---|---:|
| `P9_LOCK_TYPE_RDLCK` | 0 |
| `P9_LOCK_TYPE_WRLCK` | 1 |
| `P9_LOCK_TYPE_UNLCK` | 2 |

`Tlock flags[4]`:

| Name | Value | Meaning |
|---|---:|---|
| `P9_LOCK_FLAGS_BLOCK`   | 1 | blocking request |
| `P9_LOCK_FLAGS_RECLAIM` | 2 | reclaim a lock after a server restart |

`Rlock status[1]`:

| Name | Value | Meaning |
|---|---:|---|
| `P9_LOCK_SUCCESS` | 0 | granted |
| `P9_LOCK_BLOCKED` | 1 | would block — client should retry (the kernel retries with a delay) |
| `P9_LOCK_ERROR`   | 2 | failed |
| `P9_LOCK_GRACE`   | 3 | server is in its post-restart grace period; retry later |

`client_id[s]` is an opaque per-client string (the Linux client uses the node
name); `proc_id[4]` identifies the locking process within that client. Together
they let the server attribute locks. `Rgetlock` with `type == P9_LOCK_TYPE_UNLCK`
means "no conflicting lock".

`Tunlinkat flags[4]`: only `AT_REMOVEDIR = 0x200` is meaningful.

`Txattrcreate flags[4]`: `0` = replace-or-create, `1` = `XATTR_CREATE`,
`2` = `XATTR_REPLACE`.

