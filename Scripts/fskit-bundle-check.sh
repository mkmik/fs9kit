#!/usr/bin/env bash
# Builds the FSKit app and extension, then asserts on the bundle it produced.
#
# A real FSKit mount cannot be tested on a hosted runner: a third-party module
# is enabled by a per-user switch in System Settings, and Apple has confirmed
# there is no CLI, MDM or programmatic route to it. So this checks everything
# that can be checked without mounting — and every assertion below corresponds
# to a failure mode that a green `xcodebuild` alone does not catch.
#
# macOS 26 or later only: the extensionkit-extension product type and
# FSGenericURLResource both arrived there.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
ok()   { printf '   ok  %s\n' "$*"; }

major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 26 )); then
    echo "macOS $major: skipping, the FSKit bundle needs the macOS 26 SDK"
    exit 0
fi

command -v xcodegen >/dev/null || brew install xcodegen

echo "== Generating the Xcode project"
( cd macos && xcodegen generate )

echo "== Building"
( cd macos && xcodebuild -project FS9Kit.xcodeproj \
    -scheme FS9Kit \
    -configuration Release \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build )

APP="macos/build/Build/Products/Release/FS9Kit.app"
APPEX="$APP/Contents/Extensions/FS9KitExtension.appex"
PLIST="$APPEX/Contents/Info.plist"

echo "== Checking the bundle"

# An appex outside Contents/Extensions is invisible to pluginkit, and the build
# still succeeds.
[[ -d "$APPEX" ]] || fail "the extension is not embedded in Contents/Extensions"
[[ -f "$APPEX/Contents/MacOS/FS9KitExtension" ]] || fail "the extension has no executable"
ok "the extension is embedded where pluginkit will find it"

extract() { plutil -extract "$1" raw "$PLIST" 2>/dev/null; }

# The wrong extension point produces something that registers and is never
# called.
[[ "$(extract EXAppExtensionAttributes.EXExtensionPointIdentifier)" == "com.apple.fskit.fsmodule" ]] \
    || fail "wrong extension point identifier"
ok "extension point is com.apple.fskit.fsmodule"

[[ "$(extract EXAppExtensionAttributes.FSShortName)" == "fs9kit" ]] \
    || fail "FSShortName is not fs9kit, so 'mount -t fs9kit' will not resolve"
ok "mount -t fs9kit will resolve"

# mount(8) tests these in the order Block, PathURL, GenericURL, ServerURL and
# takes the first true one, so a stray true on either of the first two silently
# changes how the mount argument is parsed.
[[ "$(extract EXAppExtensionAttributes.FSSupportsGenericURLResources)" == "true"  ]] \
    || fail "FSSupportsGenericURLResources must be true to mount a URL"
for key in FSSupportsBlockResources FSSupportsPathURLs FSSupportsServerURLs; do
    [[ "$(extract "EXAppExtensionAttributes.$key")" == "false" ]] \
        || fail "$key must be false or mount(8) parses the argument differently"
done
ok "the resource flags say URL, not disk"

schemes="$(plutil -extract EXAppExtensionAttributes.FSSupportedSchemes json -o - "$PLIST")"
grep -q '"9p"' <<<"$schemes" || fail "the 9p scheme is not advertised"
ok "the schemes in the README are the schemes the bundle advertises"

# Without FSActivateOptionSyntax, mount(8) reports "does not support operation
# mount" and the module is never reached.
extract EXAppExtensionAttributes.FSActivateOptionSyntax.shortOptions | grep -q 'o:' \
    || fail "FSActivateOptionSyntax is missing, so mount -o will not parse"
ok "mount -o will parse"

# Building against an older SDK produces a bundle that fails only at run time.
[[ "$(plutil -extract LSMinimumSystemVersion raw "$APPEX/Contents/Info.plist")" == "26.0" ]] \
    || fail "the extension's deployment target is not macOS 26"
ok "deployment target is macOS 26"

# The pair that bites: fskitd refuses an unsandboxed extension, and a sandboxed
# container app cannot call /sbin/mount.
ext_entitlements="macos/FS9KitExtension/FS9KitExtension.entitlements"
app_entitlements="macos/FS9KitApp/FS9KitApp.entitlements"
for key in com.apple.security.app-sandbox com.apple.developer.fskit.fsmodule \
           com.apple.security.network.client; do
    grep -q "$key" "$ext_entitlements" || fail "the extension is missing $key"
done
! grep -q '<key>com.apple.security.app-sandbox</key>' "$app_entitlements" \
    || fail "the containing app is sandboxed, so it cannot call /sbin/mount"
ok "the extension is sandboxed and the app is not"

echo
echo "the FSKit bundle is well formed; mounting still needs a signed build on a real Mac"
