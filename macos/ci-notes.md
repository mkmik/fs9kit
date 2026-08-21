# What CI should run for the FSKit backend

Notes for whoever wires this into `.github/workflows/ci.yml`. Nothing here
edits a workflow file.

## What cannot be tested, and why

**A real FSKit mount cannot happen on a hosted runner. Do not add a job that
tries.** A third-party FSKit module is enabled by a per-user switch in System
Settings; Apple's DTS has confirmed there is no CLI, MDM or programmatic route,
writing `enabledModules.plist` by hand is not honoured by `fskitd`, and
`FSClient.setEnabledStateForIdentifier` needs a private entitlement. A job that
mounts would either hang or pass vacuously.

Nor can the extension be signed on CI: `com.apple.developer.fskit.fsmodule`
needs a real team, and secrets are not available to fork pull requests. So CI
builds with signing off and asserts on the bundle it produces.

## Job 1 — the adapter logic (Linux and macOS, every push)

Already covered by the existing `swift test` invocation once
`Tests/FS9KitAdapterTests` exists. It runs on Linux: every test in it is
FSKit-free by construction — URL parsing, attribute and time translation, the
errno table, open-mode translation, directory planning, the container-UUID
derivation. 89 tests as of writing.

No new job needed. Just make sure the Linux job is not filtered to specific
targets.

## Job 2 — the bundle (macOS 26 runner only)

Runs on `macos-26` or later. Skip it entirely on `macos-15`: the
`extensionkit-extension` product type and the macOS 26 SDK are both required,
and `FSGenericURLResource` does not exist before then.

```yaml
- name: Install XcodeGen
  run: brew install xcodegen

- name: Generate the Xcode project
  working-directory: macos
  run: xcodegen generate

- name: Build the app and extension
  working-directory: macos
  run: |
    xcodebuild -project FS9Kit.xcodeproj \
               -scheme FS9Kit \
               -configuration Release \
               -derivedDataPath build \
               CODE_SIGNING_ALLOWED=NO \
               CODE_SIGNING_REQUIRED=NO \
               CODE_SIGN_IDENTITY="" \
               build
```

`CODE_SIGNING_ALLOWED=NO` is what makes this work without a team. The resulting
bundle cannot be loaded by `fskitd` — that is expected and is exactly why there
is no mount step.

## Job 2 assertions

Run these after the build. Each one catches a specific, previously-observed
failure mode; a green `xcodebuild` alone does not.

```sh
APP=macos/build/Build/Products/Release/FS9Kit.app
APPEX="$APP/Contents/Extensions/FS9KitExtension.appex"
PLIST="$APPEX/Contents/Info.plist"
```

**The extension is embedded in the right place.** An appex outside
`Contents/Extensions` is invisible to `pluginkit`, and the build still succeeds.

```sh
test -d "$APPEX" || { echo "appex not embedded in Contents/Extensions"; exit 1; }
test -f "$APPEX/Contents/MacOS/FS9KitExtension" || exit 1
```

**The extension point is the FSKit one.** Getting `com.apple.fskit.unary` or the
legacy `NSExtensionPointIdentifier` spelling here produces an extension that
registers and is never called.

```sh
plutil -extract EXAppExtensionAttributes.EXExtensionPointIdentifier raw "$PLIST" \
  | grep -qx 'com.apple.fskit.fsmodule' || exit 1
```

**`mount -t fs9kit` will resolve.**

```sh
plutil -extract EXAppExtensionAttributes.FSShortName raw "$PLIST" | grep -qx 'fs9kit' || exit 1
```

**The resource-selection flags say "URL, not disk".** `mount(8)` tests these in
the order Block → PathURL → GenericURL → ServerURL and takes the first that is
true, so a stray `true` on either of the first two silently changes how the
mount argument is parsed.

```sh
plutil -extract EXAppExtensionAttributes.FSSupportsGenericURLResources raw "$PLIST" | grep -qx 'true'  || exit 1
plutil -extract EXAppExtensionAttributes.FSSupportsBlockResources     raw "$PLIST" | grep -qx 'false' || exit 1
plutil -extract EXAppExtensionAttributes.FSSupportsPathURLs           raw "$PLIST" | grep -qx 'false' || exit 1
plutil -extract EXAppExtensionAttributes.FSSupportsServerURLs         raw "$PLIST" | grep -qx 'false' || exit 1
```

**Every scheme the parser accepts is advertised, and vice versa.** These two
lists drifting apart is the failure that looks like "the mount command in the
README just does not work".

`MountURLTests` already asserts that every element of `MountSpec.allSchemes`
parses, so all this job has to check is that the plist advertises the two
spellings the README tells people to type:

```sh
plutil -extract EXAppExtensionAttributes.FSSupportedSchemes json -o - "$PLIST" | grep -q '"9p"' || exit 1
plutil -extract EXAppExtensionAttributes.FSSupportedSchemes json -o - "$PLIST" | grep -q '"p9"' || exit 1
```

**`mount -o` will parse.** Without `FSActivateOptionSyntax`, `mount(8)` reports
"does not support operation mount" and the module is never reached.

```sh
plutil -extract EXAppExtensionAttributes.FSActivateOptionSyntax.shortOptions raw "$PLIST" \
  | grep -q 'o:' || exit 1
```

**The extension is sandboxed and the app is not.** This pair is the one that
bites: an unsandboxed extension is refused by `fskitd`, and a sandboxed
container app cannot call `/sbin/mount`.

```sh
grep -q 'com.apple.security.app-sandbox' macos/FS9KitExtension/FS9KitExtension.entitlements || exit 1
grep -q 'com.apple.developer.fskit.fsmodule' macos/FS9KitExtension/FS9KitExtension.entitlements || exit 1
grep -q 'com.apple.security.network.client' macos/FS9KitExtension/FS9KitExtension.entitlements || exit 1
! grep -q '<key>com.apple.security.app-sandbox</key>' macos/FS9KitApp/FS9KitApp.entitlements || exit 1
```

When the build *is* signed (a release job with a team secret), assert on the
signature instead of on the source file, which is what actually ships:

```sh
codesign -dv --entitlements - "$APPEX" 2>&1 | grep -q 'com.apple.developer.fskit.fsmodule' || exit 1
codesign -dv --entitlements - "$APP"   2>&1 | grep -q 'app-sandbox' && exit 1
```

**The deployment target is macOS 26.** Building against an older SDK produces a
bundle that cannot mount anything and fails only at run time.

```sh
plutil -extract LSMinimumSystemVersion raw "$APPEX/Contents/Info.plist" | grep -qx '26.0' || exit 1
```

## Job 3 — not needed

There is no third job. The 9P client, the VFS and every translation the FSKit
glue performs are covered by the Linux suites; the FSKit glue itself compiles
only on macOS and is covered by job 2's build.
