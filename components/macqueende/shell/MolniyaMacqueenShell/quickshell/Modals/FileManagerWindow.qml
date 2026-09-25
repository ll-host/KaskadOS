pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

FloatingWindow {
    id: root

    property string editorMode: ""
    property string pendingDanger: ""
    property var pendingDangerEntry: null

    Shortcut { sequence: StandardKey.Copy; onActivated: FileManagerService.rememberSelected(false) }
    Shortcut { sequence: StandardKey.Cut; onActivated: FileManagerService.rememberSelected(true) }
    Shortcut { sequence: StandardKey.Paste; onActivated: FileManagerService.paste() }
    Shortcut {
        sequence: StandardKey.Delete
        onActivated: {
            if (FileManagerService.viewMode === "trash" && FileManagerService.selectedEntry) {
                root.pendingDangerEntry = FileManagerService.selectedEntry;
                root.pendingDanger = "delete";
            } else {
                FileManagerService.trashSelected();
            }
        }
    }

    function commitNameEdit() {
        const value = nameEditor.text.trim();
        if (value.length === 0)
            return;
        if (editorMode === "mkdir")
            FileManagerService.makeDirectory(value);
        else
            FileManagerService.renameSelected(value);
        nameEditor.text = "";
        editorMode = "";
    }

    objectName: "kaskadosFileManager"
    title: "Файлы — KaskadOS"
    minimumSize: Qt.size(820, 480)
    implicitWidth: 980
    implicitHeight: 680
    color: Theme.surfaceContainer
    visible: false

    function showAt(path) {
        visible = true;
        if (path)
            FileManagerService.navigate(path);
        Qt.callLater(() => locationField.forceActiveFocus());
    }

    onClosed: visible = false

    Column {
        anchors.fill: parent

        Rectangle {
            width: parent.width
            height: 58
            color: Theme.surfaceContainerHigh

            MouseArea {
                anchors.fill: parent
                onPressed: windowControls.tryStartMove()
                onDoubleClicked: windowControls.tryToggleMaximize()
            }

            Row {
                anchors.left: parent.left
                anchors.right: titleControls.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                anchors.rightMargin: Theme.spacingM
                spacing: Theme.spacingXS

                DankActionButton {
                    buttonSize: 36
                    iconName: "arrow_upward"
                    iconColor: Theme.surfaceText
                    backgroundColor: Theme.surfaceContainerHighest
                    enabled: FileManagerService.parentPath.length > 0
                    tooltipText: "На уровень выше"
                    onClicked: FileManagerService.navigate(FileManagerService.parentPath)
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: "home"
                    iconColor: Theme.surfaceText
                    backgroundColor: Theme.surfaceContainerHighest
                    tooltipText: "Домашняя папка"
                    onClicked: FileManagerService.navigate(FileManagerService.homePath)
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: "refresh"
                    iconColor: Theme.surfaceText
                    backgroundColor: Theme.surfaceContainerHighest
                    tooltipText: "Обновить"
                    onClicked: FileManagerService.refresh()
                }

                DankTextField {
                    id: locationField
                    width: Math.max(220, parent.width - 240)
                    height: 38
                    text: FileManagerService.viewMode === "trash" ? "Корзина" : FileManagerService.currentPath
                    leftIconName: FileManagerService.viewMode === "trash" ? "delete" : "folder"
                    showClearButton: false
                    enabled: FileManagerService.viewMode === "files"
                    onAccepted: if (FileManagerService.viewMode === "files") FileManagerService.navigate(text.trim())
                }

                DankActionButton {
                    buttonSize: 36
                    iconName: FileManagerService.showHidden ? "visibility" : "visibility_off"
                    iconColor: FileManagerService.showHidden ? Theme.primary : Theme.surfaceVariantText
                    backgroundColor: Theme.surfaceContainerHighest
                    tooltipText: FileManagerService.showHidden ? "Скрытые файлы показаны" : "Показать скрытые файлы"
                    onClicked: FileManagerService.setShowHidden(!FileManagerService.showHidden)
                }
            }

            Row {
                id: titleControls
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankActionButton {
                    visible: windowControls.canMaximize
                    circular: false
                    iconName: root.maximized ? "fullscreen_exit" : "fullscreen"
                    iconColor: Theme.surfaceText
                    tooltipText: root.maximized ? "Восстановить окно" : "Развернуть окно"
                    onClicked: windowControls.tryToggleMaximize()
                }

                DankActionButton {
                    circular: false
                    iconName: "close"
                    iconColor: Theme.surfaceText
                    tooltipText: "Закрыть"
                    onClicked: root.visible = false
                }
            }
        }

        Rectangle {
            width: parent.width
            height: editorRow.visible ? 50 : 0
            visible: root.editorMode.length > 0
            color: Theme.surfaceContainer
            clip: true

            Row {
                id: editorRow
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS

                DankTextField {
                    id: nameEditor
                    width: parent.width - saveNameButton.width - cancelNameButton.width - Theme.spacingS * 2
                    height: 36
                    placeholderText: root.editorMode === "mkdir" ? "Название новой папки" : "Новое имя"
                    onAccepted: root.commitNameEdit()
                }

                DankActionButton {
                    id: saveNameButton
                    buttonSize: 36
                    iconName: "check"
                    iconColor: Theme.onPrimary
                    backgroundColor: Theme.primary
                    tooltipText: "Сохранить"
                    onClicked: root.commitNameEdit()
                }

                DankActionButton {
                    id: cancelNameButton
                    buttonSize: 36
                    iconName: "close"
                    iconColor: Theme.surfaceText
                    backgroundColor: Theme.surfaceContainerHighest
                    tooltipText: "Отмена"
                    onClicked: root.editorMode = ""
                }
            }
        }

        Row {
            id: browserBody
            width: parent.width
            height: parent.height - y

            Rectangle {
                id: placesSidebar
                width: Math.min(230, Math.max(178, browserBody.width * 0.23))
                height: parent.height
                color: Theme.surfaceContainerHigh

                Column {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingXS

                    SidebarPlace {
                        width: parent.width
                        text: "Домашняя папка"
                        subtitle: FileManagerService.homePath
                        iconName: "home"
                        active: FileManagerService.viewMode === "files"
                             && FileManagerService.currentPath === FileManagerService.homePath
                        onClicked: FileManagerService.navigate(FileManagerService.homePath)
                    }

                    SidebarPlace {
                        width: parent.width
                        text: "Корзина"
                        subtitle: "Восстановление и окончательное удаление"
                        iconName: "delete"
                        active: FileManagerService.viewMode === "trash"
                        onClicked: FileManagerService.openTrash()
                    }

                    StyledText {
                        width: parent.width
                        height: 32
                        verticalAlignment: Text.AlignBottom
                        text: "Накопители"
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.DemiBold
                        color: Theme.surfaceVariantText
                    }

                    ListView {
                        id: deviceList
                        width: parent.width
                        height: Math.max(0, parent.height - y)
                        clip: true
                        spacing: 4
                        model: FileManagerService.devices

                        delegate: Rectangle {
                            id: deviceRow
                            required property var modelData
                            required property int index
                            width: deviceList.width
                            height: 68
                            radius: Theme.cornerRadius
                            color: deviceArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                            MouseArea {
                                id: deviceArea
                                anchors.fill: parent
                                anchors.rightMargin: deviceAction.width + Theme.spacingXS
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: FileManagerService.openDevice(deviceRow.modelData)
                            }

                            Item {
                                id: deviceGlyph
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                width: 34
                                height: 34

                                Image {
                                    anchors.centerIn: parent
                                    width: deviceRow.modelData.compatibility === "universal" ? 26 : 32
                                    height: width
                                    source: Qt.resolvedUrl("../assets/kaskados-logo.png")
                                    fillMode: Image.PreserveAspectFit
                                    visible: ["kaskados", "universal"].includes(deviceRow.modelData.compatibility)
                                }

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: deviceRow.modelData.compatibility === "windows" ? "window" : "hard_drive"
                                    size: 27
                                    color: deviceRow.modelData.compatibility === "windows" ? Theme.info : Theme.surfaceVariantText
                                    visible: ["windows", "other"].includes(deviceRow.modelData.compatibility)
                                }

                                Rectangle {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    width: 20
                                    height: 20
                                    radius: 10
                                    color: Theme.surfaceContainerHigh
                                    border.width: 1
                                    border.color: Theme.outlineVariant
                                    visible: deviceRow.modelData.compatibility === "universal"
                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "window"
                                        size: 14
                                        color: Theme.info
                                    }
                                }
                            }

                            Column {
                                anchors.left: deviceGlyph.right
                                anchors.leftMargin: Theme.spacingS
                                anchors.right: deviceAction.left
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: deviceRow.modelData.label
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }
                                StyledText {
                                    width: parent.width
                                    text: FileManagerService.compatibilityLabel(deviceRow.modelData)
                                        + " · " + root.formatSize(deviceRow.modelData.sizeBytes)
                                    font.pixelSize: Math.max(9, Theme.fontSizeSmall - 2)
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            DankActionButton {
                                id: deviceAction
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                buttonSize: 32
                                iconName: deviceRow.modelData.mounted ? "eject" : "mount"
                                iconColor: deviceRow.modelData.mounted ? Theme.primary : Theme.surfaceVariantText
                                backgroundColor: Theme.surfaceContainerHighest
                                tooltipText: deviceRow.modelData.mounted
                                    ? (deviceRow.modelData.removable ? "Безопасно извлечь" : "Отключить")
                                    : "Подключить"
                                onClicked: {
                                    if (deviceRow.modelData.mounted)
                                        FileManagerService.safelyRemove(deviceRow.modelData);
                                    else
                                        FileManagerService.openDevice(deviceRow.modelData);
                                }
                            }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.top: parent.top
                            anchors.topMargin: Theme.spacingM
                            visible: deviceList.count === 0
                            text: "Накопителей нет"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }
                    }
                }
            }

            Column {
                id: contentColumn
                width: browserBody.width - placesSidebar.width
                height: browserBody.height

                Rectangle {
                    id: dangerBar
                    width: parent.width
                    height: root.pendingDanger.length > 0 ? 72 : 0
                    visible: height > 0
                    color: Theme.withAlpha(Theme.error, 0.09)
                    clip: true

                    StyledText {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: dangerButtons.left
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.pendingDanger === "empty"
                            ? "Окончательно удалить всё содержимое корзины?"
                            : "Окончательно удалить «" + (root.pendingDangerEntry?.name || "") + "»?"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.error
                        elide: Text.ElideRight
                    }

                    Row {
                        id: dangerButtons
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingS
                        DankButton {
                            text: "Отмена"
                            backgroundColor: Theme.surfaceContainerHighest
                            textColor: Theme.surfaceText
                            onClicked: {
                                root.pendingDanger = "";
                                root.pendingDangerEntry = null;
                            }
                        }
                        DankButton {
                            text: "Удалить навсегда"
                            iconName: "delete_forever"
                            backgroundColor: Theme.error
                            textColor: Theme.surface
                            onClicked: {
                                if (root.pendingDanger === "empty")
                                    FileManagerService.emptyTrash();
                                else
                                    FileManagerService.deleteTrashEntry(root.pendingDangerEntry);
                                root.pendingDanger = "";
                                root.pendingDangerEntry = null;
                            }
                        }
                    }
                }

                ListView {
                    id: fileList
                    width: parent.width
                    height: parent.height - dangerBar.height - operationPanel.height - actionBar.height
                    clip: true
                    spacing: 2
                    model: FileManagerService.entries

                    header: Rectangle {
                        width: fileList.width
                        height: 32
                        color: Theme.surfaceContainer

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: 72
                            anchors.rightMargin: Theme.spacingL
                            StyledText { width: parent.width * 0.52; anchors.verticalCenter: parent.verticalCenter; text: "Имя"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText }
                            StyledText {
                                width: parent.width * 0.30
                                anchors.verticalCenter: parent.verticalCenter
                                text: FileManagerService.viewMode === "trash" ? "Было расположено" : "Тип"
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                            StyledText { width: parent.width * 0.18; anchors.verticalCenter: parent.verticalCenter; text: "Размер"; font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText; horizontalAlignment: Text.AlignRight }
                        }
                    }

                    delegate: Rectangle {
                        id: fileRow
                        required property var modelData
                        required property int index
                        width: fileList.width
                        height: 52
                        radius: Theme.cornerRadius
                        color: FileManagerService.selectedEntry?.path === modelData.path
                            ? Theme.primaryPressed : rowArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            acceptedButtons: Qt.LeftButton
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: FileManagerService.selectedEntry = fileRow.modelData
                            onDoubleClicked: if (FileManagerService.viewMode === "files") FileManagerService.activate(fileRow.modelData)
                        }

                        DankIcon {
                            id: entryIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingL
                            anchors.verticalCenter: parent.verticalCenter
                            name: {
                                if (fileRow.modelData.directory) return "folder";
                                const lower = fileRow.modelData.name.toLowerCase();
                                if (lower.endsWith(".exe")) return "window";
                                if (lower.includes(".pkg.tar.")) return "package_2";
                                if (FileManagerService.isArchive(lower)) return "folder_zip";
                                return "description";
                            }
                            size: 27
                            color: fileRow.modelData.directory ? Theme.primary : Theme.surfaceVariantText
                        }

                        Row {
                            anchors.left: entryIcon.right
                            anchors.leftMargin: Theme.spacingL
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingL
                            anchors.verticalCenter: parent.verticalCenter
                            StyledText { width: parent.width * 0.52; text: fileRow.modelData.name; font.pixelSize: Theme.fontSizeMedium; color: Theme.surfaceText; elide: Text.ElideRight }
                            StyledText {
                                width: parent.width * 0.30
                                text: FileManagerService.viewMode === "trash"
                                    ? (fileRow.modelData.originalPath || "")
                                    : fileRow.modelData.directory ? "Папка" : (fileRow.modelData.mimeType || "Файл")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideMiddle
                            }
                            StyledText { width: parent.width * 0.18; text: fileRow.modelData.directory ? "" : root.formatSize(fileRow.modelData.sizeBytes); font.pixelSize: Theme.fontSizeSmall; color: Theme.surfaceVariantText; horizontalAlignment: Text.AlignRight }
                        }
                    }

                    StyledText {
                        anchors.centerIn: parent
                        visible: !FileManagerService.loading && fileList.count === 0
                        text: FileManagerService.viewMode === "trash" ? "Корзина пуста" : "Папка пуста"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                    }
                }

                Rectangle {
                    id: operationPanel
                    width: parent.width
                    height: FileManagerService.operation !== null ? 88 : 0
                    visible: height > 0
                    color: Theme.surfaceContainer
                    clip: true

                    Column {
                        anchors.left: parent.left
                        anchors.right: operationButton.left
                        anchors.leftMargin: Theme.spacingM
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        Row {
                            width: parent.width
                            StyledText {
                                width: parent.width * 0.58
                                text: root.operationTitle()
                                font.pixelSize: Theme.fontSizeSmall
                                font.weight: Font.Medium
                                color: FileManagerService.operation?.state === "failed" ? Theme.error : Theme.surfaceText
                                elide: Text.ElideRight
                            }
                            StyledText {
                                width: parent.width * 0.42
                                text: root.operationDetails()
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                horizontalAlignment: Text.AlignRight
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 7
                            radius: 4
                            color: Theme.surfaceContainerHighest
                            Rectangle {
                                width: parent.width * root.operationRatio()
                                height: parent.height
                                radius: parent.radius
                                color: FileManagerService.operation?.state === "failed" ? Theme.error : Theme.primary
                                Behavior on width { NumberAnimation { duration: 140 } }
                            }
                        }
                    }

                    DankActionButton {
                        id: operationButton
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        buttonSize: 36
                        iconName: FileManagerService.operationActive() ? "close" : "done"
                        iconColor: FileManagerService.operationActive() ? Theme.error : Theme.primary
                        backgroundColor: Theme.surfaceContainerHighest
                        tooltipText: FileManagerService.operationActive() ? "Отменить операцию" : "Скрыть"
                        onClicked: {
                            if (FileManagerService.operationActive())
                                FileManagerService.cancelOperation();
                            else
                                FileManagerService.dismissOperation();
                        }
                    }
                }

                Rectangle {
                    id: actionBar
                    width: parent.width
                    height: 58
                    color: Theme.surfaceContainerHigh

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        spacing: Theme.spacingS
                        visible: FileManagerService.viewMode === "files"

                        DankButton {
                            text: "Новая папка"
                            iconName: "create_new_folder"
                            backgroundColor: Theme.surfaceContainerHighest
                            textColor: Theme.surfaceText
                            onClicked: {
                                root.editorMode = "mkdir";
                                nameEditor.text = "";
                                Qt.callLater(() => nameEditor.forceActiveFocus());
                            }
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "edit"; tooltipText: "Переименовать"
                            iconColor: Theme.surfaceText; backgroundColor: Theme.surfaceContainerHighest
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: {
                                root.editorMode = "rename";
                                nameEditor.text = FileManagerService.selectedEntry?.name || "";
                                Qt.callLater(() => nameEditor.forceActiveFocus());
                            }
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "content_copy"; tooltipText: "Копировать"
                            iconColor: Theme.surfaceText; backgroundColor: Theme.surfaceContainerHighest
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: FileManagerService.rememberSelected(false)
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "content_cut"; tooltipText: "Переместить"
                            iconColor: Theme.surfaceText; backgroundColor: Theme.surfaceContainerHighest
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: FileManagerService.rememberSelected(true)
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "content_paste"; tooltipText: "Вставить сюда"
                            iconColor: Theme.primary; backgroundColor: Theme.surfaceContainerHighest
                            enabled: FileManagerService.clipboardEntry !== null && !FileManagerService.operationActive()
                            onClicked: FileManagerService.paste()
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "delete"; tooltipText: "Переместить в корзину"
                            iconColor: Theme.error; backgroundColor: Theme.withAlpha(Theme.error, 0.1)
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: FileManagerService.trashSelected()
                        }
                        DankDropdown {
                            id: archiveFormat
                            width: 92
                            compactMode: true
                            options: ["zip", "7z", "tar.gz", "tar.zst"]
                            currentValue: "zip"
                        }
                        DankActionButton {
                            buttonSize: 38; iconName: "archive"; tooltipText: "Создать архив"
                            iconColor: Theme.surfaceText; backgroundColor: Theme.surfaceContainerHighest
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: FileManagerService.archiveSelected(archiveFormat.currentValue)
                        }
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Theme.spacingM
                        spacing: Theme.spacingS
                        visible: FileManagerService.viewMode === "trash"

                        DankButton {
                            text: "Восстановить"
                            iconName: "restore_from_trash"
                            backgroundColor: Theme.primary
                            textColor: Theme.onPrimary
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: FileManagerService.restoreSelected()
                        }
                        DankButton {
                            text: "Удалить навсегда"
                            iconName: "delete_forever"
                            backgroundColor: Theme.withAlpha(Theme.error, 0.1)
                            textColor: Theme.error
                            enabled: FileManagerService.selectedEntry !== null
                            onClicked: {
                                root.pendingDangerEntry = FileManagerService.selectedEntry;
                                root.pendingDanger = "delete";
                            }
                        }
                        DankButton {
                            text: "Очистить корзину"
                            iconName: "delete_sweep"
                            backgroundColor: Theme.surfaceContainerHighest
                            textColor: Theme.error
                            enabled: FileManagerService.entries.length > 0
                            onClicked: {
                                root.pendingDangerEntry = null;
                                root.pendingDanger = "empty";
                            }
                        }
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        visible: contentColumn.width >= 760
                        text: FileManagerService.loading ? "Загрузка…" : FileManagerService.entries.length + " объектов"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    FloatingWindowControls {
        id: windowControls
        targetWindow: root
    }

    Connections {
        target: FileManagerService
        function onCurrentPathChanged() {
            if (!locationField.activeFocus)
                locationField.text = FileManagerService.currentPath;
        }
        function onViewModeChanged() {
            if (!locationField.activeFocus)
                locationField.text = FileManagerService.viewMode === "trash" ? "Корзина" : FileManagerService.currentPath;
            root.pendingDanger = "";
            root.pendingDangerEntry = null;
        }
    }

    component SidebarPlace: Rectangle {
        id: place
        property string text: ""
        property string subtitle: ""
        property string iconName: "folder"
        property bool active: false
        signal clicked

        height: 58
        radius: Theme.cornerRadius
        color: active ? Theme.primaryPressed : placeArea.containsMouse ? Theme.primaryHoverLight : "transparent"

        DankIcon {
            id: placeIcon
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            name: place.iconName
            size: 25
            color: place.active ? Theme.primary : Theme.surfaceVariantText
        }
        Column {
            anchors.left: placeIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1
            StyledText { width: parent.width; text: place.text; font.pixelSize: Theme.fontSizeSmall; font.weight: Font.Medium; color: Theme.surfaceText; elide: Text.ElideRight }
            StyledText { width: parent.width; text: place.subtitle; font.pixelSize: Math.max(9, Theme.fontSizeSmall - 2); color: Theme.surfaceVariantText; elide: Text.ElideRight }
        }
        MouseArea {
            id: placeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: place.clicked()
        }
    }

    function operationRatio() {
        const operation = FileManagerService.operation;
        if (!operation)
            return 0;
        if (operation.state === "completed")
            return 1;
        const total = Number(operation.totalBytes || 0);
        return total > 0 ? Math.max(0, Math.min(1, Number(operation.processedBytes || 0) / total)) : 0;
    }

    function operationTitle() {
        const operation = FileManagerService.operation;
        if (!operation)
            return "";
        if (operation.state === "scanning")
            return "Подсчитываем размер «" + operation.name + "»…";
        if (operation.state === "failed")
            return operation.error || "Операция не выполнена";
        if (operation.state === "cancelled")
            return "Операция отменена";
        if (operation.state === "completed")
            return operation.kind === "move" ? "Перемещение завершено" : "Копирование завершено";
        return (operation.kind === "move" ? "Перемещаем «" : "Копируем «") + operation.name + "»";
    }

    function operationDetails() {
        const operation = FileManagerService.operation;
        if (!operation || operation.state === "scanning")
            return "";
        const total = Number(operation.totalBytes || 0);
        const processed = Number(operation.processedBytes || 0);
        if (total <= 0)
            return operation.state === "completed" ? "Готово" : "0 Б";
        const percent = Math.min(100, Math.round(processed * 100 / total));
        return percent + "% · осталось " + formatSize(Math.max(0, total - processed));
    }

    function formatSize(bytes) {
        let value = Number(bytes || 0);
        const units = ["Б", "КиБ", "МиБ", "ГиБ", "ТиБ"];
        let index = 0;
        while (value >= 1024 && index < units.length - 1) {
            value /= 1024;
            index++;
        }
        return (index === 0 ? Math.round(value) : value.toFixed(1)) + " " + units[index];
    }
}
