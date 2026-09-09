#!/usr/bin/env bash

set -euo pipefail

payload_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_root="$payload_root/opt/macqueende"

[[ -x "$source_root/build/compositor/bin/macqueen" ]] || {
    echo "Invalid MacqueenDE release payload." >&2
    exit 1
}
[[ -f "$source_root/build/compositor/bin/kwin/plugins/screencast.so" ]] || {
    echo "Invalid MacqueenDE release payload: screencast plugin is missing." >&2
    exit 1
}
[[ -f "$source_root/build/compositor/bin/kwin/plugins/nightlight.so" ]] || {
    echo "Invalid MacqueenDE release payload: night light plugin is missing." >&2
    exit 1
}
[[ -x "$source_root/installer/macqueende-manager" ]] || {
    echo "Invalid MacqueenDE release payload: manager is missing." >&2
    exit 1
}

sudo install -d /opt
new_root="/opt/macqueende.new.$$"
sudo cp -a "$source_root" "$new_root"

install_method=${MACQUEENDE_INSTALL_METHOD:-binary}
install_version=${MACQUEENDE_INSTALL_VERSION:-$(cat "$source_root/VERSION")}
source_commit=${MACQUEENDE_SOURCE_COMMIT:-}
build_packages=${MACQUEENDE_BUILD_PACKAGES:-}
managed_flameshot=${MACQUEENDE_MANAGED_FLAMESHOT:-0}
{
    printf 'METHOD=%s\n' "$install_method"
    printf 'VERSION=%s\n' "$install_version"
    printf 'SOURCE_COMMIT=%s\n' "$source_commit"
    printf 'BUILD_PACKAGES=%s\n' "$build_packages"
    printf 'MANAGED_FLAMESHOT=%s\n' "$managed_flameshot"
    printf 'INSTALLED_AT=%s\n' "$(date --iso-8601=seconds)"
} | sudo tee "$new_root/INSTALL_INFO" >/dev/null

if [[ -e /opt/macqueende ]]; then
    backup_root="/opt/macqueende.previous.$(date +%Y%m%d-%H%M%S)"
    sudo mv /opt/macqueende "$backup_root"
fi
sudo mv "$new_root" /opt/macqueende

{
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'export MACQUEENDE_ROOT=/opt/macqueende'
    printf '%s\n' 'exec /opt/macqueende/start-macqueende "$@"'
} | sudo install -Dm755 /dev/stdin /usr/bin/start-macqueende
sudo install -Dm755 /opt/macqueende/installer/macqueende-manager \
    /usr/bin/macqueende-manager
sed 's|Exec=/usr/local/bin/start-macqueende|Exec=/usr/bin/start-macqueende|' \
    /opt/macqueende/session/macqueende.desktop |
    sudo install -Dm644 /dev/stdin /usr/share/wayland-sessions/macqueende.desktop
sudo install -Dm644 /opt/macqueende/session/macqueende-portals.conf \
    /usr/share/xdg-desktop-portal/macqueende-portals.conf
sudo install -Dm644 /opt/macqueende/session/macqueen.portal \
    /usr/share/xdg-desktop-portal/portals/macqueen.portal
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
    /opt/macqueende/session/org.freedesktop.impl.portal.desktop.macqueen.desktop.in |
    sudo install -Dm644 /dev/stdin \
        /usr/share/applications/org.freedesktop.impl.portal.desktop.macqueen.desktop
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
    /opt/macqueende/session/org.freedesktop.impl.portal.desktop.macqueen.service.in |
    sudo install -Dm644 /dev/stdin \
        /usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.macqueen.service
sed 's|@MACQUEEN_PORTAL_EXECUTABLE@|/opt/macqueende/build/portal/bin/xdg-desktop-portal-macqueen|g' \
    /opt/macqueende/session/xdg-desktop-portal-macqueen.service.in |
    sudo install -Dm644 /dev/stdin \
        /usr/lib/systemd/user/xdg-desktop-portal-macqueen.service
systemctl --user daemon-reload 2>/dev/null || true

echo "MacqueenDE installed. Log out and select MacqueenDE in SDDM."
echo "Manage it later with: macqueende-manager"
[[ -z ${backup_root:-} ]] ||
    echo "Previous installation kept at $backup_root."
