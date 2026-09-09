#!/usr/bin/env bash

set -euo pipefail

systemctl --user stop xdg-desktop-portal-macqueen.service 2>/dev/null || true
sudo rm -f \
    /usr/local/bin/start-macqueende \
    /usr/share/wayland-sessions/macqueende.desktop \
    /usr/share/xdg-desktop-portal/macqueende-portals.conf \
    /usr/local/lib/systemd/user/xdg-desktop-portal-macqueen.service \
    /usr/local/share/applications/org.freedesktop.impl.portal.desktop.macqueen.desktop \
    /usr/local/share/dbus-1/services/org.freedesktop.impl.portal.desktop.macqueen.service \
    /usr/local/share/xdg-desktop-portal/portals/macqueen.portal \
    /etc/macqueende/dev-root

sudo rmdir /etc/macqueende 2>/dev/null || true
systemctl --user daemon-reload 2>/dev/null || true

echo "Removed the MacqueenDE development session."
