#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
launcher="$repo_root/start-macqueende"
desktop_file="$repo_root/session/macqueende.desktop"

if [[ ! -x "$repo_root/build/compositor/bin/macqueen" ]]; then
    echo "Missing compositor build. See docs/BUILDING.md." >&2
    exit 1
fi

if [[ ! -f "$repo_root/build/compositor/bin/kwin/plugins/screenshot.so" ]]; then
    echo "Missing Macqueen screenshot plugin. Run:" >&2
    echo "  cmake --build $repo_root/build/compositor --target screenshot" >&2
    exit 1
fi

if [[ ! -f "$repo_root/build/compositor/bin/kwin/plugins/screencast.so" ]]; then
    echo "Missing Macqueen screencast plugin. Run:" >&2
    echo "  cmake --build $repo_root/build/compositor --target screencast" >&2
    exit 1
fi

if [[ ! -f "$repo_root/build/compositor/bin/kwin/plugins/nightlight.so" ]]; then
    echo "Missing Macqueen night light plugin. Run:" >&2
    echo "  cmake --build $repo_root/build/compositor --target nightlight" >&2
    exit 1
fi

if [[ ! -x "$repo_root/shell/MolniyaMacqueenShell/core/bin/dms" ]]; then
    echo "Missing Molniya backend. Run:" >&2
    echo "  make -C $repo_root/shell/MolniyaMacqueenShell/core dev" >&2
    exit 1
fi

if [[ ! -f "$repo_root/build/quickshell-macqueen/Macqueen/Ipc/qmldir" ]]; then
    echo "Missing Quickshell Macqueen module. See docs/BUILDING.md." >&2
    exit 1
fi

if [[ ! -x "$repo_root/build/portal/bin/xdg-desktop-portal-macqueen" ]]; then
    echo "Missing Macqueen portal build. See docs/BUILDING.md." >&2
    exit 1
fi

echo "Installing the MacqueenDE development session..."
sudo install -Dm755 "$launcher" /usr/local/bin/start-macqueende
printf '%s\n' "$repo_root" |
    sudo install -Dm644 /dev/stdin /etc/macqueende/dev-root
sudo install -Dm644 "$desktop_file" \
    /usr/share/wayland-sessions/macqueende.desktop
sudo install -Dm644 "$repo_root/session/macqueende-portals.conf" \
    /usr/share/xdg-desktop-portal/macqueende-portals.conf
sudo install -Dm644 "$repo_root/session/macqueen.portal" \
    /usr/local/share/xdg-desktop-portal/portals/macqueen.portal
sed "s|@MACQUEEN_PORTAL_EXECUTABLE@|$repo_root/build/portal/bin/xdg-desktop-portal-macqueen|g" \
    "$repo_root/session/org.freedesktop.impl.portal.desktop.macqueen.desktop.in" |
    sudo install -Dm644 /dev/stdin \
        /usr/local/share/applications/org.freedesktop.impl.portal.desktop.macqueen.desktop
sed "s|@MACQUEEN_PORTAL_EXECUTABLE@|$repo_root/build/portal/bin/xdg-desktop-portal-macqueen|g" \
    "$repo_root/session/org.freedesktop.impl.portal.desktop.macqueen.service.in" |
    sudo install -Dm644 /dev/stdin \
        /usr/local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.macqueen.service
sed "s|@MACQUEEN_PORTAL_EXECUTABLE@|$repo_root/build/portal/bin/xdg-desktop-portal-macqueen|g" \
    "$repo_root/session/xdg-desktop-portal-macqueen.service.in" |
    sudo install -Dm644 /dev/stdin \
        /usr/local/lib/systemd/user/xdg-desktop-portal-macqueen.service
systemctl --user daemon-reload 2>/dev/null || true

echo "Installed MacqueenDE as an additional Wayland session."
echo "Log out, select MacqueenDE in SDDM, and log in."
echo "To remove it, run: $repo_root/session/uninstall-dev-session.sh"
