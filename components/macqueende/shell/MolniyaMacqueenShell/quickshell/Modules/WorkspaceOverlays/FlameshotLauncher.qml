/*
    SPDX-License-Identifier: GPL-3.0-or-later
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
*/

import Macqueen.Ipc
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Scope {
    id: root

    function openFlameshot() {
        if (captureProcess.running)
            return;
        PopoutManager.closeAllPopouts();
        PopoutManager.screenshotActive = true;
        captureProcess.running = true;
    }

    Connections {
        target: Macqueen

        function onScreenshotRequested() {
            root.openFlameshot();
        }
    }

    IpcHandler {
        target: "flameshot"

        function capture(): string {
            root.openFlameshot();
            return "FLAMESHOT_STARTED";
        }
    }

    Process {
        id: captureProcess
        command: ["flameshot", "gui"]
        running: false

        onExited: (exitCode, exitStatus) => {
            PopoutManager.screenshotActive = false;
        }
    }
}
