pragma Singleton

import QtQuick
import Quickshell
import Macqueen.Ipc 1.0
import qs.Services

Singleton {
    id: root

    readonly property bool ready: CompositorService.isMacqueen && Macqueen.available
    property bool operationPending: false

    function scheduleSync() {
        if (ready)
            syncTimer.restart();
    }

    function workspaceHasWindow(workspaceId) {
        const windows = Array.from(Macqueen.windows || []);
        return windows.some(window => {
            if (!window || window.skipTaskbar)
                return false;
            return Array.from(window.workspaces || []).includes(workspaceId);
        });
    }

    function sortedWorkspaces() {
        return Array.from(Macqueen.workspaces || []).sort((a, b) => a.position - b.position);
    }

    function sync() {
        if (!ready || operationPending)
            return;

        const workspaces = sortedWorkspaces();
        if (workspaces.length === 0)
            return;

        const last = workspaces[workspaces.length - 1];
        const lastIsOccupied = workspaceHasWindow(last.id);

        // GNOME-style invariant: every used/current workspace is followed by
        // exactly one empty workspace ready for the next task.
        if (lastIsOccupied || last.current) {
            operationPending = true;
            Macqueen.createWorkspace(workspaces.length + 1, "Рабочий стол " + (workspaces.length + 1));
            operationCooldown.restart();
            return;
        }

        if (workspaces.length > 1) {
            const previous = workspaces[workspaces.length - 2];
            if (!workspaceHasWindow(previous.id) && !previous.current) {
                operationPending = true;
                Macqueen.removeWorkspace(last.id);
                operationCooldown.restart();
            }
        }
    }

    Timer {
        id: syncTimer
        interval: 180
        repeat: false
        onTriggered: root.sync()
    }

    Timer {
        id: operationCooldown
        interval: 180
        repeat: false
        onTriggered: {
            root.operationPending = false;
            root.scheduleSync();
        }
    }

    Connections {
        target: Macqueen

        function onWorkspacesChanged() {
            root.scheduleSync();
        }

        function onWindowsChanged() {
            root.scheduleSync();
        }
    }

    Component.onCompleted: scheduleSync()
    onReadyChanged: scheduleSync()
}
