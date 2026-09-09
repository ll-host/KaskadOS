pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

FocusScope {
    id: root

    property string query: ""
    property bool showRuntimes: false
    property int selectedIndex: 0
    signal executableRequested

    readonly property var filteredApps: {
        const needle = query.trim().toLowerCase();
        if (needle.length === 0)
            return WindowsAppsService.apps || [];
        return (WindowsAppsService.apps || []).filter(app => (app.name || "").toLowerCase().includes(needle));
    }

    Component.onCompleted: WindowsAppsService.refresh()

    ConfirmModal {
        id: removeConfirm
    }

    ConfirmModal {
        id: removeRuntimeConfirm
    }

    function confirmRemove(app) {
        removeConfirm.showWithOptions({
            "title": "Удалить " + app.name + "?",
            "message": "Приложение исчезнет из меню. Его отдельный профиль, данные и связанные с этим профилем пункты также будут удалены.",
            "confirmText": "Удалить",
            "cancelText": "Отмена",
            "confirmColor": Theme.error,
            "onConfirm": () => WindowsAppsService.remove(app, true)
        });
    }

    function confirmRemoveRuntime(runtime) {
        removeRuntimeConfirm.showWithOptions({
            "title": "Удалить " + runtime.tag + "?",
            "message": "Версия Proton будет удалена. Это возможно только если она не выбрана ни для одного приложения.",
            "confirmText": "Удалить",
            "cancelText": "Отмена",
            "confirmColor": Theme.error,
            "onConfirm": () => WindowsAppsService.removeRuntime(runtime)
        });
    }

    function selectNext() {
        const count = showRuntimes ? WindowsAppsService.runtimeCatalog.length : filteredApps.length;
        if (count > 0)
            selectedIndex = Math.min(count - 1, selectedIndex + 1);
        contentList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function selectPrevious() {
        if (selectedIndex > 0)
            selectedIndex--;
        contentList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function activateSelected() {
        if (showRuntimes) {
            const release = WindowsAppsService.runtimeCatalog[selectedIndex];
            if (release && !release.installed)
                WindowsAppsService.installRuntime(release);
            return;
        }
        const app = filteredApps[selectedIndex];
        if (app)
            WindowsAppsService.launch(app);
    }

    Column {
        anchors.fill: parent
        spacing: Theme.spacingS

        Rectangle {
            width: parent.width
            height: (WindowsAppsService.busy || WindowsAppsService.appRunning || WindowsAppsService.state?.phase === "error") ? 58 : 0
            visible: height > 0
            radius: Theme.cornerRadius
            color: Theme.primaryContainer
            clip: true

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 4

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: WindowsAppsService.state?.phase === "error" ? "error"
                            : WindowsAppsService.state?.phase === "running" ? "sports_esports" : "hourglass_top"
                        size: 20
                        color: WindowsAppsService.state?.phase === "error" ? Theme.error : Theme.onPrimaryContainer
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - 64
                        text: WindowsAppsService.state?.message || "Подготовка"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.onPrimaryContainer
                        elide: Text.ElideRight
                    }

                    DankActionButton {
                        visible: WindowsAppsService.busy || (WindowsAppsService.state?.phase === "error" && WindowsAppsService.state?.logPath)
                        buttonSize: 30
                        iconName: WindowsAppsService.state?.phase === "error" ? "folder_open" : "close"
                        iconColor: Theme.onPrimaryContainer
                        backgroundColor: "transparent"
                        tooltipText: WindowsAppsService.state?.phase === "error" ? "Открыть папку журнала" : "Отменить"
                        onClicked: {
                            if (WindowsAppsService.state?.phase !== "error") {
                                WindowsAppsService.cancel();
                                return;
                            }
                            const path = String(WindowsAppsService.state?.logPath || "");
                            const slash = path.lastIndexOf("/");
                            if (slash > 0)
                                FileManagerService.openWindow(path.substring(0, slash));
                        }
                    }
                }

                M3WaveProgress {
                    width: parent.width
                    height: 14
                    value: WindowsAppsService.state?.progress > 0 ? WindowsAppsService.state.progress / 100 : 0.45
                    actualValue: value
                    visible: WindowsAppsService.state?.phase !== "error"
                    isPlaying: WindowsAppsService.busy
                    amp: 1.2
                    lineWidth: 2
                    wavelength: 18
                }
            }
        }

        Row {
            width: parent.width
            height: 36
            spacing: Theme.spacingS

            DankButton {
                id: openExecutableButton
                text: "Открыть EXE"
                iconName: "folder_open"
                backgroundColor: Theme.primary
                textColor: Theme.primaryText
                enabled: !WindowsAppsService.busy && WindowsAppsService.runtimes.length > 0
                onClicked: {
                    WindowsAppsService.preferredRuntimeTag = runtimeSelector.currentValue;
                    root.executableRequested();
                }
            }

            DankDropdown {
                id: runtimeSelector
                visible: !root.showRuntimes
                width: visible ? Math.max(120, parent.width - openExecutableButton.width - runtimeModeButton.width - Theme.spacingS * 2) : 0
                compactMode: true
                options: WindowsAppsService.runtimeTags
                currentValue: WindowsAppsService.preferredRuntimeTag
                onValueChanged: value => {
                    if (value)
                        WindowsAppsService.preferredRuntimeTag = value;
                }
            }

            DankButton {
                id: runtimeModeButton
                text: root.showRuntimes ? "Мои приложения" : "Версии Proton"
                iconName: root.showRuntimes ? "apps" : "deployed_code_update"
                backgroundColor: Theme.surfaceContainerHighest
                textColor: Theme.surfaceText
                onClicked: {
                    root.showRuntimes = !root.showRuntimes;
                    root.selectedIndex = 0;
                    if (root.showRuntimes && WindowsAppsService.releases.length === 0)
                        WindowsAppsService.loadReleases();
                }
            }

        }

        ListView {
            id: contentList
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Theme.spacingXXS
            model: root.showRuntimes ? WindowsAppsService.runtimeCatalog : root.filteredApps

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index

                width: contentList.width
                height: 64
                radius: Theme.cornerRadius
                color: root.selectedIndex === index ? Theme.primaryPressed
                    : rowArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = row.index
                    onDoubleClicked: root.activateSelected()
                }

                Rectangle {
                    id: iconBox
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest

                    DankIcon {
                        anchors.centerIn: parent
                        name: root.showRuntimes ? "deployed_code" : "window"
                        size: 23
                        color: Theme.primary
                    }
                }

                Column {
                    anchors.left: iconBox.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.right: actions.left
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: root.showRuntimes ? row.modelData.tag : row.modelData.name
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: root.showRuntimes
                            ? (row.modelData.installed
                                ? (row.modelData.managed ? "Установлен KaskadOS" : "Установлен из внешнего источника")
                                : "Доступен для загрузки")
                            : ("GE-Proton " + row.modelData.runtimeTag)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                Row {
                    id: actions
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXS

                    DankDropdown {
                        visible: !root.showRuntimes
                        width: visible ? 132 : 0
                        compactMode: true
                        options: WindowsAppsService.runtimeTags
                        currentValue: root.showRuntimes ? "" : row.modelData.runtimeTag
                        onValueChanged: value => {
                            if (!root.showRuntimes && value && value !== row.modelData.runtimeTag)
                                WindowsAppsService.setRuntime(row.modelData, value);
                        }
                    }

                    DankActionButton {
                        visible: !root.showRuntimes
                        buttonSize: 36
                        iconName: "delete"
                        iconColor: Theme.error
                        backgroundColor: Theme.withAlpha(Theme.error, 0.1)
                        tooltipText: "Убрать приложение и его профиль"
                        onClicked: root.confirmRemove(row.modelData)
                    }

                    DankActionButton {
                        visible: root.showRuntimes && row.modelData.installed && row.modelData.managed
                        buttonSize: 36
                        iconName: "delete"
                        iconColor: Theme.error
                        backgroundColor: Theme.withAlpha(Theme.error, 0.1)
                        enabled: !WindowsAppsService.busy
                        tooltipText: "Удалить версию Proton"
                        onClicked: root.confirmRemoveRuntime(row.modelData)
                    }

                    DankActionButton {
                        buttonSize: 36
                        iconName: root.showRuntimes
                            ? (row.modelData.installed ? "check" : "download")
                            : "play_arrow"
                        iconColor: Theme.onPrimary
                        backgroundColor: row.modelData.installed && root.showRuntimes
                            ? Theme.surfaceContainerHighest : Theme.primary
                        enabled: !(row.modelData.installed && root.showRuntimes) && !WindowsAppsService.busy
                        tooltipText: root.showRuntimes
                            ? (row.modelData.installed ? "Версия установлена" : "Установить версию")
                            : "Запустить"
                        onClicked: {
                            root.selectedIndex = row.index;
                            root.activateSelected();
                        }
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: contentList.count === 0
                text: root.showRuntimes
                    ? (WindowsAppsService.loading ? "Загружаю список версий…" : "Версии Proton не найдены")
                    : "Windows-приложений пока нет"
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }
        }
    }
}
