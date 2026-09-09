import Macqueen.Ipc
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets

Scope {
    id: root

    property bool overviewOpen: false
    property int selectedWindow: -1
    property string selectedWorkspaceId: ""
    property string targetScreenName: ""

    property bool dragActive: false
    property string draggingWindowId: ""
    property string draggingWindowTitle: ""
    property string draggingWindowIcon: ""
    property string dropWorkspaceId: ""

    readonly property var visibleWindows: Macqueen.windows.filter(window => !window.skipTaskbar)
    readonly property var selectedWorkspace: {
        for (const workspace of Macqueen.workspaces) {
            if (workspace.id === selectedWorkspaceId)
                return workspace;
        }
        return Macqueen.workspaces.length > 0 ? Macqueen.workspaces[0] : null;
    }
    readonly property var displayedWindows: {
        if (!selectedWorkspace)
            return [];
        return visibleWindows.filter(window => windowBelongsToWorkspace(window, selectedWorkspace.id));
    }
    readonly property var selectedWindowData: selectedWindow >= 0 && selectedWindow < visibleWindows.length
        ? visibleWindows[selectedWindow]
        : null

    component KeyHint: Row {
        property string keyText: ""
        property string label: ""

        spacing: Theme.spacingXS

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: keyLabel.implicitWidth + Theme.spacingS * 2
            implicitHeight: 24
            radius: 7
            color: Theme.surfaceContainerHighest
            border.width: 1
            border.color: Theme.outline

            StyledText {
                id: keyLabel

                anchors.centerIn: parent
                text: parent.parent.keyText
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.DemiBold
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: parent.label
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    function targetScreen() {
        for (const screen of Quickshell.screens) {
            if (screen.name === targetScreenName)
                return screen;
        }
        return Quickshell.screens.length > 0 ? Quickshell.screens[0] : null;
    }

    function uiText(english, russian) {
        return I18n._lang === "ru" ? russian : english;
    }

    function windowCountText(count) {
        if (I18n._lang === "ru")
            return count + " окн.";
        return count + " " + (count === 1 ? "window" : "windows");
    }

    function currentWorkspaceId() {
        for (const workspace of Macqueen.workspaces) {
            if (workspace.current)
                return workspace.id;
        }
        return Macqueen.workspaces.length > 0 ? Macqueen.workspaces[0].id : "";
    }

    function workspaceIndex(workspaceId) {
        return Macqueen.workspaces.findIndex(workspace => workspace.id === workspaceId);
    }

    function windowBelongsToWorkspace(window, workspaceId) {
        const workspaceIds = window.workspaces || [];
        // KWin reports an empty desktop list for windows pinned to all desktops.
        return workspaceIds.length === 0 || workspaceIds.includes(workspaceId);
    }

    function windowsForWorkspace(workspaceId) {
        return visibleWindows.filter(window => windowBelongsToWorkspace(window, workspaceId));
    }

    function preferredWorkspaceForWindow(window) {
        if (!window)
            return currentWorkspaceId();
        if (selectedWorkspaceId && windowBelongsToWorkspace(window, selectedWorkspaceId))
            return selectedWorkspaceId;
        const workspaceIds = window.workspaces || [];
        for (const workspace of Macqueen.workspaces) {
            if (workspaceIds.includes(workspace.id))
                return workspace.id;
        }
        return currentWorkspaceId();
    }

    function setSelectedWindow(index) {
        if (visibleWindows.length === 0) {
            selectedWindow = -1;
            return;
        }
        selectedWindow = (index + visibleWindows.length) % visibleWindows.length;
        selectedWorkspaceId = preferredWorkspaceForWindow(visibleWindows[selectedWindow]);
    }

    function selectRelative(offset) {
        if (visibleWindows.length === 0) {
            selectedWindow = -1;
            return;
        }
        if (selectedWindow < 0) {
            const activeId = Macqueen.activeWindow && Macqueen.activeWindow.id
                ? Macqueen.activeWindow.id
                : "";
            selectedWindow = visibleWindows.findIndex(window => window.id === activeId);
            if (selectedWindow < 0)
                selectedWindow = 0;
        }
        setSelectedWindow(selectedWindow + offset);
    }

    function selectDisplayedRelative(offset) {
        if (displayedWindows.length === 0) {
            selectedWindow = -1;
            return;
        }
        const selectedId = selectedWindowData && selectedWindowData.id
            ? selectedWindowData.id
            : "";
        let localIndex = displayedWindows.findIndex(window => window.id === selectedId);
        if (localIndex < 0)
            localIndex = offset > 0 ? -1 : 0;
        localIndex = (localIndex + offset + displayedWindows.length) % displayedWindows.length;
        selectedWindow = visibleWindows.findIndex(window => window.id === displayedWindows[localIndex].id);
    }

    function selectWorkspaceRelative(offset) {
        if (Macqueen.workspaces.length === 0)
            return;
        let index = workspaceIndex(selectedWorkspaceId);
        if (index < 0)
            index = 0;
        index = (index + offset + Macqueen.workspaces.length) % Macqueen.workspaces.length;
        selectedWorkspaceId = Macqueen.workspaces[index].id;
        const workspaceWindows = windowsForWorkspace(selectedWorkspaceId);
        if (workspaceWindows.length > 0)
            selectedWindow = visibleWindows.findIndex(window => window.id === workspaceWindows[0].id);
        else
            selectedWindow = -1;
    }

    function selectWorkspace(workspaceId) {
        selectedWorkspaceId = workspaceId;
        if (selectedWindowData && windowBelongsToWorkspace(selectedWindowData, workspaceId))
            return;
        const workspaceWindows = windowsForWorkspace(workspaceId);
        selectedWindow = workspaceWindows.length > 0
            ? visibleWindows.findIndex(window => window.id === workspaceWindows[0].id)
            : -1;
    }

    function open(reason) {
        if (!overviewOpen) {
            Macqueen.refresh();
            targetScreenName = Macqueen.outputAtCursor();
            selectedWorkspaceId = currentWorkspaceId();
            const activeId = Macqueen.activeWindow && Macqueen.activeWindow.id
                ? Macqueen.activeWindow.id
                : "";
            selectedWindow = visibleWindows.findIndex(window => window.id === activeId);
            overviewOpen = true;
        }
        if (reason === "alt-tab")
            selectDisplayedRelative(1);
        else if (reason === "alt-shift-tab")
            selectDisplayedRelative(-1);
    }

    function close(activateSelection) {
        if (activateSelection && selectedWindowData)
            Macqueen.activateWindow(selectedWindowData.id);
        overviewOpen = false;
        endDrag();
    }

    function beginDrag(windowData, sourceItem, mouseX, mouseY) {
        const point = sourceItem.mapToItem(focusScope, 0, 0);
        draggingWindowId = windowData.id;
        draggingWindowTitle = windowData.title || windowData.appId;
        draggingWindowIcon = sourceItem.iconPath || "";
        dragProxy.width = sourceItem.width;
        dragProxy.height = sourceItem.height;
        dragProxy.x = point.x;
        dragProxy.y = point.y;
        dragProxy.dragOffsetX = mouseX;
        dragProxy.dragOffsetY = mouseY;
        dropWorkspaceId = "";
    }

    function endDrag() {
        dragActive = false;
        draggingWindowId = "";
        draggingWindowTitle = "";
        draggingWindowIcon = "";
        dropWorkspaceId = "";
    }

    Connections {
        target: Macqueen

        function onOverviewRequested(reason) {
            if (reason === "screen-edge" && root.overviewOpen)
                root.close(false);
            else
                root.open(reason);
        }

        function onWindowsChanged() {
            if (!root.overviewOpen)
                return;
            if (root.visibleWindows.length === 0) {
                root.selectedWindow = -1;
                return;
            }
            if (root.selectedWindow >= root.visibleWindows.length)
                root.selectedWindow = root.visibleWindows.length - 1;
        }

        function onWorkspacesChanged() {
            if (!root.overviewOpen)
                return;
            if (root.workspaceIndex(root.selectedWorkspaceId) < 0)
                root.selectedWorkspaceId = root.currentWorkspaceId();
        }
    }

    Loader {
        active: root.overviewOpen
        asynchronous: false

        sourceComponent: PanelWindow {
            id: panel

            screen: root.targetScreen()
            visible: root.overviewOpen
            color: "transparent"

            WlrLayershell.namespace: "macqueen:overview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: root.overviewOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

            anchors {
                top: true
                left: true
                right: true
                bottom: true
            }

            Rectangle {
                anchors.fill: parent
                color: Theme.withAlpha("#08070b", 0.48)

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.close(false)
                }
            }

            FocusScope {
                id: focusScope

                anchors.fill: parent
                focus: true

                readonly property int gridColumns: switcher.width >= 1000
                    ? 4
                    : (switcher.width >= 760 ? 3 : 2)

                function workspaceAt(pointX, pointY) {
                    for (let index = 0; index < workspaceRepeater.count; index++) {
                        const workspace = workspaceRepeater.itemAt(index);
                        if (!workspace)
                            continue;
                        const origin = workspace.mapToItem(focusScope, 0, 0);
                        if (pointX >= origin.x && pointX <= origin.x + workspace.width
                                && pointY >= origin.y && pointY <= origin.y + workspace.height)
                            return workspace.modelData.id;
                    }
                    return "";
                }

                Keys.onEscapePressed: event => {
                    root.close(false);
                    event.accepted = true;
                }
                Keys.onReturnPressed: event => {
                    if (root.selectedWindowData)
                        root.close(true);
                    else if (root.selectedWorkspace)
                        Macqueen.activateWorkspace(root.selectedWorkspace.id);
                    event.accepted = true;
                }
                Keys.onEnterPressed: event => {
                    if (root.selectedWindowData)
                        root.close(true);
                    else if (root.selectedWorkspace)
                        Macqueen.activateWorkspace(root.selectedWorkspace.id);
                    event.accepted = true;
                }
                Keys.onTabPressed: event => {
                    root.selectDisplayedRelative((event.modifiers & Qt.ShiftModifier) ? -1 : 1);
                    event.accepted = true;
                }
                Keys.onLeftPressed: event => {
                    root.selectDisplayedRelative(-1);
                    event.accepted = true;
                }
                Keys.onRightPressed: event => {
                    root.selectDisplayedRelative(1);
                    event.accepted = true;
                }
                Keys.onUpPressed: event => {
                    root.selectDisplayedRelative(-focusScope.gridColumns);
                    event.accepted = true;
                }
                Keys.onDownPressed: event => {
                    root.selectDisplayedRelative(focusScope.gridColumns);
                    event.accepted = true;
                }
                Keys.onPressed: event => {
                    if (event.key === Qt.Key_PageUp) {
                        root.selectWorkspaceRelative(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        root.selectWorkspaceRelative(1);
                        event.accepted = true;
                    } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                        const workspaceIndex = event.key - Qt.Key_1;
                        if (workspaceIndex < Macqueen.workspaces.length) {
                            root.selectWorkspace(Macqueen.workspaces[workspaceIndex].id);
                            event.accepted = true;
                        }
                    }
                }
                Keys.onReleased: event => {
                    if (event.key === Qt.Key_Alt) {
                        if (!root.dragActive)
                            root.close(true);
                        event.accepted = true;
                    }
                }

                Component.onCompleted: forceActiveFocus()

                WindowBlur {
                    targetWindow: panel
                    blurX: switcher.x
                    blurY: switcher.y
                    blurWidth: switcher.width
                    blurHeight: switcher.height
                    blurRadius: switcher.radius
                }

                Rectangle {
                    id: switcher

                    readonly property real preferredWidth: root.displayedWindows.length <= 2
                        ? 700
                        : (root.displayedWindows.length <= 6 ? 920 : 1120)

                    anchors.centerIn: parent
                    width: Math.max(520, Math.min(parent.width - Theme.spacingXL * 2, preferredWidth))
                    height: Math.min(parent.height - Theme.spacingXL * 2, contentColumn.implicitHeight + Theme.spacingL * 2)
                    radius: Theme.cornerRadius + 6
                    color: Theme.withAlpha(Theme.surfaceContainer, 0.94)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.outline, 0.9)
                    clip: true

                    MouseArea {
                        anchors.fill: parent
                        onClicked: mouse => {
                            mouse.accepted = true;
                        }
                    }

                    Column {
                        id: contentColumn

                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: Theme.spacingL
                        }
                        spacing: Theme.spacingM

                        Item {
                            width: parent.width
                            height: 48

                            Row {
                                anchors {
                                    left: parent.left
                                    verticalCenter: parent.verticalCenter
                                }
                                spacing: Theme.spacingM

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 42
                                    height: 42
                                    radius: 12
                                    color: Theme.primaryContainer

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "overview"
                                        size: 24
                                        color: Theme.primary
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1

                                    StyledText {
                                        text: root.uiText("Window switcher", "Переключатель окон")
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeXLarge
                                        font.weight: Font.DemiBold
                                    }

                                    StyledText {
                                        text: {
                                            const workspaceName = root.selectedWorkspace && root.selectedWorkspace.name
                                                ? root.selectedWorkspace.name
                                                : root.uiText("Workspace", "Рабочий стол");
                                            const count = root.displayedWindows.length;
                                            return workspaceName + "  •  " + root.windowCountText(count);
                                        }
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            Rectangle {
                                anchors {
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                }
                                implicitWidth: outputLabel.implicitWidth + Theme.spacingM * 2
                                height: 30
                                radius: 10
                                color: Theme.surfaceContainerHigh
                                border.width: 1
                                border.color: Theme.outline

                                StyledText {
                                    id: outputLabel

                                    anchors.centerIn: parent
                                    text: root.targetScreenName || root.uiText("Current display", "Текущий монитор")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                }
                            }
                        }

                        Flickable {
                            id: workspaceViewport

                            width: parent.width
                            height: 54
                            contentWidth: workspaceRow.implicitWidth
                            contentHeight: height
                            clip: true
                            interactive: contentWidth > width
                            boundsBehavior: Flickable.StopAtBounds

                            Row {
                                id: workspaceRow

                                height: parent.height
                                spacing: Theme.spacingS

                                Repeater {
                                    id: workspaceRepeater

                                    model: Macqueen.workspaces

                                    delegate: Rectangle {
                                        id: workspaceChip

                                        required property var modelData
                                        readonly property bool selected: modelData.id === root.selectedWorkspaceId
                                        readonly property bool dropTarget: modelData.id === root.dropWorkspaceId
                                        readonly property int windowCount: root.windowsForWorkspace(modelData.id).length

                                        width: Math.max(150, Math.min(210, workspaceViewport.width / Math.max(1, Math.min(4, Macqueen.workspaces.length)) - Theme.spacingS))
                                        height: 50
                                        radius: 14
                                        color: dropTarget
                                            ? Theme.primaryContainer
                                            : (selected ? Theme.primaryContainer : Theme.surfaceContainerHigh)
                                        border.width: selected || dropTarget ? 2 : 1
                                        border.color: selected || dropTarget ? Theme.primary : Theme.outline

                                        MouseArea {
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                Macqueen.activateWorkspace(workspaceChip.modelData.id);
                                                root.close(false);
                                            }
                                        }

                                        Row {
                                            anchors {
                                                fill: parent
                                                margins: Theme.spacingS
                                            }
                                            spacing: Theme.spacingS

                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 30
                                                height: 30
                                                radius: 9
                                                color: workspaceChip.selected ? Theme.primary : Theme.surfaceContainerHighest

                                                StyledText {
                                                    anchors.centerIn: parent
                                                    text: workspaceChip.modelData.position
                                                    color: workspaceChip.selected ? Theme.onPrimary : Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Bold
                                                }
                                            }

                                            Column {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: workspaceChip.width - 82
                                                spacing: 1

                                                StyledText {
                                                    width: parent.width
                                                    text: workspaceChip.modelData.name || root.uiText("Workspace", "Рабочий стол") + " " + workspaceChip.modelData.position
                                                    color: workspaceChip.selected ? Theme.primary : Theme.surfaceText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.DemiBold
                                                    wrapMode: Text.NoWrap
                                                    elide: Text.ElideRight
                                                }

                                                StyledText {
                                                    width: parent.width
                                                    text: workspaceChip.dropTarget
                                                        ? root.uiText("Release to move", "Отпустите — переместить")
                                                        : (workspaceChip.modelData.current
                                                            ? root.uiText("Current workspace", "Текущий стол")
                                                            : root.windowCountText(workspaceChip.windowCount))
                                                    color: Theme.surfaceVariantText
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    wrapMode: Text.NoWrap
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Rectangle {
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: 8
                                                height: 8
                                                radius: 4
                                                color: workspaceChip.modelData.current ? Theme.primary : "transparent"
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outline
                            opacity: 0.65
                        }

                        Item {
                            width: parent.width
                            height: 34

                            Row {
                                anchors {
                                    left: parent.left
                                    verticalCenter: parent.verticalCenter
                                }
                                spacing: Theme.spacingS

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.uiText("Windows", "Окна")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                }

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: countLabel.implicitWidth + Theme.spacingS * 2
                                    height: 22
                                    radius: 8
                                    color: Theme.surfaceContainerHighest

                                    StyledText {
                                        id: countLabel

                                        anchors.centerIn: parent
                                        text: root.displayedWindows.length
                                        color: Theme.surfaceVariantText
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            Rectangle {
                                id: switchWorkspaceButton

                                anchors {
                                    right: parent.right
                                    verticalCenter: parent.verticalCenter
                                }
                                visible: root.selectedWorkspace && !root.selectedWorkspace.current
                                implicitWidth: switchWorkspaceLabel.implicitWidth + Theme.spacingL * 2
                                height: 32
                                radius: 10
                                color: switchWorkspaceMouse.containsMouse ? Theme.primary : Theme.primaryContainer

                                StyledText {
                                    id: switchWorkspaceLabel

                                    anchors.centerIn: parent
                                    text: root.uiText("Open workspace", "Перейти на стол")
                                    color: switchWorkspaceMouse.containsMouse ? Theme.onPrimary : Theme.primary
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                }

                                MouseArea {
                                    id: switchWorkspaceMouse

                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Macqueen.activateWorkspace(root.selectedWorkspace.id);
                                        root.close(false);
                                    }
                                }
                            }
                        }

                        Item {
                            id: windowArea

                            width: parent.width
                            height: Math.max(92, Math.min(windowGrid.implicitHeight, focusScope.height - 285))

                            Flickable {
                                id: windowViewport

                                anchors.fill: parent
                                contentWidth: width
                                contentHeight: windowGrid.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                Grid {
                                    id: windowGrid

                                    width: windowViewport.width
                                    columns: focusScope.gridColumns
                                    spacing: Theme.spacingS

                                    Repeater {
                                        model: root.displayedWindows

                                        delegate: Rectangle {
                                            id: windowCard

                                            required property var modelData
                                            property bool dragOccurred: false
                                            readonly property int globalIndex: root.visibleWindows.findIndex(window => window.id === modelData.id)
                                            readonly property bool selected: globalIndex === root.selectedWindow
                                            readonly property var entry: DesktopEntries.heuristicLookup(Paths.moddedAppId(modelData.appId || ""))
                                            readonly property string iconPath: Paths.getAppIcon(modelData.appId || "", entry) || Quickshell.iconPath("application-x-executable", "image-missing")

                                            width: (windowGrid.width - windowGrid.spacing * (windowGrid.columns - 1)) / windowGrid.columns
                                            height: 78
                                            radius: 14
                                            color: selected
                                                ? Theme.primaryContainer
                                                : (windowCardMouse.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)
                                            border.width: selected ? 2 : 1
                                            border.color: selected ? Theme.primary : Theme.outline
                                            opacity: modelData.minimized && !selected ? 0.72 : 1

                                            Behavior on color {
                                                ColorAnimation {
                                                    duration: 100
                                                }
                                            }

                                            Rectangle {
                                                anchors {
                                                    left: parent.left
                                                    top: parent.top
                                                    bottom: parent.bottom
                                                    leftMargin: 5
                                                    topMargin: 12
                                                    bottomMargin: 12
                                                }
                                                width: 4
                                                radius: 2
                                                color: windowCard.selected ? Theme.primary : "transparent"
                                            }

                                            Row {
                                                z: 1
                                                anchors {
                                                    fill: parent
                                                    margins: Theme.spacingM
                                                    leftMargin: Theme.spacingM + 4
                                                }
                                                spacing: Theme.spacingM

                                                Rectangle {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 42
                                                    height: 42
                                                    radius: 11
                                                    color: Theme.surfaceContainerHighest

                                                    Image {
                                                        anchors.centerIn: parent
                                                        width: 30
                                                        height: 30
                                                        source: windowCard.iconPath
                                                        sourceSize: Qt.size(30, 30)
                                                        fillMode: Image.PreserveAspectFit
                                                    }
                                                }

                                                Column {
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: parent.width - 42 - closeWindowButton.width - parent.spacing * 2
                                                    spacing: 3

                                                    StyledText {
                                                        width: parent.width
                                                        text: windowCard.modelData.title || windowCard.modelData.appId || root.uiText("Untitled window", "Окно без названия")
                                                        color: Theme.surfaceText
                                                        font.pixelSize: Theme.fontSizeMedium
                                                        font.weight: Font.DemiBold
                                                        wrapMode: Text.NoWrap
                                                        maximumLineCount: 1
                                                        elide: Text.ElideRight
                                                    }

                                                    StyledText {
                                                        width: parent.width
                                                        text: {
                                                            let detail = windowCard.modelData.appId || root.uiText("Application", "Приложение");
                                                            if (windowCard.modelData.output && windowCard.modelData.output !== root.targetScreenName)
                                                                detail += "  •  " + windowCard.modelData.output;
                                                            if (windowCard.modelData.minimized)
                                                                detail += "  •  " + root.uiText("Minimized", "Свёрнуто");
                                                            return detail;
                                                        }
                                                        color: Theme.surfaceVariantText
                                                        font.pixelSize: Theme.fontSizeSmall
                                                        wrapMode: Text.NoWrap
                                                        maximumLineCount: 1
                                                        elide: Text.ElideRight
                                                    }
                                                }

                                                Rectangle {
                                                    id: closeWindowButton

                                                    anchors.verticalCenter: parent.verticalCenter
                                                    width: 28
                                                    height: 28
                                                    radius: 9
                                                    color: closeWindowMouse.containsMouse ? Theme.errorContainer : "transparent"
                                                    opacity: windowCardMouse.containsMouse || windowCard.selected ? 1 : 0
                                                    visible: windowCard.modelData.closeable

                                                    DankIcon {
                                                        anchors.centerIn: parent
                                                        name: "close"
                                                        size: 16
                                                        color: closeWindowMouse.containsMouse ? Theme.error : Theme.surfaceVariantText
                                                    }

                                                    MouseArea {
                                                        id: closeWindowMouse

                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: mouse => {
                                                            Macqueen.closeWindow(windowCard.modelData.id);
                                                            mouse.accepted = true;
                                                        }
                                                    }
                                                }
                                            }

                                            MouseArea {
                                                id: windowCardMouse

                                                anchors.fill: parent
                                                z: 0
                                                hoverEnabled: true
                                                cursorShape: root.dragActive ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                                                onContainsMouseChanged: {
                                                    if (containsMouse && !root.dragActive)
                                                        root.selectedWindow = windowCard.globalIndex;
                                                }
                                                onPressed: windowCard.dragOccurred = false
                                                onClicked: {
                                                    if (windowCard.dragOccurred)
                                                        return;
                                                    root.selectedWindow = windowCard.globalIndex;
                                                    root.close(true);
                                                }
                                            }

                                            DragHandler {
                                                id: windowDragHandler

                                                property bool gestureStarted: false
                                                property string draggedWindowId: ""
                                                property string targetWorkspaceId: ""

                                                target: null
                                                acceptedButtons: Qt.LeftButton

                                                function updatePosition() {
                                                    const point = windowCard.mapToItem(
                                                        focusScope,
                                                        centroid.position.x,
                                                        centroid.position.y
                                                    );
                                                    dragProxy.x = Math.max(Theme.spacingS, Math.min(
                                                        focusScope.width - dragProxy.width - Theme.spacingS,
                                                        point.x - dragProxy.dragOffsetX
                                                    ));
                                                    dragProxy.y = Math.max(Theme.spacingS, Math.min(
                                                        focusScope.height - dragProxy.height - Theme.spacingS,
                                                        point.y - dragProxy.dragOffsetY
                                                    ));
                                                    targetWorkspaceId = focusScope.workspaceAt(point.x, point.y);
                                                    root.dropWorkspaceId = targetWorkspaceId;
                                                }

                                                onActiveChanged: {
                                                    if (active) {
                                                        gestureStarted = true;
                                                        draggedWindowId = windowCard.modelData.id || "";
                                                        targetWorkspaceId = "";
                                                        windowCard.dragOccurred = true;
                                                        root.beginDrag(
                                                            windowCard.modelData,
                                                            windowCard,
                                                            windowCard.width / 2,
                                                            windowCard.height / 2
                                                        );
                                                        root.dragActive = true;
                                                        updatePosition();
                                                    } else if (gestureStarted) {
                                                        gestureStarted = false;
                                                        const windowId = draggedWindowId;
                                                        const workspaceId = targetWorkspaceId;
                                                        draggedWindowId = "";
                                                        targetWorkspaceId = "";
                                                        root.endDrag();
                                                        if (windowId !== "" && workspaceId !== "") {
                                                            const moved = Macqueen.moveWindowToWorkspace(windowId, workspaceId);
                                                            console.info("MacqueenOverview: move window", windowId, "to", workspaceId, "result:", moved);
                                                            if (moved) {
                                                                root.selectedWorkspaceId = workspaceId;
                                                                root.selectedWindow = root.visibleWindows.findIndex(window => window.id === windowId);
                                                            }
                                                        }
                                                    }
                                                }
                                                onCentroidChanged: {
                                                    if (active)
                                                        updatePosition();
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                visible: root.displayedWindows.length === 0
                                spacing: Theme.spacingS

                                DankIcon {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    name: "view-grid"
                                    size: 32
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.uiText("No windows on this workspace", "На этом рабочем столе нет окон")
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                }

                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: root.uiText("Choose another workspace above", "Выберите другой рабочий стол сверху")
                                    color: Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                }
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outline
                            opacity: 0.65
                        }

                        Column {
                            width: parent.width
                            spacing: Theme.spacingS

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: root.uiText(
                                    "Click a window to open • drag it onto a workspace to move",
                                    "Нажмите окно — открыть • перетащите на рабочий стол — переместить"
                                )
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Theme.spacingL

                                KeyHint {
                                    keyText: "Alt + Tab"
                                    label: root.uiText("next", "листать")
                                }

                                KeyHint {
                                    keyText: "← ↑ ↓ →"
                                    label: root.uiText("navigate", "выбор")
                                }

                                KeyHint {
                                    keyText: "PgUp / PgDn"
                                    label: root.uiText("workspace", "столы")
                                }

                                KeyHint {
                                    keyText: "Enter"
                                    label: root.uiText("open", "открыть")
                                }

                                KeyHint {
                                    keyText: "Esc"
                                    label: root.uiText("close", "закрыть")
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: dragProxy

                    property real dragOffsetX: 0
                    property real dragOffsetY: 0

                    visible: root.dragActive
                    z: 1000
                    radius: 14
                    color: Theme.primaryContainer
                    border.width: 2
                    border.color: Theme.primary
                    opacity: 0.94

                    Row {
                        anchors {
                            fill: parent
                            margins: Theme.spacingM
                        }
                        spacing: Theme.spacingM

                        Image {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 32
                            height: 32
                            source: root.draggingWindowIcon
                            sourceSize: Qt.size(32, 32)
                            fillMode: Image.PreserveAspectFit
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 44
                            text: root.draggingWindowTitle
                            color: Theme.surfaceText
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
