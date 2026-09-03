# The FSKit backend: build, install, enable, mount

This directory builds `FS9Kit.app`, a container application whose only real
content is `FS9KitExtension.appex` — an FSKit filesystem module that mounts a 9P
server as a macOS volume with no kernel extension and no macFUSE.

**Requires macOS 26.0 (Tahoe) or later.** Mounting a filesystem that has no
block device behind it needs `FSGenericURLResource`, which does not exist before
macOS 26, and needs the `mount(8)` code path that builds one, which first ships
in the macOS 26 line. There is no fallback on macOS 15.x — use the NFS loopback
backend there.

**Requires a real code-signing identity.** `fskitd` refuses an unsigned appex,
and an ad-hoc signature (`codesign -s -`) is rejected by AMFI unless the machine
is booted with `amfi_get_out_of_my_way=1`, which means SIP off. A free Apple
Developer team is enough: "FSKit Module" is not an approval-gated capability.

---

## 1. Generate the Xcode project

The project file is not checked in — it is unreviewable and unmergeable. It is
generated from [`project.yml`](project.yml):

```sh
brew install xcodegen
cd macos
xcodegen generate          # writes FS9Kit.xcodeproj
```

Both targets consume the SwiftPM package at the repository root, so there is
exactly one copy of the 9P client, the VFS and the FSKit glue.

## 2. Build and sign

```sh
export FS9KIT_DEVELOPMENT_TEAM=ABCDE12345      # your Team ID
cd macos
xcodegen generate
xcodebuild -project FS9Kit.xcodeproj \
           -scheme FS9Kit \
           -configuration Release \
           -derivedDataPath build \
           -allowProvisioningUpdates \
           DEVELOPMENT_TEAM="$FS9KIT_DEVELOPMENT_TEAM" \
           build
```

`-allowProvisioningUpdates` matters: the `com.apple.developer.fskit.fsmodule`
entitlement has to be vended in a provisioning profile, and Xcode will create
one for you only if you ask.

The product is `macos/build/Build/Products/Release/FS9Kit.app`, with the
extension inside it at `Contents/Extensions/FS9KitExtension.appex`.

Check the signature and the entitlement before going further:

```sh
APP=macos/build/Build/Products/Release/FS9Kit.app
APPEX=$APP/Contents/Extensions/FS9KitExtension.appex

codesign -dv --entitlements - "$APPEX" 2>&1 | grep -A1 fskit
# expect: com.apple.developer.fskit.fsmodule = true

codesign -dv --entitlements - "$APP" 2>&1 | grep app-sandbox
# expect: NOTHING. The container app must not be sandboxed — App Sandbox
# forbids calling /sbin/mount.

plutil -extract EXAppExtensionAttributes.FSShortName raw "$APPEX/Contents/Info.plist"
# expect: fs9kit
```

## 3. Install

The app must live somewhere LaunchServices scans. In practice that means
`/Applications`; no other location is reported to work reliably.

```sh
sudo rm -rf /Applications/FS9Kit.app
sudo cp -R macos/build/Build/Products/Release/FS9Kit.app /Applications/
open /Applications/FS9Kit.app
```

**After every reinstall, re-register.** `fskitd` caches the previous bundle's
UUID and will keep loading a bundle that no longer exists:

```sh
sudo pkill fskitd; sleep 3
sudo pluginkit -a /Applications/FS9Kit.app/Contents/Extensions/FS9KitExtension.appex
```

## 4. Enable the extension

This is a per-user switch and there is no system-wide, MDM or pre-login
equivalent. Apple's DTS has said so explicitly.

**In the UI:** System Settings → General → *Login Items & Extensions* → scroll
to *Extensions* → **File System Extensions** → ⓘ → switch **fs9kit** on.

**From the command line** (unofficial, but it is what every project in this
space uses):

```sh
sudo pluginkit -e use -i com.fs9kit.FS9KitApp.FS9KitExtension
pluginkit -m -A -i com.fs9kit.FS9KitApp.FS9KitExtension
# a leading '+' means enabled, '-' means registered but off,
# no output at all means not registered
```

`FS9Kit.app` shows the same status and has a button that opens the right
Settings pane.

## 5. Mount

```sh
mkdir -p /Volumes/fs9kit
sudo /sbin/mount -F -t fs9kit p9://127.0.0.1:564/ /Volumes/fs9kit

ls /Volumes/fs9kit
mount | grep fs9kit
```

The "device" argument is a whole URL, not a path. Its form:

```
p9://[user@]host[:port]/[aname][?option&option=value]
p9://…            same thing; see the note below
9p+unix:///path/to/socket?aname=tree
```

| Part | Meaning |
|---|---|
| `user@` | the 9P `uname`; defaults to the user running the extension |
| `:port` | defaults to 564, 9P's registered port |
| `/aname` | which tree to attach to; usually empty |
| `?uname=` | the 9P `uname`, overriding `user@` |
| `?msize=` | message size — `65536`, `64k`, `1M`; between 4 KiB and 16 MiB |
| `?version=` | pin the dialect: `9P2000.L` / `9P2000.u` / `9P2000` (or `L` / `u`) |
| `?ro` | read-only. `-o ro` does the same and wins if either says so |
| `?uid=` `?gid=` | report every file as owned by this uid/gid |
| `?volname=` | the name Finder shows |
| `?debug` | verbose logging |

