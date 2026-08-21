#!/usr/bin/env bash
# End-to-end proof that a 9P server can be mounted and used as a real
# filesystem, through the kernel's own NFS client.
#
# Everything else in the test suite talks to our own code. This talks to the
# kernel: if the mount is wrong, `cat` and `cp` say so.
#
#   Scripts/e2e-mount.sh            # serve a fixture with fs9p and mount it
#   Scripts/e2e-mount.sh p9ufs      # serve it with a third-party 9P server
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

server="${1:-fs9p}"
fs9p="$repo_root/.build/release/fs9p"
port="${FS9P_TEST_PORT:-5673}"

fixture=""
mountpoint=""
server_pid=""
mount_pid=""
failures=0

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
fail() { printf '   FAIL %s\n' "$*"; failures=$((failures + 1)); }

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi
}

check_equal() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

cleanup() {
    set +e
    if [[ -n "$mountpoint" ]] && mount | grep -q " $mountpoint "; then
        sudo umount -f "$mountpoint" 2>/dev/null
    fi
    [[ -n "$mount_pid" ]] && kill "$mount_pid" 2>/dev/null
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
    sleep 0.3
    [[ -n "$mountpoint" ]] && rmdir "$mountpoint" 2>/dev/null
    [[ -n "$fixture" ]] && rm -rf "$fixture"
    set -e
}
trap cleanup EXIT

# ---------------------------------------------------------------- build

log "Building"
swift build -c release --product fs9p
[[ -x "$fs9p" ]] || { echo "fs9p was not built at $fs9p" >&2; exit 1; }

# ---------------------------------------------------------------- fixture

fixture="$(mktemp -d "${TMPDIR:-/tmp}/fs9kit-e2e.XXXXXX")"
mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/fs9kit-mnt.XXXXXX")"
# macOS reports mounts under their real path, and /var is a symlink to
# /private/var, so a mktemp path never matches what `mount` prints.
mountpoint="$(cd "$mountpoint" && pwd -P)"
fixture="$(cd "$fixture" && pwd -P)"

mkdir -p "$fixture/dir/nested"
printf 'hello from 9p\n'      > "$fixture/hello.txt"
printf 'deep content\n'       > "$fixture/dir/nested/deep.txt"
head -c 4194304 /dev/urandom  > "$fixture/big.bin"
for i in $(seq 1 200); do : > "$fixture/dir/entry-$i"; done
big_sum="$(shasum -a 256 "$fixture/big.bin" | cut -d' ' -f1)"

# ---------------------------------------------------------------- serve

log "Starting the 9P server ($server)"
case "$server" in
    fs9p)
        "$fs9p" serve "$fixture" --port="$port" &
        server_pid=$!
        ;;
    p9ufs)
        command -v p9ufs >/dev/null || go install github.com/hugelgupf/p9/cmd/p9ufs@latest
        "$(go env GOPATH)/bin/p9ufs" -root "$fixture" "127.0.0.1:$port" &
        server_pid=$!
        ;;
    *) echo "unknown server '$server'" >&2; exit 2 ;;
esac

for _ in $(seq 1 100); do
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
    sleep 0.1
done

# ---------------------------------------------------------------- mount

log "Mounting on $mountpoint"
"$fs9p" mount "tcp!127.0.0.1!$port" "$mountpoint" &
mount_pid=$!

mounted=no
for _ in $(seq 1 150); do
    if mount | grep -q " $mountpoint "; then mounted=yes; break; fi
    kill -0 "$mount_pid" 2>/dev/null || break
    sleep 0.2
done
if [[ "$mounted" != yes ]]; then
    echo "the filesystem never mounted" >&2
    mount | grep -i nfs || true
    exit 1
fi
mount | grep " $mountpoint " || true

# ---------------------------------------------------------------- exercise

