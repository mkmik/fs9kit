#!/usr/bin/env bash
# Runs the interoperability suite against a third-party 9P server.
#
# A client tested only against its own server proves little: both ends can
# share a misreading of the spec. These servers were written by other people,
# in another language, from the same specs.
#
#   Scripts/interop.sh p9ufs      # hugelgupf/p9, speaks 9P2000.L
#   Scripts/interop.sh export9p   # knusbaum/go9p, speaks base 9P2000
#   Scripts/interop.sh all
#
# Requires a Go toolchain on PATH. Both servers are pure Go and build for
# darwin/arm64 and linux as-is.
set -euo pipefail
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

: "${GOBIN:=$(go env GOPATH)/bin}"
export PATH="$GOBIN:$PATH"

server_pid=""
fixture=""

cleanup() {
    [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
    [[ -n "$fixture" && -d "$fixture" ]] && rm -rf "$fixture" || true
}
trap cleanup EXIT

install_servers() {
    command -v p9ufs    >/dev/null || go install github.com/hugelgupf/p9/cmd/p9ufs@latest
    command -v export9p >/dev/null || go install github.com/knusbaum/go9p/cmd/export9p@latest
}

make_fixture() {
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/fs9kit-fixture.XXXXXX")"
    mkdir -p "$fixture/dir/nested"
    printf 'hello 9p\n'            > "$fixture/hello.txt"
    printf 'nested content\n'      > "$fixture/dir/nested/deep.txt"
    # A file big enough to span several msize-sized reads.
    head -c 300000 /dev/urandom    > "$fixture/big.bin"
    ln -sf hello.txt "$fixture/link-to-hello" 2>/dev/null || true
    echo "$fixture"
}

# Waits for the server to accept connections rather than sleeping and hoping.
wait_for_port() {
    local port="$1" tries=0
    while (( tries < 100 )); do
        if command -v nc >/dev/null && nc -z 127.0.0.1 "$port" 2>/dev/null; then return 0; fi
        # nc is not everywhere; fall back to bash's own /dev/tcp.
        if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3>&- 3<&-; return 0; fi
        tries=$((tries + 1)); sleep 0.1
    done
    echo "server never came up on port $port" >&2
    return 1
}

run_case() {
    local name="$1" port="$2" version="$3" offer="$4"
    local log; log="$(mktemp "${TMPDIR:-/tmp}/fs9kit-interop.XXXXXX.log")"
    make_fixture >/dev/null
    echo "=== $name on 127.0.0.1:$port (expecting $version), exporting $fixture"

    case "$name" in
        p9ufs)    p9ufs -root "$fixture" "127.0.0.1:$port" & ;;
        export9p) export9p -noperm -dir "$fixture" -address "127.0.0.1:$port" & ;;
        *) echo "unknown server $name" >&2; return 1 ;;
    esac
    server_pid=$!
    wait_for_port "$port"

    FS9KIT_9P_ADDR="tcp!127.0.0.1!$port" \
    FS9KIT_9P_ROOT="$fixture" \
    FS9KIT_9P_VERSION="$version" \
    FS9KIT_9P_NAME="$name" \
    FS9KIT_9P_OFFER="$offer" \
    swift test --filter InteropTests 2>&1 | tee "$log" || {
        echo "--- failures against $name"
        grep -E "✘|recorded an issue" "$log" | grep -v " skipped\.$" | head -40
        return 1
    }

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
    rm -rf "$fixture"; fixture=""
}

install_servers

case "${1:-all}" in
    p9ufs)    run_case p9ufs 5640 9P2000.L "9P2000.L" ;;
    # export9p cannot answer a 9P2000.L Tversion at all, so offer it only the
    # dialect it speaks rather than making every connection wait out a timeout.
    export9p) run_case export9p 5641 9P2000 "9P2000" ;;
    all)
        run_case p9ufs 5640 9P2000.L "9P2000.L"
        run_case export9p 5641 9P2000 "9P2000"
        ;;
    *) echo "usage: $0 [p9ufs|export9p|all]" >&2; exit 2 ;;
esac

echo "interop: all cases passed"