Anything else in the query is an error, so a typo fails the mount instead of
being silently ignored.

> **Use `p9://`, not `9p://`.**
> `mount(8)` turns the argument into a resource with
> `[NSURL URLWithString:argv[0]]` before the extension is reached, and a URL
> scheme may not begin with a digit under RFC 3986. How strictly that is
> enforced differs between Foundation implementations — swift-corelibs-foundation
> returns `nil` for `9p://host/` — so `p9://` is the spelling that is safe
> everywhere. Both are registered in `FSSupportedSchemes` and the extension
> treats them identically; `Tests/FS9KitAdapterTests` records which way each
> platform goes. See `docs/design/fskit-backend.md`.

> **`9p+unix://` needs an extra entitlement.** A sandboxed extension cannot
> reach an arbitrary unix socket on disk. Put the socket in an app-group
> container and add `com.apple.security.application-groups` to
> `FS9KitExtension.entitlements`.

Read-only, on a non-default port, attaching to a named tree, as another user:

```sh
sudo /sbin/mount -F -t fs9kit -o ro \
     "p9://alice@files.example.com:5640/exports?msize=1M&version=9P2000.L" \
     /Volumes/exports
```

## 6. Unmount

```sh
sudo diskutil unmount /Volumes/fs9kit
sudo diskutil unmount force /Volumes/fs9kit      # when something is holding it
umount /Volumes/fs9kit                           # also works
```

## 7. When it goes wrong

Watch the module and the daemons together:

```sh
log stream --info --debug --predicate \
  'subsystem == "com.fs9kit" OR process == "fskitd" OR process == "fskit_agent" OR process CONTAINS "FS9KitExtension"'
```

After the fact:

```sh
log show --last 10m --style compact --predicate \
  'subsystem == "com.fs9kit" OR process == "fskitd"' | tail -100
```

| What you see | What it means |
|---|---|
| `File system named fs9kit not found` | Not registered, or `FSShortName` does not say `fs9kit`. Re-run the `pluginkit -a` step. |
| `Module … is disabled!` | The System Settings switch is off. Step 4. |
| `supports neither Block Device nor PathURL resources nor ServerURL resources` | `FSSupportsGenericURLResources` is not `true` — or you are on macOS 15.x, where `mount(8)` has no GenericURL branch at all. |
| `does not support operation mount` | `FSActivateOptionSyntax` is missing from the extension's `Info.plist`. |
| `EAGAIN` from `loadResource`, or "unexpected container state" | The container identifier changed between probe and load, or `containerStatus` was not `.ready`. Both are handled in `FS9UnaryFileSystem`; if you see it, the identifier is no longer a pure function of the URL. |
| `Resource busy`, "resource state is 5" | A previous mount of the same URL failed during `activate` and wedged it (FB24419932). `sudo pkill fskitd` clears it. One wrong hostname is enough to trigger this. |
| `com.apple.extensionKit.errorDomain error 2` | Stale LaunchServices registration after a rebuild. `sudo pkill fskitd`, re-run `pluginkit -a`; if it persists, `lsregister -R -f -u ~/Library/Developer/Xcode/DerivedData`. |
| Mounts, but Finder shows nothing | `getAttributes` left an attribute unset — `modifyTime` above all. |
| `Unable to invoke task` under plain `sudo mount -F` | Known: root's `mount -F` does not always find a per-user-enabled module. Check the module is enabled for *your* user, not for root. |

The nuclear reset, after a bad build:

```sh
sudo diskutil unmount force /Volumes/fs9kit 2>/dev/null
sudo pkill fskitd; sudo pkill -f FS9KitExtension
sudo rm -rf /Applications/FS9Kit.app
# reinstall, then re-register and re-enable
```

## 8. What this backend cannot do

These are FSKit's limits, not the 9P client's. They are documented at length in
[`../docs/design/fskit-backend.md`](../docs/design/fskit-backend.md).

- **A name that once returned `ENOENT` keeps returning it** for the lifetime of
  the kernel's vnode (FB24419825). A file created on the server after you looked
  for it will be listed by `ls` and still fail to open. Remounting clears it.
- **`fsync(2)` does nothing.** `synchronize` is never called on a URL-backed
  volume (FB24419870); the call returns success without reaching the module.
- **No `flock(2)` or `fcntl(2)` locks** reach the module (FB24419974), so they
  cannot coordinate between clients.
- **No ACLs**, so `ls -le`, `chmod +a` and `cp -p` with ACLs do not work.
- **`renameatx_np(RENAME_SWAP)` is not distinguishable from a clobbering
  rename** (FB24419773).
- **Per-user only.** A 9P home directory cannot be mounted before login.
- **Read/write performance is FSKit's slow path.** Apple: the
  `ReadWriteOperations` route "has not been heavily optimized".
- **Updating or deleting the app unmounts every volume** without notice.
