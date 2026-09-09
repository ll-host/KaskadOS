#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
macqueen_binary="$repo_root/build/compositor/bin/macqueen"

if [[ ! -x "$macqueen_binary" ]]; then
    echo "Missing compositor build: $macqueen_binary" >&2
    exit 1
fi

if ! command -v foot >/dev/null; then
    echo "foot is required for the window IPC smoke test." >&2
    exit 1
fi

echo "Starting the Macqueen window command smoke test..."

dbus-run-session -- bash -c '
set -euo pipefail

repo_root=$1
macqueen_binary=$2
test_dir=$(mktemp -d)

cleanup()
{
    for pid in "${foot_pid:-}" "${macqueen_pid:-}"; do
        if [[ -n $pid ]]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
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
        --socket macqueen-window-smoke \
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

WAYLAND_DISPLAY=macqueen-window-smoke \
    foot --app-id macqueen-ipc-smoke sh -c "sleep 30" >/dev/null 2>&1 &
foot_pid=$!

window_id=
for _ in $(seq 1 50); do
    windows=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
        org.macqueen.Compositor1.windows)
    window_id=$(sed -n "s/^id: //p" <<<"$windows" | head -n 1)
    [[ -n $window_id ]] && break
    sleep 0.1
done
[[ -n $window_id ]]

call()
{
    qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
        "org.macqueen.Compositor1.$1" "${@:2}"
}

call setWindowFullscreen "$window_id" true | grep -q true
sleep 0.2
call windows | grep -q "fullscreen: true"
call setWindowFullscreen "$window_id" false | grep -q true

call setWindowMinimized "$window_id" true | grep -q true
sleep 0.2
call windows | grep -q "minimized: true"
call setWindowMinimized "$window_id" false | grep -q true

second_workspace=$(call createWorkspace 2 "Second")
call moveWindowToWorkspace "$window_id" "$second_workspace" | grep -q true
sleep 0.2
call windows | grep -q "$second_workspace"

call activateWindow "$window_id" | grep -q true
call closeWindow "$window_id" | grep -q true
for _ in $(seq 1 50); do
    kill -0 "$foot_pid" 2>/dev/null || break
    sleep 0.1
done
! kill -0 "$foot_pid" 2>/dev/null
' _ "$repo_root" "$macqueen_binary"

echo "Macqueen window command smoke test passed."
