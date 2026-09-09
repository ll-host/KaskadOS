#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
macqueen_binary="$repo_root/build/compositor/bin/macqueen"
module_build="$repo_root/build/quickshell-macqueen"
smoke_qml="$repo_root/quickshell/macqueen-module/tests/smoke.qml"

if [[ ! -x "$macqueen_binary" ]]; then
    echo "Missing compositor build: $macqueen_binary" >&2
    exit 1
fi

if [[ ! -f "$module_build/Macqueen/Ipc/qmldir" ]]; then
    echo "Missing Quickshell module build. See docs/BUILDING.md." >&2
    exit 1
fi

echo "Starting the Macqueen and Quickshell integration smoke test..."

dbus-run-session -- bash -c '
set -euo pipefail

repo_root=$1
macqueen_binary=$2
module_build=$3
smoke_qml=$4
test_dir=$(mktemp -d)

cleanup()
{
    if [[ -n ${macqueen_pid:-} ]]; then
        kill "$macqueen_pid" 2>/dev/null || true
        wait "$macqueen_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_dir"
}
trap cleanup EXIT

mkdir -m 700 "$test_dir/runtime" "$test_dir/config" "$test_dir/cache" "$test_dir/data"
export XDG_RUNTIME_DIR="$test_dir/runtime"
export XDG_CONFIG_HOME="$test_dir/config"
export XDG_CACHE_HOME="$test_dir/cache"
export XDG_DATA_HOME="$test_dir/data"

env \
    KWIN_COMPOSE=Q \
    QT_PLUGIN_PATH="$repo_root/build/compositor/bin:$repo_root/build/compositor/lib" \
    "$macqueen_binary" \
        --virtual \
        --width 1280 \
        --height 720 \
        --socket macqueen-quickshell-smoke \
        --no-lockscreen \
        --no-global-shortcuts \
        --no-kactivities \
        >"$test_dir/macqueen.log" 2>&1 &
macqueen_pid=$!

for _ in $(seq 1 50); do
    if qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
        org.macqueen.Compositor1.protocolVersion >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

WAYLAND_DISPLAY=macqueen-quickshell-smoke \
QML2_IMPORT_PATH="$module_build" \
QT_NO_XDG_DESKTOP_PORTAL=1 \
timeout 10s quickshell --no-color -p "$smoke_qml"
' _ "$repo_root" "$macqueen_binary" "$module_build" "$smoke_qml"

echo "Macqueen and Quickshell integration smoke test passed."
