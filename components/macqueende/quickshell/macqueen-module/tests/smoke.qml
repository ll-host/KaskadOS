import Quickshell
import QtQml
import Macqueen.Ipc 1.0

ShellRoot {
    Timer {
        interval: 100
        running: true

        onTriggered: {
            console.log("Macqueen outputs:", JSON.stringify(Macqueen.outputs))
            console.log("Macqueen workspaces:", JSON.stringify(Macqueen.workspaces))
            if (!Macqueen.available)
                throw new Error("Macqueen IPC is unavailable")
            if (Macqueen.protocolVersion !== 4)
                throw new Error("Unexpected protocol version: " + Macqueen.protocolVersion)
            if (Macqueen.compositorVersion !== "0.1.0-dev")
                throw new Error("Unexpected compositor version: " + Macqueen.compositorVersion)
            if (Macqueen.outputs.length !== 1 || Macqueen.outputs[0].name !== "Virtual-0")
                throw new Error("Virtual output was not exposed")
            if (Macqueen.workspaces.length !== 1 || Macqueen.workspaces[0].name !== "Desktop 1")
                throw new Error("Default workspace was not exposed")
            if (Macqueen.keyboardLayouts.length < 1 || Macqueen.availableKeyboardLayouts.length < 1)
                throw new Error("Keyboard layouts were not exposed")

            const workspaceId = Macqueen.createWorkspace(2, "QML workspace")
            if (!workspaceId || !Macqueen.activateWorkspace(workspaceId))
                throw new Error("Workspace creation or activation failed")
            if (!Macqueen.renameWorkspace(workspaceId, "QML renamed"))
                throw new Error("Workspace rename failed")
            Macqueen.refresh()
            if (Macqueen.workspaces.length !== 2 || !Macqueen.workspaces.some(workspace => workspace.id === workspaceId && workspace.current && workspace.name === "QML renamed"))
                throw new Error("Workspace changes were not reflected in QML")
            if (!Macqueen.removeWorkspace(workspaceId))
                throw new Error("Workspace removal failed")

            console.log("Macqueen QML module smoke test passed")
            Qt.quit()
        }
    }
}
