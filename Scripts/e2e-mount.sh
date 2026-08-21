#!/usr/bin/env bash
# End-to-end proof that a 9P server can be mounted and used as a real
# filesystem, through the kernel's own NFS client.
#
# Everything else in the test suite talks to our own code. This talks to the
# kernel: if the mount is wrong, `cat` and `cp` say so.
#
#   Scripts/e2e-mount.sh            # serve a fixture with fs9p and mount it
#   Scripts/e2e-mount.sh p9ufs      # serve it with a third-party 9P server
#
# Two rules keep a failure legible rather than turning into a CI job that
# holds a runner until the workflow's own limit with nothing printed:
#
#  * every step announces itself *before* it runs, so the last line of a
#    truncated log names what wedged;
#  * nothing that touches the mount point runs unbounded, and no bounded
#    command is allowed to hold this script's stdout after its deadline —
#    see `run` below for why that second half matters.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

server="${1:-fs9p}"
fs9p="$repo_root/.build/release/fs9p"
port="${FS9P_TEST_PORT:-5673}"
# The whole exercise phase gets a deadline of its own, comfortably inside the
# workflow's, so the diagnostics below always get a chance to print.
# The serial phase takes well under a minute, so a generous multiple of that
# still surfaces a wedge quickly rather than at the workflow's limit.
overall_deadline="${FS9P_E2E_DEADLINE:-300}"

fixture=""
mountpoint=""
scratch=""
server_pid=""
mount_pid=""
watchdog_pid=""
failures=0
started_at=$SECONDS

stamp() { printf '[%3ds] ' "$((SECONDS - started_at))"; }
log()   { printf '\n\033[1m== %s %s\033[0m\n' "$(stamp)" "$*"; }
step()  { printf '   ..   %s%s\n' "$(stamp)" "$*"; }
ok()    { printf '   ok   %s\n' "$*"; }
fail()  { printf '   FAIL %s\n' "$*"; failures=$((failures + 1)); }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/fs9kit-e2e-scratch.XXXXXX")"

# Run a command under a deadline.
#
# Base macOS ships no timeout(1) — it is GNU coreutils — so this cannot lean
# on one. The hand-rolled watchdog has to be more careful than it looks:
#
#  * A process blocked in an NFS RPC is often uninterruptible, so `kill -9`
#    does not necessarily reap it. Waiting on it after the deadline would
#    reintroduce exactly the unbounded wait the deadline exists to prevent,
#    so once the deadline passes this stops waiting and reports 124.
#  * Output goes to a file, never straight to this script's stdout. Callers
#    use `$(run ...)`, and a command substitution does not finish until every
#    writer to its pipe is gone — an abandoned child would hold it open
#    forever, wedging the script even though the deadline fired.
run() {
    local secs="$1"; shift
    # A distinct file per call: the concurrency section runs several of these
    # at once.
    local out; out="$(mktemp "$scratch/run.XXXXXX")"
    "$@" >"$out" 2>"$out.err" &
    local pid=$! status=0 waited=0 limit=$((secs * 10))
    while (( waited < limit )) && kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        status=124
    else
        wait "$pid" || status=$?
    fi
    cat "$out"
    (( status == 0 )) || { sed 's/^/        | /' "$out.err" >&2 || true; }
    rm -f "$out" "$out.err"
    return "$status"
}

check() {
    local label="$1"; shift
    step "$label"
    if run 45 "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi
}

check_equal() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        fail "$label (expected '$expected', got '$actual')"
    fi
}

diagnostics() {
    echo "--- mount table"
    mount | grep -i nfs || true
    echo "--- processes stuck on the mount (state U or D means uninterruptible)"
    ps -o pid,stat,wchan,command -A 2>/dev/null | grep -v grep | grep -E "$mountpoint|fs9p|shasum|dd |cat " || true
    echo "--- nfsstat"
    nfsstat -c 2>/dev/null | head -40 || true
}

dump_logs() {
    if [[ -n "${mount_log:-}" && -f "$mount_log" ]]; then
        echo "--- fs9p mount log"; cat "$mount_log"
    fi
    if [[ -n "${server_log:-}" && -f "$server_log" ]]; then
        echo "--- 9P server log"; cat "$server_log"
    fi
}