log "Reading"
check_equal "cat a small file" "hello from 9p" "$(cat "$mountpoint/hello.txt")"
check_equal "cat through a subdirectory" "deep content" "$(cat "$mountpoint/dir/nested/deep.txt")"
check_equal "a 4 MiB file survives the round trip" "$big_sum" \
    "$(shasum -a 256 "$mountpoint/big.bin" | cut -d' ' -f1)"
check_equal "ls counts the directory correctly" \
    "$(ls -1 "$fixture/dir" | wc -l | tr -d ' ')" \
    "$(ls -1 "$mountpoint/dir" | wc -l | tr -d ' ')"
check_equal "stat reports the right size" "$(stat -f%z "$fixture/hello.txt")" \
    "$(stat -f%z "$mountpoint/hello.txt")"
check "find walks the whole tree" find "$mountpoint" -type f
check_equal "seeking into a file works" "content" \
    "$(dd if="$mountpoint/dir/nested/deep.txt" bs=1 skip=5 count=7 2>/dev/null)"
check "df reports the volume" df -k "$mountpoint"

log "Writing"
echo "written through the mount" > "$mountpoint/new.txt"
check_equal "a new file lands on the server" "written through the mount" \
    "$(cat "$fixture/new.txt")"
check_equal "and reads back through the mount" "written through the mount" \
    "$(cat "$mountpoint/new.txt")"

cp "$fixture/big.bin" "$mountpoint/copied.bin"
check_equal "copying 4 MiB in preserves every byte" "$big_sum" \
    "$(shasum -a 256 "$fixture/copied.bin" | cut -d' ' -f1)"

printf 'appended\n' >> "$mountpoint/new.txt"
check_equal "append works" "written through the mount
appended" "$(cat "$fixture/new.txt")"

log "Namespace"
mkdir "$mountpoint/made"
check "mkdir creates a directory on the server" test -d "$fixture/made"
echo x > "$mountpoint/made/file"
mv "$mountpoint/made/file" "$mountpoint/made/renamed"
check "rename moves the file" test -f "$fixture/made/renamed"
check "and the old name is gone" test ! -e "$fixture/made/file"
mv "$mountpoint/made/renamed" "$mountpoint/moved-out"
check "rename across directories works" test -f "$fixture/moved-out"
rm "$mountpoint/moved-out"
check "rm removes it" test ! -e "$fixture/moved-out"
rmdir "$mountpoint/made"
check "rmdir removes the directory" test ! -d "$fixture/made"

if ln -s hello.txt "$mountpoint/link" 2>/dev/null; then
    check_equal "a symlink created through the mount resolves" "hello from 9p" \
        "$(cat "$mountpoint/link")"
    check_equal "and points where it should" "hello.txt" \
        "$(readlink "$mountpoint/link")"
else
    printf '   skip symlinks (server declined)\n'
fi

log "Attributes"
chmod 600 "$mountpoint/new.txt" 2>/dev/null && \
    check_equal "chmod takes effect" "600" "$(stat -f%Lp "$fixture/new.txt")" || \
    printf '   skip chmod (server declined)\n'

: > "$mountpoint/new.txt"
check_equal "truncate empties the file" "0" "$(stat -f%z "$fixture/new.txt")"

log "Concurrency"
for i in 1 2 3 4 5 6 7 8; do
    ( shasum -a 256 "$mountpoint/big.bin" | cut -d' ' -f1 > "$fixture/sum.$i" ) &
done
wait
concurrent_ok=yes
for i in 1 2 3 4 5 6 7 8; do
    [[ "$(cat "$fixture/sum.$i")" == "$big_sum" ]] || concurrent_ok=no
done
check_equal "eight concurrent readers all agree" "yes" "$concurrent_ok"

# ---------------------------------------------------------------- unmount

log "Unmounting"
"$fs9p" umount "$mountpoint"
sleep 0.5
if mount | grep -q " $mountpoint "; then fail "still mounted"; else ok "unmounted cleanly"; fi

log "Result"
if (( failures > 0 )); then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
