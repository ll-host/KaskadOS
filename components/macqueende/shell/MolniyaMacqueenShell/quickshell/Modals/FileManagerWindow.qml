pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

FloatingWindow {
    id: root

    property string editorMode: ""

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
                    text: FileManagerService.currentPath
                    leftIconName: "folder"
                    showClearButton: false
                    onAccepted: FileManagerService.navigate(text.trim())
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

        ListView {
            id: fileList
            width: parent.width
            height: parent.height - y - actionBar.height
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

                    StyledText {
                        width: parent.width * 0.55
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Имя"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width * 0.25
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Тип"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width * 0.2
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Размер"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignRight
                    }
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
                    ? Theme.primaryPressed
                    : rowArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: FileManagerService.selectedEntry = fileRow.modelData
                    onDoubleClicked: FileManagerService.activate(fileRow.modelData)
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

                    StyledText {
                        width: parent.width * 0.55
                        text: fileRow.modelData.name
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width * 0.25
                        text: fileRow.modelData.directory ? "Папка" : (fileRow.modelData.mimeType || "Файл")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width * 0.2
                        text: fileRow.modelData.directory ? "" : formatSize(fileRow.modelData.sizeBytes)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: !FileManagerService.loading && fileList.count === 0
                text: "Папка пуста"
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }
        }

        Rectangle {
            id: actionBar
            width: parent.width
            height: 54
            color: Theme.surfaceContainerHigh

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.spacingM
                spacing: Theme.spacingS

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

                DankButton {
                    text: "Переименовать"
                    iconName: "edit"
                    backgroundColor: Theme.surfaceContainerHighest
                    textColor: Theme.surfaceText
                    enabled: FileManagerService.selectedEntry !== null
                    onClicked: {
                        root.editorMode = "rename";
                        nameEditor.text = FileManagerService.selectedEntry?.name || "";
                        Qt.callLater(() => nameEditor.forceActiveFocus());
                    }
                }

                DankButton {
                    text: "В корзину"
                    iconName: "delete"
                    backgroundColor: Theme.withAlpha(Theme.error, 0.1)
                    textColor: Theme.error
                    enabled: FileManagerService.selectedEntry !== null
                    onClicked: FileManagerService.trashSelected()
                }

                DankDropdown {
                    id: archiveFormat
                    width: 110
                    compactMode: true
                    options: ["zip", "7z", "tar.gz", "tar.zst"]
                    currentValue: "zip"
                }

                DankButton {
                    text: "В архив"
                    iconName: "archive"
                    backgroundColor: Theme.surfaceContainerHighest
                    textColor: Theme.surfaceText
                    enabled: FileManagerService.selectedEntry !== null
                    onClicked: FileManagerService.archiveSelected(archiveFormat.currentValue)
                }
            }

            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                text: FileManagerService.loading ? "Загрузка…" : FileManagerService.entries.length + " объектов"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
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
