# CI feasibility for an FSKit 9P client on GitHub Actions

Research date: **2026-08-21**. Every claim below is either linked to a primary source or
explicitly marked **UNCONFIRMED**.

---

## Bottom line

**You cannot mount an FSKit filesystem on a GitHub-hosted macOS runner. Not today, not with
any trick.** The blocker is not SIP, not signing, and not the macOS version — it is that a
third-party FSKit module must be *enabled* by an interactive click in
**System Settings → General → Login Items & Extensions → File System Extensions**, that this
state is **per-user and stored in the user's home**, that Apple DTS has said on the record
there is **no CLI, MDM, or programmatic path** to set it, and that GitHub runners are
**ephemeral** (a fresh VM per job erases any one-time setup even if you could do it).
On top of that, `pluginkit -a` only *registers* an appex; it does **not** enable it, and
FSKit keeps its own enabled-modules list separate from PlugInKit elections.

So split the work into three tiers:

### Tier 1 — GitHub-hosted runners (every push, free, fully automatable)

Run on `macos-15` (macOS 15.7.7) and/or `macos-26` (macOS 26.5.2, arm64) plus
`ubuntu-latest`:

1. **`swift build` / `swift test`** of the pure-Swift 9P codec + client
   (`Sources/NineP`, `Tests/NinePTests`). Linux + macOS, both arches. This is the bulk of
   the value and it is 100% reliable.
2. **Loopback 9P integration tests**: spin up a 9P server on `127.0.0.1` (either your own
   Swift test server, or `diod`/`u9fs`/a Go `go9p` server built in the job) and drive the
   real client over TCP. No mount, no privileges, no TCC. Works identically on Linux and
   macOS. **This is where you get real protocol coverage.**
3. **FSKit framework/binding probe**: `dlopen` / link `FSKit.framework` in a plain signed
   process and assert the classes, protocols and selectors you depend on exist
   (`FSUnaryFileSystem`, `FSUnaryFileSystemOperations`, `FSVolume.Operations`, …). Proven
   to work on `macos-15` by [greatliontech/fskit-go](https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md)
   ("Tier-1 result — PASS (2026-06-20, macos-15 = 15.7)"). Catches SDK/ABI drift.
4. **Build the app + appex with `xcodebuild`**, ad-hoc signed, and assert bundle structure:
   `EXExtensionPointIdentifier = com.apple.fskit.fsmodule`, `FSShortName`,
   `FSSupportsPathURLs`, `com.apple.security.app-sandbox = true`. Fails fast on Info.plist /
   entitlement regressions. (No Apple account needed for the ad-hoc leg.)