# Killing the watchdog subshell does not kill the `sleep` it is blocked in —
# that is a child of its own, and it outlives the script as an orphan.
stop_watchdog() {
    [[ -n "$watchdog_pid" ]] || return 0
    pkill -P "$watchdog_pid" 2>/dev/null
    kill "$watchdog_pid" 2>/dev/null
    watchdog_pid=""
}

cleanup() {
    set +e
    stop_watchdog
    if [[ -n "$mountpoint" ]] && mount | grep -q " $mountpoint "; then
        run 30 sudo umount -f "$mountpoint"
    fi
    [[ -n "$mount_pid" ]] && kill "$mount_pid" 2>/dev/null
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
    dump_logs
    sleep 0.3
    [[ -n "$mountpoint" ]] && rmdir "$mountpoint" 2>/dev/null
    [[ -n "$fixture" ]] && rm -rf "$fixture"
    [[ -n "$scratch" ]] && rm -rf "$scratch"
    set -e
}
trap cleanup EXIT

# ---------------------------------------------------------------- build

log "Building"
swift build -c release --product fs9p
[[ -x "$fs9p" ]] || { echo "fs9p was not built at $fs9p" >&2; exit 1; }

# ---------------------------------------------------------------- fixture

log "Preparing the fixture"
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
# One file per concurrent reader, laid down before the mount exists so that no
# cached lookup decides whether they are visible. Eight readers of the *same*
# file would prove nothing: the client serves all but the first from its own
# cache — the first run of that section issued no NFS READs at all — so the
# requests never overlap at the bridge, which is the thing under test.
for i in 1 2 3 4 5 6 7 8; do
    cp "$fixture/big.bin" "$fixture/concurrent-$i.bin"
done
dir_count="$(ls -1 "$fixture/dir" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------- serve

log "Starting the 9P server ($server)"
# Anything backgrounded gets its own log file rather than the step's stdout: a
# process still holding that pipe keeps the CI step alive after the script has
# finished, which reads as a hang rather than a result.
server_log="$scratch/server.log"
case "$server" in
    fs9p)
        "$fs9p" serve "$fixture" --port="$port" > "$server_log" 2>&1 &
        server_pid=$!
        ;;
    p9ufs)
        command -v p9ufs >/dev/null || go install github.com/hugelgupf/p9/cmd/p9ufs@latest
        "$(go env GOPATH)/bin/p9ufs" -root "$fixture" "127.0.0.1:$port" > "$server_log" 2>&1 &
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
mount_log="$scratch/mount.log"
"$fs9p" mount "tcp!127.0.0.1!$port" "$mountpoint" > "$mount_log" 2>&1 &
mount_pid=$!

mounted=no
for _ in $(seq 1 150); do
    if mount | grep -q " $mountpoint "; then mounted=yes; break; fi
    kill -0 "$mount_pid" 2>/dev/null || break
    sleep 0.2
done
if [[ "$mounted" != yes ]]; then
    echo "the filesystem never mounted; fs9p said:" >&2
    cat "$mount_log" >&2
    diagnostics
    exit 1
fi
mount | grep " $mountpoint " || true

# From here on the mount exists, so a wedge is possible. The watchdog prints
# what everything was doing and then tears the mount down, which releases any
# process blocked on it and lets the script reach its own exit path.
(
    sleep "$overall_deadline"
    printf '\n\033[1m== DEADLINE: the exercise phase exceeded %ss\033[0m\n' "$overall_deadline"
    diagnostics
    sudo umount -f "$mountpoint" 2>/dev/null
    sleep 2
    kill -TERM "$$" 2>/dev/null
) &
watchdog_pid=$!

# ---------------------------------------------------------------- exercise

log "Reading"
step "cat a small file"
check_equal "cat a small file" "hello from 9p" "$(run 20 cat "$mountpoint/hello.txt")"
step "cat through a subdirectory"
check_equal "cat through a subdirectory" "deep content" "$(run 20 cat "$mountpoint/dir/nested/deep.txt")"
step "checksum a 4 MiB file"
check_equal "a 4 MiB file survives the round trip" "$big_sum" \
    "$(run 90 shasum -a 256 "$mountpoint/big.bin" | cut -d' ' -f1)"
step "list a 200-entry directory"
check_equal "ls counts the directory correctly" "$dir_count" \
    "$(run 45 ls -1 "$mountpoint/dir" | wc -l | tr -d ' ')"
