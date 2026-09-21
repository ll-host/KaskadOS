pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common

Singleton {
    id: root

    property string username: ""
    property string fullName: ""
    property string profilePicture: ""
    property string hostname: ""
    property bool profileAvailable: false

    function getUserInfo() {
        const command = [
            "sh", "-c",
            "user=${USER:-$(id -un)}; "
            + "full=$(getent passwd \"$user\" | cut -d: -f5 | cut -d, -f1); "
            + "host=$(hostnamectl --static 2>/dev/null || sed -n '1p' /etc/hostname 2>/dev/null); "
            + "printf '%s|%s|%s\\n' \"$user\" \"$full\" \"$host\""
        ];
        Proc.runCommand("userInfo", command, (output, exitCode) => {
            if (exitCode !== 0) {
                root.username = "User";
                root.fullName = "User";
                root.hostname = "System";
                return;
            }
            const parts = output.trim().split("|");
            if (parts.length >= 3) {
                root.username = parts[0] || "";
                root.fullName = parts[1] || parts[0] || "";
                root.hostname = parts[2] || "";
            }
        }, 0);
    }

    Component.onCompleted: getUserInfo()
}
