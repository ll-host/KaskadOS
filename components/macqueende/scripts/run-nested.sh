#!/usr/bin/env bash

set -euo pipefail

die()
{
    echo "run-nested: $*" >&2
    exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
macqueen="$repo_root/build/compositor/bin/macqueen"
molniya="$repo_root/session/run-molniya-nested"
qml_module="$repo_root/build/quickshell-macqueen"
host_wayland=${WAYLAND_DISPLAY:-}
nested_socket="macqueen-nested-$$"

[[ -n "$host_wayland" ]] ||
    die "WAYLAND_DISPLAY is empty; run this inside KDE Wayland or Hyprland"
[[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR:-} ]] ||
    die "XDG_RUNTIME_DIR is unavailable"
[[ -x "$macqueen" ]] ||
    die "missing $macqueen; build the compositor first"
[[ -x "$molniya" ]] ||
    die "missing $molniya"
[[ -f "$qml_module/Macqueen/Ipc/qmldir" ]] ||
    die "missing the Quickshell Macqueen module; build it first"

export MACQUEENDE_ROOT="$repo_root"
export QT_PLUGIN_PATH="$repo_root/build/compositor/bin:$repo_root/build/compositor/lib${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
export QML2_IMPORT_PATH="$qml_module${QML2_IMPORT_PATH:+:$QML2_IMPORT_PATH}"
export LD_LIBRARY_PATH="$repo_root/build/compositor/bin${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_CURRENT_DESKTOP=MacqueenDE-Nested
export XDG_SESSION_DESKTOP=MacqueenDE-Nested
export QT_QPA_PLATFORM=wayland

echo "Opening MacqueenDE in a 1280x720 window on $host_wayland"
echo "Close the window to stop the nested session."

exec "$macqueen" \
    --wayland-display "$host_wayland" \
    --socket "$nested_socket" \
    --width "${MACQUEEN_NESTED_WIDTH:-1280}" \
    --height "${MACQUEEN_NESTED_HEIGHT:-720}" \
    --xwayland \
    --no-lockscreen \
    --no-global-shortcuts \
    --no-kactivities \
    --exit-with-session "$molniya"