5. **Optional, if you have signing secrets**: import a `.p12` + provisioning profile carrying
   `com.apple.developer.fskit.fsmodule`, do a real signed (and optionally notarized) build,
   and verify with `codesign -d --entitlements`. Proven pattern:
   [oakdotspace/oak `_build-macos-app.yml`](https://github.com/oakdotspace/oak/blob/main/.github/workflows/_build-macos-app.yml).
6. **`pluginkit -a <appex>` + `pluginkit -m -v -p com.apple.fskit.fsmodule`** as a
   *registration-only* smoke check. It will show the module as discovered. It will **not**
   be enabled and `mount -F` will still fail with `Module <id> is disabled!`. Keep this step
   `continue-on-error: true` / assertion-free, or it becomes a flaky liar.
7. **Loopback NFSv3 mount as a real-filesystem substitute** (see §5.3). `sudo nfsd` +
   `sudo mount_nfs -o vers=3 localhost:...` is **proven working on `macos-15` GitHub runners**
   ([zotero/zotero CI](https://github.com/zotero/zotero/blob/master/.github/workflows/ci.yml)),
   and a userspace NFS server + `mount_nfs` loopback is proven on `macos-latest`
   ([nexi-lab/nexus](https://github.com/nexi-lab/nexus/blob/main/.github/workflows/fuse-plugin-macos-nfs-e2e.yml)).
   If you build an NFS-loopback fallback backend (the FUSE-T technique), **that backend is
   fully CI-testable end-to-end, including a real POSIX mount**. This is the single best
   lever you have for getting real mount coverage on hosted CI.

### Tier 2 — one persistent self-hosted Mac (the only way to test a real FSKit mount)

A **bare-metal or persistent Apple Silicon Mac**, auto-login GUI user, the extension enabled
**once by hand**, and the Actions runner installed as a **LaunchAgent under that same user**
(not a LaunchDaemon — the enabled state is session-scoped). Then a `runs-on: [self-hosted,
macOS, fskit]` job can do the real
`/sbin/mount -F -t <fsname> -o nobrowse <resource> <mountpoint>` → `ls` → `cat` → `umount`.
This is exactly what [astrid-runtime/astrid](https://github.com/astrid-runtime/astrid/blob/main/.github/workflows/native-storage-certification.yml)
does (`runs-on: [self-hosted, macOS, fskit]`, with a guard that errors out unless it is
"the pre-approved GUI user session").
Caveat from [indragiek/GHFS](https://github.com/indragiek/GHFS/blob/main/FSKIT.md): **re-signing
the appex changes its UUID and silently drops the enablement**, so a rebuild-per-job runner
needs a stable signing identity, or a human re-toggle, or you keep the enabled bundle fixed
and swap only the daemon behind it.

Cheapest credible options: **your own Mac ($0)**, a **Scaleway M1 24-h lease (~€2.64)** to
prove it once, then a dedicated mini at **~$85–150/mo** (MacMiniVault / MacStadium /
Scaleway) for ongoing CI.

### Tier 3 — manual, documented, human-in-the-loop

- Clicking the File System Extensions toggle after a fresh install.
- Anything involving Finder/Spotlight/Time Machine interaction with the volume.
- First-run TCC prompts (mounting into `~/Documents`, `~/Desktop`, `~/Downloads` requires
  Full Disk Access for the invoking process — see the `oak` source comment quoted in §4).

### What to explicitly **not** do

- Don't try macFUSE on hosted CI (kext approval is GUI-only; on Apple Silicon it also needs
  Reduced Security + reboot). See §5.4.
- Don't try nested virtualization / Lima / Colima / a Linux VM on `macos-*` arm64 runners —
  GitHub documents it as unsupported. See §5.5.
- Don't ship a workflow that writes `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`
  directly. It is documented as **not honored by `fskitd`** (§3) and DTS discourages it.

### Sample workflow

See [§7](#7-sample-github-actions-workflow) for a copy-pasteable skeleton.

---

## 1. GitHub-hosted macOS runner images (as of August 2026)

| Label | macOS | Arch | Status | Notes |
|---|---|---|---|---|
| `macos-13` | 13.x | x64 | **Retired** (fully unsupported since 2025-12-04) | [changelog](https://github.blog/changelog/2025-09-19-github-actions-macos-13-runner-image-is-closing-down/), [issue #13046](https://github.com/actions/runner-images/issues/13046) |
| `macos-14`, `macos-14-large/xlarge` | 14.x | arm64 (x64 for `-large`) | **Deprecating** — began 2026-07-06, fully unsupported **2026-11-02** | [issue #13518](https://github.com/actions/runner-images/issues/13518) |
| `macos-15` | **15.7.7 (24G720)**, Darwin 24.6.0 | **arm64** (M1) | GA | image `20260727.0256.1` — [readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) |
| `macos-15-intel` | 15.7.7 (24G720) | x64 | GA | [readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) |
| `macos-26` | **26.5.2 (25F84)**, Darwin 25.5.0 | **arm64** | **GA since 2026-02-26** | image `20260728.0273.1` — [readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), [changelog](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/) |
| `macos-26-intel` | 26.6 (25G72), Darwin 25.6.0 | x64 | GA | [readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md) |
| `macos-26-large` / `macos-26-xlarge` | 26.x | x64 / arm64 | GA (larger runners, paid) | |
| `macos-latest` | **→ macOS 26** | arm64 | migrated starting **2026-06-15** | [changelog](https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/), [issue #14167](https://github.com/actions/runner-images/issues/14167) |
| `xcode-27` | 26.x | arm64 | public preview | [docs](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) |

**Toolchains**

- `macos-26` (arm64): Xcode **26.6** (17F113) default; also 26.5, 26.4.1, 26.3, 26.2, 26.1.1,
  26.0.1. Xcode Command Line Tools 26.6.0.0.1781586589. SDKs: macOS 26.0–26.6, plus iOS /
  tvOS / watchOS / visionOS / DriverKit.
- `macos-15` (arm64): Xcode **16.4** (16F6) default; 16.0–16.3 plus 26.0.1–26.3 preview
  installed. Select the newest with
  `sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"`.
- **Swift version is not listed explicitly in the readmes** — it is whatever ships in the
  selected Xcode (Xcode 16.4 → Swift 6.1.x; Xcode 26.6 → Swift 6.x). Exact minor:
  **UNCONFIRMED**; read it at job time with `swift --version`. `SwiftFormat 0.62.1` is
  preinstalled on `macos-26`.

**Which label gives you FSKit?**
FSKit shipped in **macOS 15.4** (Sequoia) and got major additions in **macOS 26.0**
([KhaosT/FSKitSample](https://github.com/KhaosT/FSKitSample), [indragiek/GHFS FSKIT.md](https://github.com/indragiek/GHFS/blob/main/FSKIT.md)).
Therefore **all currently supported labels** (`macos-15`, `macos-15-intel`, `macos-26`,
`macos-26-intel`, `macos-latest`) have the FSKit framework available for *building and
linking*. `macos-26` gives you the macOS 26 SDK you need if you target the newer FSKit API
(e.g. `FSVolume.DataCacheHandler`).

Note the community advice to pin runtime work at **macOS 15.6+**, not 15.4 — 15.4/15.5 were
buggy enough that both macFUSE and ExtendFS set their floor at 15.6
([fskit-go CI doc](https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md),
[macFUSE FUSE Backends wiki](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)).

---

## 2. Security posture of GitHub-hosted macOS runners

**Sudo:** passwordless `sudo` is available. GitHub documents macOS runners as supporting
passwordless sudo ([GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)),
and it is used in practice (`sudo nfsd`, `sudo mount_nfs`, `sudo unzip -d /usr/local`,
`sudo xcode-select`). The runner user is `runner` and is an admin.

**SIP:** `macos-13` shipped with **SIP disabled** — confirmed by `csrutil status` output in
[actions/runner-images#8162](https://github.com/actions/runner-images/issues/8162)
(macOS 11 and 12 had it *enabled*; 13 had it *disabled*). **For `macos-15` and `macos-26` the
status is UNCONFIRMED** — I found no issue or public log stating it. Two indirect signals
that it is *likely* disabled or "unknown (Custom Configuration)":
- the image build script
  [`images/macos/scripts/build/configure-tccdb-macos.sh`](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh)
  writes rows directly into `/Library/Application Support/com.apple.TCC/TCC.db`, which
  requires SIP off (at least at image-build time);
- [`configure-machine.sh`](https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-machine.sh)
  contains `if csrutil status | grep -Eq "System Integrity Protection status: (disabled|unknown)"`,
  i.e. the build path expects a non-enabled SIP.

Either way: **SIP is not settable from inside a job** (it needs Recovery + reboot; a reboot
ends the job). Same for `nvram boot-args=amfi_get_out_of_my_way=1`. So the
"SIP-off + AMFI-off + ad-hoc-signed restricted entitlement" route that
[FSM1/cipher-box](https://github.com/FSM1/cipher-box/blob/main/tools/hw-gates/fskit-spike/RESULTS.md)
used in a UTM VM is **not reachable on hosted runners**.

Good news: **you don't need SIP off for FSKit.** A properly provisioned
`com.apple.developer.fskit.fsmodule` entitlement satisfies AMFI with SIP fully on — the
provisioning profile *is* the authorization. `amfi_get_out_of_my_way` is only for
unsigned/unauthorized code
([fskit-go CI doc](https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md);
[Apple forums 787500](https://developer.apple.com/forums/thread/787500)).
[mohsen1/git-lazy-mount](https://github.com/mohsen1/git-lazy-mount/blob/main/docs/future-platforms/macos-fskit-ondevice.md)
states it flatly: *"SIP is not the issue. FSKit is a user-space app-extension model and is
designed to run with SIP enabled; no SIP change is ever required."*

**Unsigned / ad-hoc-signed code with restricted entitlements:** will **not** load.
`com.apple.developer.fskit.fsmodule` is a *restricted* entitlement — it must come from a real
provisioning profile minted by a paid Apple Developer team that has been granted the
"File System Module" **managed capability** via Apple's
[Capability Requests](https://developer.apple.com/help/account/capabilities/capability-requests)
flow. `oak`'s workflow says it explicitly: *"The OakFS extension needs the restricted
`com.apple.developer.fskit.fsmodule` entitlement, which must come from real provisioning
profiles — CLI/automatic signing strips it."*

**GUI session:** **yes, there is one.** The runner images are built with
[`configure-autologin.sh`](https://github.com/actions/runner-images/tree/main/images/macos/scripts/build)
and [`setAutoLogin.sh`](https://github.com/actions/runner-images/blob/main/images/macos/assets/bootstrap-provisioner/setAutoLogin.sh)
(referenced from every `macOS-{14,15,26}[.arm64].anka.pkr.hcl` template), so the `runner`
user is auto-logged into an Aqua session. Corroborating evidence: workflows that do
`open MyApp.app`, `pluginkit -m -i <id>`, `qlmanage -p`, and `screencapture -x` and pass
(e.g. [u1aryz/macos-webm-quicklook](https://github.com/u1aryz/macos-webm-quicklook/blob/main/.github/workflows/ci.yml),
[moritalous/cost-widget-mac](https://github.com/moritalous/cost-widget-mac/blob/main/.github/workflows/macos.yml)),
and runner-images bug reports about SetupAssistant windows and screen-recording prompts
appearing ([#14161](https://github.com/actions/runner-images/issues/14161),
[#14166](https://github.com/actions/runner-images/issues/14166)).

**TCC:** the image pre-grants `kTCCServiceAccessibility`, `kTCCServiceAppleEvents` (to
`com.apple.systemevents`, `com.apple.finder`, `com.apple.Safari`),
`kTCCServiceScreenCapture`, `kTCCServiceSystemPolicyAllFiles` (Full Disk Access) and
`kTCCServiceSystemPolicyNetworkVolumes` to `/bin/bash` and `/usr/bin/osascript`. So
AppleScript UI-scripting of System Settings is **not blocked by TCC** on these images. That
is the only theoretical crack in the enablement wall (see §3), and it is **UNCONFIRMED** —
nobody has demonstrated it, and it would still be defeated by runner ephemerality.

**Gatekeeper / `spctl`:** `spctl --status` is commonly printed in CI preflights; I found no
report of it being disabled on 15/26. Assume **enabled**. It is not a blocker for locally
built, locally run code.

---

## 3. Can app extensions be registered and enabled headlessly?

Two separate things, and the distinction is the whole story.

### Registration — YES

`pluginkit -a <path/to/.appex>` "explicitly adds plugins at the file location(s) given, even
if they are not normally eligible for automatic discovery"
([pluginkit(8)](https://keith.github.io/xcode-man-pages/pluginkit.8.html)). Simply
`open`ing the containing app also triggers discovery. Both work headlessly on GitHub
runners; multiple public workflows do exactly this and assert on
`pluginkit -m -A -D -i <bundle-id>` output:

- Widget: [moritalous/cost-widget-mac](https://github.com/moritalous/cost-widget-mac/blob/main/.github/workflows/macos.yml)
  (`lsregister -f …`, `pluginkit -a …`, `pluginkit -m -A -D -i …`)
- QuickLook: [u1aryz/macos-webm-quicklook](https://github.com/u1aryz/macos-webm-quicklook/blob/main/.github/workflows/ci.yml),
  [zoharbabin/fen](https://github.com/zoharbabin/fen/blob/main/.github/workflows/release.yml)
- Mail plugin: [rnpgp/rnp-mailapp-extension](https://github.com/rnpgp/rnp-mailapp-extension/blob/main/.github/workflows/release.yml)
- FileProvider: [Jesssullivan/tummycrypt](https://github.com/Jesssullivan/tummycrypt/blob/main/.github/workflows/macos-postinstall-smoke.yml)
- FSKit appex: [agucova/oxcrypt](https://github.com/agucova/oxcrypt/blob/main/.github/workflows/rust.yml)
  (`pluginkit -a "$APPEX_PATH" || echo "pluginkit -a returned non-zero (expected without signing)"`)
- [mohsen1/git-lazy-mount](https://github.com/mohsen1/git-lazy-mount/blob/main/docs/future-platforms/macos-fskit-ondevice.md)
  reports `pluginkit` registration of `com.apple.fskit.fsmodule` as ✅ for both Apple's own
  sample and their own extension.

Note `pluginkit` requires `com.apple.security.app-sandbox = true` in the appex entitlements
or `pkd` refuses to register it (noted in
[ReyemTech/stint](https://github.com/ReyemTech/stint/blob/main/.github/workflows/release-artifacts.yml)
and [eylonshm/claude-meter](https://github.com/eylonshm/claude-meter/blob/main/.github/workflows/pr.yml)).
FSKit extensions are mandatorily sandboxed anyway.

### Enablement — NO

This is the wall.

1. **Apple DTS, on the record.** Asked whether an FSKit module can be enabled globally /
   for all users / pre-login, the answer was **"No"** — *"app extensions are fundamentally
   scoped to a given user."* The state lives in
   `/Users/<user>/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist`,
   and DTS explicitly discourages writing it: *"these are very much implementation details
   and thus not something I can encourage folks to rely on … it wouldn't surprise me if the
   files that back these settings were protected by MAC, or become so protected in the
   future."*
   → [Apple Developer Forums thread 808594 — "Enable FSKit module globally pre-login"](https://developer.apple.com/forums/thread/808594)

2. **Writing the plist does not work anyway.** From a hands-on spike on macOS 27 beta:
   *"Enablement is privileged. A third-party module must be enabled before `fskitd` will
   route to it. `FSClient.setEnabledStateForIdentifier` needs
   `com.apple.private.LiveFS.connection` (returns `EPERM` without it); hand-editing
   `~/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist` is **not**
   honored by `fskitd`."*
   → [FSM1/cipher-box `tools/hw-gates/fskit-spike/RESULTS.md`](https://github.com/FSM1/cipher-box/blob/main/tools/hw-gates/fskit-spike/RESULTS.md)
   (that spike only got `enable` working at all because it ran with **SIP disabled +
   `boot-args=amfi_get_out_of_my_way=1`** in a UTM VM, letting an ad-hoc binary claim the
   private entitlement — not reproducible on a hosted runner.)

3. **PlugInKit election ≠ FSKit enablement.** `pluginkit -e use -i <id>` sets a *user
   election*, but FSKit maintains its **own** enabled-modules list:
   *"`pluginkit -mA` may still show a `+` prefix, but that is not the same state as FSKit's
   own enabled-modules list."*
   → [indragiek/GHFS `FSKIT.md`](https://github.com/indragiek/GHFS/blob/main/FSKIT.md)
   The [fskit-go CI doc](https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md)
   further reports that `-e use` elections are *"non-durable … will be reverted in subsequent
   discovery"* and that *"controlling appexes is currently only available in System Settings"*
   — **UNCONFIRMED**: I could not find that wording in the current
   [pluginkit(8)](https://keith.github.io/xcode-man-pages/pluginkit.8.html), which only
   documents `-e` as applying `use`/`ignore`/`default` elections.

4. **No MDM payload.** `com.apple.system-extension-policy` covers DriverExtension /
   NetworkExtension / EndpointSecurityExtension only — a *different* subsystem (System
   Extensions, not App Extensions). There is no FSKit-appex pre-approval payload.
   (Reported by the fskit-go doc; I did not find an Apple page contradicting it.
   **UNCONFIRMED** against Apple's device-management schema.)

5. **Re-signing silently un-enables it.** *"macOS tracks enabled FSKit modules by extension
   UUID. Every time the extension bundle is re-signed (even a no-op rebuild), it gets a new
   UUID, and the user's previous 'enabled' choice … no longer applies. The extension has to
   be re-enabled through the UI after *every* build before `/sbin/mount` will accept it."*
   → [GHFS `FSKIT.md`](https://github.com/indragiek/GHFS/blob/main/FSKIT.md).
   Symptom: `mount: Unable to invoke task` + `Module <bundle-id> is disabled!`.

6. **Ephemerality.** Even a hypothetical scripted enable would be discarded with the VM at
   end of job.

### Interlude: how other extension types compare

| Extension type | Headless enable on hosted CI? |
|---|---|
| Finder Sync | Registration yes; enabling still `pluginkit -e use` + System Settings (and same election durability question). Public example instructs users to run `pluginkit -e use -i … ; killall Finder` **manually after install** ([kubilaysalih/eylem](https://github.com/kubilaysalih/eylem/blob/main/.github/workflows/release.yml)). |
| QuickLook / Widget | Effectively yes — these are enabled-by-default once discovered; the CI examples above prove it. |
| FSKit | **No** (this document). |
| Network Extension / System Extension | No — needs user approval + often MDM; also a different subsystem. |
| DriverKit / kext | No — GUI approval, and on Apple Silicon also Reduced Security + reboot. |

---

## 4. Has anyone run `mount -F -t <myfs>` on CI?

**No public evidence of a successful `mount -F` on a GitHub-*hosted* runner.**
Searches across GitHub code search (`"mount -F -t" path:.github/workflows`,
`fskit path:.github/workflows`, `"com.apple.fskit.unary" pluginkit`) returned **zero**
workflow files that attempt a hosted-runner FSKit mount and assert success.

What does exist:

- **`astrid-runtime/astrid` — a real FSKit mount certification, on a self-hosted runner.**
  [`.github/workflows/native-storage-certification.yml`](https://github.com/astrid-runtime/astrid/blob/main/.github/workflows/native-storage-certification.yml):
  `runs-on: [self-hosted, macOS, fskit]`, a guard that aborts with
  *"FSKit certification must run in the pre-approved GUI user session"*, signed +
  **notarized** app install to `/Applications/AstridFS.app`, then
  `manage-macos-fskit.sh install / validate / enable`, then a real mount asserted with
  `[[ "$(stat -f %T "$MOUNTPOINT_INITIAL")" == astridfs ]]`.
  Their `enable` verb is instructive — it is *not* automation:
  ```sh
  enable)
    validate_app "$DESTINATION_APP"
    open "$DESTINATION_APP"
    echo "AstridFS launched. Enable AstridFS in System Settings when macOS prompts you."
  ```
  → [`scripts/manage-macos-fskit.sh`](https://github.com/astrid-runtime/astrid/blob/main/scripts/manage-macos-fskit.sh)

- **`mmilitzer/fuse-stream-mvp` — `fskit-debug.yml`** runs FSKit/macFUSE mount tests on
  `runs-on: [self-hosted, macOS, ARM64, macFUSE]` — again, a self-hosted Mac with the kext
  pre-approved.

- **The exact command shape**, from a shipping implementation
  ([oakdotspace/oak `cli/src/commands/mount/fskit/mod.rs`](https://github.com/oakdotspace/oak/blob/main/cli/src/commands/mount/fskit/mod.rs)):
  ```
  /sbin/mount -F -t <FS_SHORT_NAME> -o nobrowse <resource-dir> <mount-point>
  ```
  with three hard-won caveats worth copying into your own design:
  - **Never run it as root.** *"FSKit extensions are registered per-user, so `/sbin/mount`
    as root can't invoke the user's OakFS task ('Unable to invoke task'), and the broker
    LaunchAgent can't bootstrap into root's nonexistent `gui/0` domain."*
  - **`mount(8) silently drops unknown `-o key=value` sub-options`**, so they never reach
    `FSTaskOptions.taskOptions`; pass state through the *resource* path instead.
  - **`Operation not permitted` from `mount(2)`** usually means you tried to mount into a
    TCC-protected folder (`~/Documents`, `~/Desktop`, `~/Downloads`, iCloud Drive) without
    Full Disk Access — not an extension problem.
  - `FSSupportsPathURLs: true` is required for synthetic (non-block-device) resources
    ([oak `macos/OakFS/project.yml`](https://github.com/oakdotspace/oak/blob/main/macos/OakFS/project.yml)).

- **`greatliontech/fskit-go` `.github/workflows/ci.yml`** is the closest thing to a
  hosted-runner FSKit CI job that exists: on `macos-15` it runs a probe binary that loads
  the real FSKit framework and registers a Go-backed `FSUnaryFileSystem` subclass, dumps
  `.swiftinterface` and ObjC headers, and uses `dyld_info -exports` on Apple's own `msdos`
  appex to recover the extension entry mechanism. **No `pluginkit` enable, no `mount -F`** —
  deliberately.

### The macOS 26 third-party FSKit bug (important)

Independent of CI: **third-party FSKit modules have been reported broken on macOS 26.x.**

- [andrewgazelka/loaf#1](https://github.com/andrewgazelka/loaf/issues/1) — on 26.1 (25B78)
  and 26.2 (25C56), `fskitd` rejects the client: `Hello FSClient! entitlement no` →
  `Failed to start instance … extensionKit Code=2 … RBSRequestErrorDomain Code=5`.
  Reproduces **on Apple's own `FSKitSample`**. Developer ID signing, notarization, hardened
  runtime, disabled library validation, embedded dylib, manual plist enablement and an
  `fskitd` restart all failed. Apple DTS (Jul 2025): *"more bugs have been found so you're
  going to need to wait for more fixes."*
- [mohsen1/git-lazy-mount](https://github.com/mohsen1/git-lazy-mount/blob/main/docs/future-platforms/macos-fskit-ondevice.md)
  reproduced the same on **26.4.1**: build ✅, sign ✅, install ✅, `pluginkit` register ✅,
  **enable ❌, `mount -t …` ❌**. *"The System Settings enablement toggle for File System
  Extensions is inert for every third-party FSKit module on macOS 26. Clicking it produces
  zero system response, so `/Library/Filesystems/<name>.fs` is never created and `mount`
  fails with `Module … is disabled!`."*
- Counter-evidence that it *does* work for some people on 26.x: [indragiek/GHFS](https://github.com/indragiek/GHFS)
  requires macOS 26.4+ and documents a working mount workflow (with the
  re-enable-after-every-build caveat and `killall -9 fskit_agent extensionkitservice`
  recovery), and [FSM1/cipher-box](https://github.com/FSM1/cipher-box/blob/main/tools/hw-gates/fskit-spike/RESULTS.md)
  got a full mount + read/write/rename/xattr working on macOS 27 beta.
- **Net:** treat macOS 26 third-party FSKit as *works, but fragile and version-sensitive*.
  Whatever host you pick for Tier 2, **verify a mount by hand before committing to it**, and
  pin the OS minor.

---

## 5. What CAN be reliably tested on a GitHub macOS runner

### 5.1 Build + unit test — YES, unreservedly

`swift build`, `swift test`, `xcodebuild test -destination 'platform=macOS'` all work.
`swift test` on `ubuntu-latest` covers the platform-independent codec. Note this repo's
`Sources/NineP` (Message/Codec/ByteOrder/Types) is pure Swift with no Darwin dependency —
run it on Linux too, it's free coverage and catches accidental Foundation/Darwin creep.

### 5.2 Local 9P server + client over TCP — YES, this is your main integration surface

Nothing privileged is involved: bind a listener on `127.0.0.1`, connect, exercise
version/attach/walk/open/read/write/clunk/stat, fuzz the codec against it.
Loopback is exempt from macOS 15's Local Network privacy gate (which is otherwise a real
CI annoyance — see [actions/runner-images#10924](https://github.com/actions/runner-images/issues/10924)),
so bind to `127.0.0.1` explicitly, never `0.0.0.0`.
Server options: your own Swift test server (best — no extra CI deps), or install
`diod`/`u9fs` via brew/apt, or build a Go `go9p` server in the job.

### 5.3 NFSv3 loopback mount — YES, and this is the big win

Two independent proofs on GitHub-hosted macOS runners:

- **Apple's built-in `nfsd` + `mount_nfs`, on `macos-15`** —
  [zotero/zotero `.github/workflows/ci.yml`](https://github.com/zotero/zotero/blob/master/.github/workflows/ci.yml):
  ```yaml
  test-mac:
    runs-on: macos-15
    steps:
      - name: Set up NFS share
        run: |
          sudo mkdir -p /private/var/zotero-nfs
          sudo chown $(whoami) /private/var/zotero-nfs
          echo "/private/var/zotero-nfs -mapall=$(whoami) localhost" | sudo tee /etc/exports
          sudo nfsd enable || sudo nfsd start
          sleep 2
          showmount -e localhost
          mkdir -p "$HOME/zotero-nfs"
          sudo mount_nfs -o vers=3 localhost:/private/var/zotero-nfs "$HOME/zotero-nfs"
  ```
  So: `mount_nfs` **is present**, `nfsd` **is present**, and `sudo` **is passwordless**.

- **A userspace, in-process NFSv3 server + `mount_nfs`, on `macos-latest`** —
  [nexi-lab/nexus `.github/workflows/fuse-plugin-macos-nfs-e2e.yml`](https://github.com/nexi-lab/nexus/blob/main/.github/workflows/fuse-plugin-macos-nfs-e2e.yml).
  The daemon serves NFSv3 in-process and mounts it at `/tmp/nexus-nfs-e2e`; pytest then runs
  real filesystem workflows against the mount. Teardown is `umount -f <mnt>`.
  This is the **FUSE-T technique**: a userspace NFS server on a loopback TCP port that the
  macOS NFS *client* mounts — no kext, and FUSE-T advertises it as not requiring root
  ([fuse-t wiki](https://github.com/macos-fuse-t/fuse-t/wiki)). Whether a *user* (non-sudo)
  `mount_nfs` succeeds on a GitHub runner is **UNCONFIRMED** — nexus's mount happens inside
  the daemon and zotero uses `sudo`; since sudo is passwordless, just use it.

  Two cautions lifted straight from that workflow's comments:
  - **FUSE-T's own NFS backend is reported broken on macOS 26 (Tahoe)**: *"go-nfsv4 panic,
    SMB EOF, FSKit entitlement missing"*. They install `brew install fuse-t` only for the
    libfuse3 headers/dylib, and rely on their own NFSv3 fallback.
  - **A hard NFS mount that mounts-but-doesn't-serve will hang `ls` forever** and blow your
    job budget. Copy their pattern: bounded probes (`subprocess.run(timeout=…)`; note GNU
    `timeout` is not on macOS by default), a wall-clock readiness deadline, and
    `umount -f` **before** killing the daemon.

**Implication for fs9kit:** if you implement an **NFSv3-loopback backend** alongside the
FSKit backend (same `VFS`/`FileSystem` core, two adapters), you get a *real POSIX mount*
exercised on hosted CI on every push — `open`/`read`/`write`/`readdir`/`rename`/`stat`
through the actual kernel VFS — while the FSKit adapter stays a Tier-2 concern. That is by
far the highest-value architectural decision this research suggests.

### 5.4 macFUSE — NO

`brew install --cask macfuse` installs the package, but the **kext will not load**:
*"Extension with identifiers … not approved to load … Please approve using System
Preferences"* ([actions/virtual-environments#4731](https://github.com/actions/virtual-environments/issues/4731)),
and `kmutil load` cannot approve it from the CLI
([macfuse/macfuse#1039](https://github.com/macfuse/macfuse/issues/1039)). On Apple Silicon
it additionally requires Reduced Security + a reboot into 1TR. `agucova/oxcrypt` installs
the cask and then explicitly `--exclude oxcrypt-fuse` with the comment *"macFUSE requires
kernel extension approval"*. Don't bother.

macFUSE 5.x does have an **FSKit backend** (`-o backend=fskit`,
[macFUSE FUSE Backends wiki](https://github.com/macfuse/macfuse/wiki/FUSE-Backends)) — but
that just moves you back to the FSKit enablement wall.

### 5.5 Virtualization / nested VM / Linux VM on the runner — NO on arm64

GitHub's own docs, for macOS arm64 runners: *"Nested-virtualization is not supported due to
the limitation of Apple's Virtualization Framework"*
([GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
The runner is itself an Anka VM on Apple Silicon, so `Hypervisor.framework` /
`Virtualization.framework` are unavailable inside it — Colima/Lima fail with `HV_UNSUPPORTED`
([abiosoft/colima#970](https://github.com/abiosoft/colima/issues/970),
[#971](https://github.com/abiosoft/colima/issues/971),
[#1427](https://github.com/abiosoft/colima/issues/1427)).

`macos-*-intel` (x64) is the historically-workable option for Docker/Colima on macOS runners
(the [setup-docker-on-macos](https://github.com/douglascamata/setup-docker-macos-action)
action's guidance), but **UNCONFIRMED** for `macos-15-intel`/`macos-26-intel` specifically —
Colima's own CI does use `macos-15-intel`, which is suggestive.

In any case: **testing "a mount inside a Linux VM" tests nothing about FSKit.** If you want
Linux mount coverage of your 9P core, do it natively on `ubuntu-latest` with the kernel's
`9p`/`v9fs` client (`mount -t 9p -o trans=tcp,port=…,version=9p2000.L 127.0.0.1 /mnt`)
inside a privileged step or a container. That is cheap, fast and genuinely useful for
validating your *server-facing* protocol behaviour — just don't confuse it with validating
the macOS adapter.

### 5.6 Other things that work on hosted runners

- `hdiutil attach` / disk-image mounts (used by many workflows).
- SMB loopback (`sudo sharing` / `smbutil`) — **UNCONFIRMED** on 15/26; zotero uses SMB on
  Linux only.
- `screencapture`, `open`, `osascript` + System Events (TCC pre-granted, §2).
- `codesign -d --entitlements -`, `spctl -a -vv`, `xcrun notarytool` (with secrets).

---

## 6. Getting a real interactive macOS with FSKit

| Option | Shape | Persistent? | GUI? | ~Cost | Verdict |
|---|---|---|---|---|---|
| **A Mac you already own** | bare metal | yes | yes | **$0** | **Do this first.** Auto-login user, enable once, install the Actions runner as a **LaunchAgent** under that user. |
| **Scaleway Apple silicon** (dedicated mini, Paris) | bare metal | yes | VNC | **~€0.11/h M1**, 24h min → **~€2.64 for a one-day proof**; ~€139/mo M2 Pro | Cheapest way to *prove* the mount once. Explicit "Sequoia 15" OS picker. |
| **MacMiniVault** | dedicated mini M1/M4 | yes | VNC, root | **~$85/mo (M1), ~$105/mo (M4)** | Best price/fit for ongoing Tier-2 CI. |
| **MacStadium** (dedicated, not Orka) | dedicated mini/Studio | yes | VNC, root | **~$119/mo M4** | Most OS-version-flexible ("older macOS on request"); SIP changes via Remote Hands. [pricing](https://macstadium.com/pricing) |
| **AWS EC2 Mac** | bare-metal Dedicated Host | yes *while running* — **stop/terminate scrubs the SSD** | VNC over SSH | **~$475/mo (mac2-m2)**, 24h min | Works, ~4–5× the price; good if you're already in AWS. [SIP settings docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/mac-sip-settings.html) |
| OakHost / Macly / HostMyApple / Flow Swiss | dedicated mini | yes | VNC, root | ~€70–$150/mo | Fine shape; ask about the OS minor. |
| **Depot macOS runners** | M4, `depot-macos-26` / `-15` / `-14` | **ephemeral per job** | — | per-minute | Faster GitHub-hosted, **same enablement wall**. [announcement](https://depot.dev/blog/now-available-macos-26-github-actions) |
| **Cirrus / Orka / Tart-clone / Xcode Cloud / GitHub larger runners** | VM and/or ephemeral | no | — | — | **Avoid for FSKit.** Ephemeral kills the one-time enable, and *no source confirms a third-party FSKit extension activates inside a macOS VM guest at all* — treat VM-based offerings as unproven until you test one. |

Two structural rules (from [fskit-go's CI doc](https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md),
and consistent with everything else found here):

1. **Prefer dedicated bare-metal Apple Silicon over any VM** for the FSKit tier.
2. **Reject ephemeral runners** for the FSKit tier — a fresh VM per job erases the one-time
   GUI enable.

And do **not** reject a host for withholding SIP control: FSKit does not need SIP off.

---

## 7. Sample GitHub Actions workflow

Drop-in skeleton that works today. Everything in it is either proven by a cited public
workflow or is plain SwiftPM.

```yaml
name: CI

on:
  push:
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions: {}

jobs:
  # ── Tier 1a: pure-Swift core, both platforms ────────────────────────────────
  unit:
    name: Unit tests (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-15, macos-26]
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }

      - name: Toolchain info
        run: |
          uname -a
          swift --version
          if [ "$RUNNER_OS" = "macOS" ]; then
            sw_vers
            xcodebuild -version
            echo "SIP: $(csrutil status 2>&1 || true)"
            echo "user=$(whoami) uid=$(id -u) admin=$(id -Gn | tr ' ' '\n' | grep -c '^admin$')"
          fi

      - run: swift build -v
      - run: swift test -v

  # ── Tier 1b: loopback 9P server ↔ client, no privileges needed ──────────────
  loopback-9p:
    name: 9P over loopback TCP (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-26]
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }
      # Bind 127.0.0.1 explicitly: macOS 15+ gates Local Network access, loopback is exempt.
      - name: Integration tests against an in-process 9P server on 127.0.0.1
        env:
          FS9KIT_TEST_9P_HOST: "127.0.0.1"
        run: swift test --filter Integration

  # ── Tier 1c: FSKit framework/ABI probe (macOS only, no appex, no enablement) ─
  fskit-probe:
    name: FSKit framework probe (macos-26)
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }
      - name: Select newest Xcode
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - name: Framework present and API surface intact
        run: |
          set -euo pipefail
          xcrun --sdk macosx --show-sdk-version
          ls -d "$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/FSKit.framework"
          # Compile-and-run a probe that asserts the classes/protocols you bind against.
          swift run fskit-probe   # or: xcodebuild -scheme FSKitProbe test

  # ── Tier 1d: build the app + appex, assert bundle/entitlement shape ─────────
  appex-build:
    name: Build FSKit appex (ad-hoc signed)
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }
      - run: sudo xcode-select -s "$(ls -d /Applications/Xcode*.app | sort -V | tail -1)"
      - run: brew install xcodegen
      - run: xcodegen generate --spec macos/FS9P/project.yml
      - name: Build (Release, ad-hoc)
        run: |
          xcodebuild -scheme FS9P -configuration Release \
            -derivedDataPath build CODE_SIGN_IDENTITY="-" build | tail -20
      - name: Assert appex shape
        run: |
          set -euo pipefail
          APPEX="build/Build/Products/Release/FS9P.app/Contents/Extensions/FS9PFS.appex"
          PB=/usr/libexec/PlistBuddy
          test -d "$APPEX"
          $PB -c "Print :EXAppExtensionAttributes:EXExtensionPointIdentifier" "$APPEX/Contents/Info.plist" \
            | grep -qx 'com.apple.fskit.fsmodule'
          $PB -c "Print :EXAppExtensionAttributes:FSShortName" "$APPEX/Contents/Info.plist"
          $PB -c "Print :EXAppExtensionAttributes:FSSupportsPathURLs" "$APPEX/Contents/Info.plist" \
            | grep -qx 'true'
          codesign -d --entitlements - "$APPEX" 2>/dev/null \
            | grep -q 'com.apple.security.app-sandbox'
      # Informational only. `-a` REGISTERS; it does NOT enable. `mount -F` will still fail
      # with "Module <id> is disabled!". Never assert on this step.
      - name: pluginkit registration (informational)
        continue-on-error: true
        run: |
          APPEX="build/Build/Products/Release/FS9P.app/Contents/Extensions/FS9PFS.appex"
          pluginkit -a "$APPEX" || true
          sleep 3
          pluginkit -m -A -D -v -p com.apple.fskit.fsmodule || true

  # ── Tier 1e: REAL mount via the NFSv3-loopback backend (if you build one) ───
  nfs-loopback-mount:
    name: Real mount via NFSv3 loopback (macos-15)
    runs-on: macos-15          # pin 15: FUSE-T/NFS behaviour on 26 is less settled
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }
      - run: swift build -c release

      - name: Start 9P server + fs9kit NFS-loopback bridge, then mount
        run: |
          set -euo pipefail
          MNT=/tmp/fs9kit-nfs
          mkdir -p "$MNT"

          .build/release/fs9p-testserver --listen 127.0.0.1:5640 &
          SRV=$!
          .build/release/fs9p --backend nfs-loopback \
            --addr 127.0.0.1:5640 --mount "$MNT" > bridge.log 2>&1 &
          BRIDGE=$!

          # Bounded readiness poll on a wall-clock deadline. A hard NFS mount that
          # mounted-but-cannot-serve makes a bare `ls` hang forever, so never poll with `ls`.
          # (GNU `timeout` is not installed on macOS runners; use python3.)
          DEADLINE=$(( $(date +%s) + 120 ))
          READY=false
          while [ "$(date +%s)" -lt "$DEADLINE" ]; do
            if python3 -c "
import os,subprocess,sys
sys.exit(0 if subprocess.run(['stat','-f','%T','$MNT'],capture_output=True,timeout=5).returncode==0 else 1)
"; then READY=true; break; fi
            sleep 2
          done
          [ "$READY" = true ] || { echo '::error::mount never became ready'; }

          RC=0
          if [ "$READY" = true ]; then
            swift test --filter MountedFilesystem -Xswiftc -DFS9KIT_MOUNT_TESTS \
              || RC=$?
          else
            RC=1
          fi

          # Force-unmount BEFORE killing the daemon, or teardown can block forever.
          umount -f "$MNT" 2>/dev/null || sudo umount -f "$MNT" 2>/dev/null || true
          kill "$BRIDGE" "$SRV" 2>/dev/null || true
          sleep 2
          kill -9 "$BRIDGE" "$SRV" 2>/dev/null || true
          tail -100 bridge.log || true
          exit $RC

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: nfs-loopback-logs
          path: bridge.log
          if-no-files-found: ignore

  # ── Tier 2: REAL FSKit mount — self-hosted, persistent, pre-enabled, GUI user ─
  # Add this only once you have a Mac configured per §6. It will never work on a
  # GitHub-hosted runner.
  fskit-mount:
    name: FSKit mount certification (self-hosted)
    if: github.event_name == 'workflow_dispatch'
    runs-on: [self-hosted, macOS, ARM64, fskit]
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
        with: { persist-credentials: false }

      - name: Guard — must be the pre-approved GUI user session
        run: |
          set -euo pipefail
          [ "$(launchctl managername)" = "Aqua" ] || {
            echo "::error::FSKit mount tests must run in the pre-approved Aqua session"; exit 1; }
          [ "$(id -u)" -ne 0 ] || {
            echo "::error::must not run as root — FSKit extensions are per-user"; exit 1; }

      - name: Install + verify enablement
        run: |
          set -euo pipefail
          ./scripts/install-fskit-app.sh          # signed build → /Applications/FS9P.app
          open -g /Applications/FS9P.app
          sleep 5
          # If this fails a human must re-toggle System Settings → General →
          # Login Items & Extensions → File System Extensions. Re-signing changes the
          # extension UUID and silently drops the enablement.
          plutil -p "$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist" \
            | grep -q 'fs9kit' || { echo "::error::module not enabled — re-toggle in System Settings"; exit 1; }

      - name: Mount, exercise, unmount
        run: |
          set -euo pipefail
          MNT="$RUNNER_TEMP/fs9p-mnt"; STATE="$RUNNER_TEMP/fs9p-state"
          mkdir -p "$MNT" "$STATE"
          .build/release/fs9p-testserver --listen 127.0.0.1:5640 & SRV=$!
          # NOT under sudo: root cannot invoke the per-user FSKit task.
          /sbin/mount -F -t fs9p -o nobrowse "$STATE" "$MNT"
          [ "$(stat -f %T "$MNT")" = fs9p ]
          ls -la "$MNT"
          swift test --filter MountedFilesystem
          diskutil unmount force "$MNT" || umount -f "$MNT" || true
          kill "$SRV" 2>/dev/null || true
```

---

## 8. Open questions / things to verify yourself

- **SIP status on `macos-15` / `macos-26`** — run `csrutil status` in your first CI job and
  record it. Not blocking either way, but worth knowing.
- **Does `sudo`-less `mount_nfs` work on a GitHub runner?** Both public examples either use
  `sudo` or mount from inside a daemon. sudo is passwordless, so this is academic.
- **Is `pluginkit -e use` durable?** The fskit-go doc says elections are reverted on
  re-discovery; the current man page doesn't say so. Irrelevant for FSKit (elections aren't
  FSKit's enabled list) but relevant if you ever add a Finder Sync extension.
- **Could `osascript` + System Events click the File System Extensions toggle?** The runner
  images pre-grant Accessibility and AppleEvents to `/bin/bash` and `/usr/bin/osascript`, so
  TCC would not block it. Nobody has demonstrated it, System Settings UI scripting is
  notoriously brittle across minors, and the ephemeral VM makes it worthless for
  cross-job persistence — but it might be worth 30 minutes if you ever need a
  *single-job* enable-then-mount. **UNCONFIRMED.**
- **Does a third-party FSKit extension activate inside a macOS VM guest at all?** No source
  confirms it either way. Decide your Tier-2 host on bare metal to avoid finding out the
  hard way.
- **macOS 26 third-party FSKit reliability** — verify a manual mount on your target OS minor
  before committing; see §4.

---

## Sources

Runner images / GitHub docs
- <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md>
- <https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md>
- <https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md>
- <https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md>
- <https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
- <https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/>
- <https://github.blog/changelog/2026-05-14-github-actions-upcoming-image-migrations/>
- <https://github.com/actions/runner-images/issues/14167> (macos-latest → macOS 26)
- <https://github.com/actions/runner-images/issues/13518> (macOS 14 deprecation)
- <https://github.com/actions/runner-images/issues/13046> (macOS 13 deprecation)
- <https://github.com/actions/runner-images/issues/8162> (SIP disabled in macos-13)
- <https://github.com/actions/runner-images/issues/10924> (macOS 15 local network permission)
- <https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-tccdb-macos.sh>
- <https://github.com/actions/runner-images/blob/main/images/macos/scripts/build/configure-machine.sh>
- <https://github.com/actions/runner-images/blob/main/images/macos/assets/bootstrap-provisioner/setAutoLogin.sh>

FSKit enablement / Apple
- <https://developer.apple.com/forums/thread/808594> (DTS: no global/headless enable; per-user; don't write the plist)
- <https://developer.apple.com/forums/thread/788609> (FSKit mount permission failures)
- <https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.fskit.fsmodule>
- <https://developer.apple.com/help/account/capabilities/capability-requests>
- <https://keith.github.io/xcode-man-pages/pluginkit.8.html>
- <https://keith.github.io/xcode-man-pages/fskitd.8.html>, <https://manp.gs/mac/8/fskit_agent>

Real-world FSKit projects / spikes
- <https://github.com/greatliontech/fskit-go/blob/main/docs/ci-and-spike-strategy.md> (the closest prior art to this document)
- <https://github.com/greatliontech/fskit-go/blob/main/.github/workflows/ci.yml>
- <https://github.com/FSM1/cipher-box/blob/main/tools/hw-gates/fskit-spike/RESULTS.md>
- <https://github.com/mohsen1/git-lazy-mount/blob/main/docs/future-platforms/macos-fskit-ondevice.md>
- <https://github.com/indragiek/GHFS/blob/main/FSKIT.md>
- <https://github.com/andrewgazelka/loaf/issues/1> (macOS 26 third-party FSKit breakage)
- <https://github.com/oakdotspace/oak/blob/main/cli/src/commands/mount/fskit/mod.rs> (`mount -F` invocation + caveats)
- <https://github.com/oakdotspace/oak/blob/main/.github/workflows/_build-macos-app.yml> (signed+notarized appex on CI)
- <https://github.com/astrid-runtime/astrid/blob/main/.github/workflows/native-storage-certification.yml> (self-hosted FSKit mount certification)
- <https://github.com/astrid-runtime/astrid/blob/main/scripts/manage-macos-fskit.sh>
- <https://github.com/KhaosT/FSKitSample>
- <https://github.com/madsmtm/objc2/tree/master/examples/fskit>

NFS / FUSE on CI
- <https://github.com/zotero/zotero/blob/master/.github/workflows/ci.yml> (`nfsd` + `mount_nfs` on macos-15)
- <https://github.com/nexi-lab/nexus/blob/main/.github/workflows/fuse-plugin-macos-nfs-e2e.yml> (userspace NFSv3 + `mount_nfs` on macos-latest)
- <https://github.com/macos-fuse-t/fuse-t/wiki> (NFS-loopback technique, no root)
- <https://github.com/macfuse/macfuse/wiki/FUSE-Backends>
- <https://github.com/actions/virtual-environments/issues/4731> (macFUSE kext won't load on runners)
- <https://github.com/macfuse/macfuse/issues/1039> (can't approve macFUSE from CLI)

Virtualization
- <https://github.com/abiosoft/colima/issues/970>, <https://github.com/abiosoft/colima/issues/971>, <https://github.com/abiosoft/colima/issues/1427>
- <https://github.com/douglascamata/setup-docker-macos-action>

Hosting
- <https://macstadium.com/pricing>
- <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/mac-sip-settings.html>
- <https://depot.dev/blog/now-available-macos-26-github-actions>

App-extension registration on CI (proof that `pluginkit` works headlessly)
- <https://github.com/u1aryz/macos-webm-quicklook/blob/main/.github/workflows/ci.yml>
- <https://github.com/moritalous/cost-widget-mac/blob/main/.github/workflows/macos.yml>
- <https://github.com/zoharbabin/fen/blob/main/.github/workflows/release.yml>
- <https://github.com/rnpgp/rnp-mailapp-extension/blob/main/.github/workflows/release.yml>
- <https://github.com/Jesssullivan/tummycrypt/blob/main/.github/workflows/macos-postinstall-smoke.yml>
- <https://github.com/agucova/oxcrypt/blob/main/.github/workflows/rust.yml>
- <https://github.com/kubilaysalih/eylem/blob/main/.github/workflows/release.yml>