step "stat a file"
check_equal "stat reports the right size" "$(stat -f%z "$fixture/hello.txt")" \
    "$(run 20 stat -f%z "$mountpoint/hello.txt")"
check "find walks the whole tree" find "$mountpoint" -type f
step "seek into a file"
check_equal "seeking into a file works" "content" \
    "$(run 20 dd if="$mountpoint/dir/nested/deep.txt" bs=1 skip=5 count=7)"
check "df reports the volume" df -k "$mountpoint"

log "Writing"
check "creating a file through the mount" \
    bash -c 'printf "written through the mount\n" > "$1"' _ "$mountpoint/new.txt"
check_equal "a new file lands on the server" "written through the mount" \
    "$(cat "$fixture/new.txt")"
step "read the new file back"
check_equal "and reads back through the mount" "written through the mount" \
    "$(run 20 cat "$mountpoint/new.txt")"

check "copying 4 MiB in" cp "$fixture/big.bin" "$mountpoint/copied.bin"
check_equal "copying 4 MiB in preserves every byte" "$big_sum" \
    "$(shasum -a 256 "$fixture/copied.bin" | cut -d' ' -f1)"

check "appending" bash -c 'printf "appended\n" >> "$1"' _ "$mountpoint/new.txt"
check_equal "append works" "written through the mount
appended" "$(cat "$fixture/new.txt")"

log "Namespace"
check "mkdir through the mount" mkdir "$mountpoint/made"
check "mkdir creates a directory on the server" test -d "$fixture/made"
check "write into the new directory" bash -c 'echo x > "$1"' _ "$mountpoint/made/file"
check "rename within a directory" mv "$mountpoint/made/file" "$mountpoint/made/renamed"
check "rename moves the file" test -f "$fixture/made/renamed"
check "and the old name is gone" test ! -e "$fixture/made/file"
check "rename across directories" mv "$mountpoint/made/renamed" "$mountpoint/moved-out"
check "rename across directories works" test -f "$fixture/moved-out"
check "unlink" rm "$mountpoint/moved-out"
check "rm removes it" test ! -e "$fixture/moved-out"
check "rmdir" rmdir "$mountpoint/made"
check "rmdir removes the directory" test ! -d "$fixture/made"

step "symlink"
if run 20 ln -s hello.txt "$mountpoint/link" >/dev/null 2>&1; then
    check_equal "a symlink created through the mount resolves" "hello from 9p" \
        "$(run 20 cat "$mountpoint/link")"
    check_equal "and points where it should" "hello.txt" \
        "$(run 20 readlink "$mountpoint/link")"
else
    printf '   skip symlinks (server declined)\n'
fi

log "Attributes"
step "chmod"
if run 20 chmod 600 "$mountpoint/new.txt" >/dev/null 2>&1; then
    check_equal "chmod takes effect" "600" "$(stat -f%Lp "$fixture/new.txt")"
else
    printf '   skip chmod (server declined)\n'
fi

check "truncate" bash -c ': > "$1"' _ "$mountpoint/new.txt"
check_equal "truncate empties the file" "0" "$(stat -f%z "$fixture/new.txt")"

log "Concurrency"
step "eight concurrent 4 MiB checksums"
readers=()
for i in 1 2 3 4 5 6 7 8; do
    ( run 120 shasum -a 256 "$mountpoint/concurrent-$i.bin" | cut -d' ' -f1 \
        > "$fixture/sum.$i" ) &
    readers+=("$!")
done
# Named explicitly, never bare: a bare `wait` also waits for the deadline
# watchdog above, which is a background job of this same shell and sleeps for
# the whole deadline. That turned a section which had already finished into a
# job that sat until the watchdog fired.
for pid in "${readers[@]}"; do wait "$pid" || true; done
concurrent_ok=yes
for i in 1 2 3 4 5 6 7 8; do
    [[ "$(cat "$fixture/sum.$i")" == "$big_sum" ]] || concurrent_ok=no
done
check_equal "eight concurrent readers all agree" "yes" "$concurrent_ok"

# ---------------------------------------------------------------- unmount

log "Unmounting"
stop_watchdog
check "umount" "$fs9p" umount "$mountpoint"
sleep 0.5
if mount | grep -q " $mountpoint "; then fail "still mounted"; else ok "unmounted cleanly"; fi

log "Result"
if (( failures > 0 )); then
    diagnostics
    echo "$failures check(s) failed"
    exit 1
fi
echo "all checks passed"
