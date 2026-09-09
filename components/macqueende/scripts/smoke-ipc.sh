#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
macqueen_binary="$repo_root/build/compositor/bin/macqueen"

if [[ ! -x "$macqueen_binary" ]]; then
    echo "Missing compositor build: $macqueen_binary" >&2
    exit 1
fi

if ! command -v qdbus6 >/dev/null; then
    echo "qdbus6 is required for the IPC smoke test." >&2
    exit 1
fi

echo "Starting Macqueen in an isolated D-Bus session..."

dbus-run-session -- bash -c '
set -euo pipefail

repo_root=$1
macqueen_binary=$2
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

env \
    XDG_RUNTIME_DIR="$test_dir/runtime" \
    XDG_CONFIG_HOME="$test_dir/config" \
    XDG_CACHE_HOME="$test_dir/cache" \
    XDG_DATA_HOME="$test_dir/data" \
    KWIN_COMPOSE=Q \
    QT_PLUGIN_PATH="$repo_root/build/compositor/bin:$repo_root/build/compositor/lib" \
    "$macqueen_binary" \
        --virtual \
        --width 1280 \
        --height 720 \
        --socket macqueen-ipc-smoke \
        --no-lockscreen \
        --no-global-shortcuts \
        --no-kactivities \
        >"$test_dir/macqueen.log" 2>&1 &
macqueen_pid=$!

for _ in $(seq 1 50); do
    version=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
        org.macqueen.Compositor1.protocolVersion 2>/dev/null || true)
    if [[ $version == 3 ]]; then
        break
    fi
    sleep 0.1
done

if [[ ${version:-} != 3 ]]; then
    cat "$test_dir/macqueen.log" >&2
    echo "Macqueen IPC did not become ready." >&2
    exit 1
fi

compositor_version=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.compositorVersion)
outputs=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.outputs)
workspaces=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.workspaces)

[[ $compositor_version == 0.1.0-dev ]]
grep -q "name: Virtual-0" <<<"$outputs"
grep -q "width: 1280" <<<"$outputs"
grep -q "height: 720" <<<"$outputs"
grep -q "name: Desktop 1" <<<"$workspaces"

default_layouts=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.keyboardLayouts)
grep -q "code: us" <<<"$default_layouts"

gdbus call --session \
    --dest org.macqueen.Compositor1 \
    --object-path /org/macqueen/Compositor1 \
    --method org.macqueen.Compositor1.setKeyboardLayouts \
    "[\"us\", \"ru\"]" | grep -q true

layouts=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.keyboardLayouts)
grep -q "code: us" <<<"$layouts"
grep -q "code: ru" <<<"$layouts"

second_workspace=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.createWorkspace 2 "Second")
[[ -n $second_workspace ]]

qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.activateWorkspace "$second_workspace" | grep -q true
qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.renameWorkspace "$second_workspace" "Renamed" | grep -q true

workspaces=$(qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.workspaces)
grep -q "name: Renamed" <<<"$workspaces"

qdbus6 org.macqueen.Compositor1 /org/macqueen/Compositor1 \
    org.macqueen.Compositor1.removeWorkspace "$second_workspace" | grep -q true
' _ "$repo_root" "$macqueen_binary"

echo "Macqueen IPC smoke test passed."
