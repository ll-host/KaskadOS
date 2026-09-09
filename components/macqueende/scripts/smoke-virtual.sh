#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
macqueen_binary="$repo_root/build/compositor/bin/macqueen"

if [[ ! -x "$macqueen_binary" ]]; then
    echo "Missing compositor build: $macqueen_binary" >&2
    echo "Build the macqueen target first. See docs/BUILDING.md." >&2
    exit 1
fi

smoke_dir=$(mktemp -d /tmp/macqueen-smoke.XXXXXX)
cleanup()
{
    rm -r -- "$smoke_dir"
}
trap cleanup EXIT

mkdir -p \
    "$smoke_dir/runtime" \
    "$smoke_dir/config" \
    "$smoke_dir/cache" \
    "$smoke_dir/data"
chmod 700 "$smoke_dir/runtime"

echo "Starting an isolated virtual compositor smoke test..."

env \
    XDG_RUNTIME_DIR="$smoke_dir/runtime" \
    XDG_CONFIG_HOME="$smoke_dir/config" \
    XDG_CACHE_HOME="$smoke_dir/cache" \
    XDG_DATA_HOME="$smoke_dir/data" \
    KWIN_COMPOSE=Q \
    QT_PLUGIN_PATH="$repo_root/build/compositor/bin:$repo_root/build/compositor/lib" \
    timeout 15s \
    "$macqueen_binary" \
        --virtual \
        --width 1280 \
        --height 720 \
        --socket macqueen-smoke \
        --no-lockscreen \
        --no-global-shortcuts \
        --no-kactivities \
        --exit-with-session /usr/bin/true

echo "Virtual compositor smoke test passed."
