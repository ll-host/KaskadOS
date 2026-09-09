pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    property var section: null
    property var controller: null
    property string viewMode: "list"
    property bool canChangeViewMode: true
    property bool canCollapse: true
    property bool isSticky: false
    property bool popupAbove: false
    property Item popupAboveItem: null
    property var transientSurfaceTracker: null

    signal viewModeToggled

    Component.onDestruction: transientSurfaceTracker?.unregister(root)

    Connections {
        target: root.transientSurfaceTracker
        ignoreUnknownSignals: true

        function onCloseRequested() {
            categoryPopup.close();
        }
    }

    width: parent?.width ?? 200
    height: 32
    color: isSticky ? Theme.withAlpha(Theme.surfaceHover, 0) : (hoverArea.containsMouse ? Theme.surfaceHover : Theme.withAlpha(Theme.surfaceHover, 0))
    radius: Theme.cornerRadius

    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    Row {
        id: leftContent
        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        readonly property bool hasAppFolders: root.section?.id === "apps" && (root.controller?.appFolders?.length ?? 0) > 0

        DankIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: !leftContent.hasAppFolders
            name: root.section?.icon ?? "folder"
            size: 16
            color: Theme.surfaceVariantText
        }

        // Plain title — hidden when the category chip is shown
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            visible: !leftContent.hasAppFolders
            text: root.section?.title ?? ""
            font.pixelSize: Theme.fontSizeSmall
            font.weight: Font.Medium
            color: Theme.surfaceVariantText
        }

        Item {
            id: categoryChip
            visible: leftContent.hasAppFolders
            anchors.verticalCenter: parent.verticalCenter
            width: chipRow.implicitWidth + Theme.spacingM * 2
            height: 24

            readonly property var currentFolder: root.controller?.appFolder(root.controller?.appFolderId) ?? null
            readonly property string currentFolderName: currentFolder?.name ?? I18n.tr("All")
            property string editingFolderId: ""
            property bool creatingFolder: false
            property bool folderNameInvalid: false

            function beginCreateFolder() {
                creatingFolder = true;
                editingFolderId = "";
                folderNameInvalid = false;
                folderNameInput.text = "";
                Qt.callLater(() => folderNameInput.forceActiveFocus());
            }

            function beginRenameFolder(folder) {
                creatingFolder = false;
                editingFolderId = folder.id;
                folderNameInvalid = false;
                folderNameInput.text = folder.name;
                Qt.callLater(() => {
                    folderNameInput.forceActiveFocus();
                    folderNameInput.selectAll();
                });
            }

            function cancelFolderEdit() {
                creatingFolder = false;
                editingFolderId = "";
                folderNameInvalid = false;
                folderNameInput.text = "";
            }

            function commitFolderEdit() {
                let saved = false;
                if (creatingFolder)
                    saved = root.controller?.createAppFolder(folderNameInput.text) ?? false;
                else if (editingFolderId)
                    saved = root.controller?.renameAppFolder(editingFolderId, folderNameInput.text) ?? false;
                if (saved)
                    cancelFolderEdit();
                else
                    folderNameInvalid = true;
            }

            Rectangle {
                anchors.fill: parent
                radius: Theme.cornerRadius
                color: chipArea.containsMouse || categoryPopup.visible ? Theme.surfaceContainerHigh : Theme.withAlpha(Theme.surfaceContainerHigh, 0)
                border.color: categoryPopup.visible ? Theme.primary : Theme.outlineMedium
                border.width: categoryPopup.visible ? 2 : 1
            }

            Row {
                id: chipRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: categoryChip.currentFolder?.system ? "apps" : "folder"
                    size: 14
                    color: Theme.surfaceText
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: categoryChip.currentFolderName
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                }

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: categoryPopup.visible ? "expand_less" : "expand_more"
                    size: 14
                    color: Theme.surfaceVariantText
                }
            }

            MouseArea {
                id: chipArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (categoryPopup.visible) {
                        categoryPopup.close();
                    } else {
                        const chipPos = categoryChip.mapToItem(Overlay.overlay, 0, 0);
                        const abovePos = (root.popupAboveItem ?? categoryChip).mapToItem(Overlay.overlay, 0, 0);
                        categoryPopup.x = chipPos.x;
                        categoryPopup.y = root.popupAbove ? abovePos.y - categoryPopup.height - 4 : chipPos.y + categoryChip.height + 4;
                        categoryPopup.open();
                    }
                }
            }

            Popup {
                id: categoryPopup
                parent: categoryChip.Overlay.overlay
                width: Math.max(categoryChip.width, 292)
                padding: 0
                modal: true
                dim: false
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

                onVisibleChanged: root.transientSurfaceTracker?.setActive(root, visible, null)
                onClosed: categoryChip.cancelFolderEdit()

                background: Rectangle {
                    color: "transparent"
                }

                contentItem: Rectangle {
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceContainer, 1)
                    border.color: Theme.primary
                    border.width: 2

                    ElevationShadow {
                        anchors.fill: parent
                        z: -1
                        level: Theme.elevationLevel2
                        fallbackOffset: 4
                        targetRadius: parent.radius
                        targetColor: parent.color
                        borderColor: parent.border.color
                        borderWidth: parent.border.width
                        shadowEnabled: Theme.elevationEnabled && SettingsData.popoutElevationEnabled
                    }

                    Column {
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingXS

                        ListView {
                            id: categoryList
                            width: parent.width
                            height: Math.min(contentHeight, 8 * 36)
                            model: root.controller?.appFolders ?? []
                            spacing: Theme.spacingXXS
                            clip: true
                            interactive: contentHeight > height

                            delegate: Rectangle {
                                id: catDelegate
                                required property var modelData
                                required property int index
                                width: categoryList.width
                                height: 34
                                radius: Theme.cornerRadius
                                readonly property bool isCurrent: root.controller?.appFolderId === modelData.id
                                readonly property bool isSystem: modelData.system === true
                                color: isCurrent ? Theme.primaryHover : catArea.containsMouse ? Theme.primaryHoverLight : Theme.withAlpha(Theme.primaryHoverLight, 0)

                                MouseArea {
                                    id: catArea
                                    anchors.left: parent.left
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.right: folderActions.visible ? folderActions.left : parent.right
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.controller?.setAppFolder(catDelegate.modelData.id);
                                        categoryPopup.close();
                                    }
                                }

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: catDelegate.isSystem ? "apps" : "folder"
                                        size: 16
                                        color: catDelegate.isCurrent ? Theme.primary : Theme.surfaceText
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: catDelegate.width - (catDelegate.isSystem ? 48 : 144)
                                        text: catDelegate.modelData.name
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: catDelegate.isCurrent ? Theme.primary : Theme.surfaceText
                                        font.weight: catDelegate.isCurrent ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                }

                                Row {
                                    id: folderActions
                                    visible: !catDelegate.isSystem
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1

                                    Repeater {
                                        model: [
                                            {
                                                icon: "arrow_upward",
                                                enabled: catDelegate.index > 1,
                                                run: () => root.controller?.moveAppFolder(catDelegate.modelData.id, -1)
                                            },
                                            {
                                                icon: "arrow_downward",
                                                enabled: catDelegate.index < (root.controller?.appFolders?.length ?? 0) - 1,
                                                run: () => root.controller?.moveAppFolder(catDelegate.modelData.id, 1)
                                            },
                                            {
                                                icon: "edit",
                                                enabled: true,
                                                run: () => categoryChip.beginRenameFolder(catDelegate.modelData)
                                            },
                                            {
                                                icon: "delete",
                                                enabled: true,
                                                run: () => root.controller?.deleteAppFolder(catDelegate.modelData.id)
                                            }
                                        ]

                                        delegate: Rectangle {
                                            id: actionDelegate
                                            required property var modelData
                                            required property int index
                                            width: 24
                                            height: 24
                                            radius: 6
                                            opacity: modelData.enabled ? 1 : 0.35
                                            color: actionArea.containsMouse && modelData.enabled ? Theme.surfaceHover : "transparent"

                                            DankIcon {
                                                anchors.centerIn: parent
                                                name: actionDelegate.modelData.icon
                                                size: 14
                                                color: Theme.surfaceVariantText
                                            }

                                            MouseArea {
                                                id: actionArea
                                                anchors.fill: parent
                                                enabled: actionDelegate.modelData.enabled
                                                hoverEnabled: true
                                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: actionDelegate.modelData.run()
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outlineMedium
                        }

                        Item {
                            width: parent.width
                            height: 38

                            Rectangle {
                                anchors.fill: parent
                                visible: !categoryChip.creatingFolder && !categoryChip.editingFolderId
                                radius: Theme.cornerRadius
                                color: addFolderArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                                Row {
                                    anchors.centerIn: parent
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "create_new_folder"
                                        size: 17
                                        color: Theme.primary
                                    }

                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: I18n.tr("Create folder")
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.primary
                                        font.weight: Font.Medium
                                    }
                                }

                                MouseArea {
                                    id: addFolderArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: categoryChip.beginCreateFolder()
                                }
                            }

                            Row {
                                anchors.fill: parent
                                visible: categoryChip.creatingFolder || !!categoryChip.editingFolderId
                                spacing: Theme.spacingXS

                                DankTextField {
                                    id: folderNameInput
                                    width: parent.width - 62
                                    height: parent.height
                                    placeholderText: I18n.tr("Folder")
                                    showClearButton: false
                                    backgroundColor: Theme.surfaceContainerHigh
                                    normalBorderColor: categoryChip.folderNameInvalid ? Theme.error : Theme.outlineMedium
                                    focusedBorderColor: categoryChip.folderNameInvalid ? Theme.error : Theme.primary
                                    textColor: Theme.surfaceText
                                    onTextEdited: categoryChip.folderNameInvalid = false
                                    onAccepted: categoryChip.commitFolderEdit()
                                }

                                Rectangle {
                                    width: 28
                                    height: 28
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: Theme.cornerRadius
                                    color: saveFolderArea.containsMouse ? Theme.primaryHover : "transparent"

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "check"
                                        size: 17
                                        color: Theme.primary
                                    }

                                    MouseArea {
                                        id: saveFolderArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: categoryChip.commitFolderEdit()
                                    }
                                }

                                Rectangle {
                                    width: 28
                                    height: 28
                                    anchors.verticalCenter: parent.verticalCenter
                                    radius: Theme.cornerRadius
                                    color: cancelFolderArea.containsMouse ? Theme.surfaceHover : "transparent"

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: "close"
                                        size: 17
                                        color: Theme.surfaceVariantText
                                    }

                                    MouseArea {
                                        id: cancelFolderArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: categoryChip.cancelFolderEdit()
                                    }
                                }
                            }
                        }
                    }
                }

                height: Math.min((root.controller?.appFolders?.length ?? 0) * 36, 8 * 36) + 48 + Theme.spacingS * 2
            }
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: root.section?.items?.length ?? 0
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.outlineButton
        }
    }

    Row {
        id: rightContent
        anchors.right: parent.right
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        Row {
            id: viewModeRow
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXXS
            visible: root.canChangeViewMode && !root.section?.collapsed

            Repeater {
                model: [
                    {
                        mode: "list",
                        icon: "view_list"
                    },
                    {
                        mode: "grid",
                        icon: "grid_view"
                    },
                    {
                        mode: "tile",
                        icon: "view_module"
                    }
                ]

                Rectangle {
                    required property var modelData
                    required property int index

                    width: 20
                    height: 20
                    radius: 4
                    color: root.viewMode === modelData.mode ? Theme.primaryHover : modeArea.containsMouse ? Theme.surfaceHover : Theme.withAlpha(Theme.surfaceHover, 0)

                    DankIcon {
                        anchors.centerIn: parent
                        name: parent.modelData.icon
                        size: 14
                        color: root.viewMode === parent.modelData.mode ? Theme.primary : Theme.surfaceVariantText
                    }

                    MouseArea {
                        id: modeArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.viewMode !== parent.modelData.mode && root.controller && root.section) {
                                root.controller.setSectionViewMode(root.section.id, parent.modelData.mode);
                            }
                        }
                    }
                }
            }
        }

        Item {
            id: collapseButton
            width: root.canCollapse ? 24 : 0
            height: 24
            visible: root.canCollapse
            anchors.verticalCenter: parent.verticalCenter

            DankIcon {
                anchors.centerIn: parent
                name: root.section?.collapsed ? "expand_more" : "expand_less"
                size: 16
                color: collapseArea.containsMouse ? Theme.primary : Theme.surfaceVariantText
            }

            MouseArea {
                id: collapseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (root.controller && root.section) {
                        root.controller.toggleSection(root.section.id);
                    }
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.rightMargin: rightContent.width + Theme.spacingS
        cursorShape: root.canCollapse ? Qt.PointingHandCursor : Qt.ArrowCursor
        enabled: root.canCollapse && !leftContent.hasAppFolders
        onClicked: {
            if (root.canCollapse && root.controller && root.section) {
                root.controller.toggleSection(root.section.id);
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: Theme.outlineMedium
        visible: root.isSticky
    }
}
