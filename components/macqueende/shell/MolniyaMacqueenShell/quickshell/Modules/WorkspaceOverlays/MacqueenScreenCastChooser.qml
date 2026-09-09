/*
    SPDX-License-Identifier: GPL-3.0-or-later
    SPDX-FileCopyrightText: 2026 The MacqueenDE contributors
*/

import Macqueen.Ipc
import QtQuick
import Quickshell
import qs.Common
import qs.Modals.Common
import qs.Widgets

Scope {
    id: controller

    property string requestId: ""
    property string chooserTitle: ""
    property var choices: []
    property bool allowRestore: true
    property int selectedIndex: -1

    function clearState() {
        requestId = "";
        chooserTitle = "";
        choices = [];
        selectedIndex = -1;
    }

    function cancel() {
        const pendingRequest = requestId;
        clearState();
        chooser.close();
        if (pendingRequest.length > 0)
            Macqueen.cancelScreenCastSelection(pendingRequest);
    }

    function accept() {
        if (selectedIndex < 0 || selectedIndex >= choices.length)
            return;
        const pendingRequest = requestId;
        const choice = choices[selectedIndex];
        if (!Macqueen.submitScreenCastSelection(pendingRequest, choice.kind, choice.id, allowRestore))
            return;
        clearState();
        chooser.close();
    }

    Connections {
        target: Macqueen

        function onScreenCastSelectionRequested(newRequestId, newTitle, optionsJson) {
            let options = {};
            try {
                options = JSON.parse(optionsJson);
            } catch (error) {
                console.warn("Invalid Macqueen screencast request:", error);
                Macqueen.cancelScreenCastSelection(newRequestId);
                return;
            }

            if (controller.requestId.length > 0)
                Macqueen.cancelScreenCastSelection(controller.requestId);

            controller.requestId = newRequestId;
            controller.chooserTitle = newTitle;
            controller.choices = (options.outputs || []).concat(options.windows || []);
            controller.allowRestore = true;
            controller.selectedIndex = controller.choices.length === 1 ? 0 : -1;
            chooser.open();
        }
    }

    DankModal {
        id: chooser

        layerNamespace: "macqueen:screen-cast-chooser"
        shouldBeVisible: false
        closeOnEscapeKey: false
        closeOnBackgroundClick: false
        allowStacking: true
        useOverlayLayer: true
        modalWidth: Math.max(320, Math.min(760, screenWidth - Theme.spacingL * 2))
        modalHeight: Math.max(360, Math.min(680, screenHeight - Theme.spacingL * 2))

        onOpened: Qt.callLater(() => contentLoader.item?.forceActiveFocus())

        onDialogClosed: {
            if (controller.requestId.length === 0)
                return;
            const pendingRequest = controller.requestId;
            controller.clearState();
            Macqueen.cancelScreenCastSelection(pendingRequest);
        }

        content: Component {
            FocusScope {
                id: chooserContent

                anchors.fill: parent
                focus: true

                Keys.onEscapePressed: event => {
                    controller.cancel();
                    event.accepted = true;
                }
                Keys.onReturnPressed: event => {
                    controller.accept();
                    event.accepted = true;
                }
                Keys.onEnterPressed: event => {
                    controller.accept();
                    event.accepted = true;
                }
                Keys.onUpPressed: event => {
                    controller.selectedIndex = Math.max(0, controller.selectedIndex - 1);
                    choicesView.positionViewAtIndex(controller.selectedIndex, ListView.Contain);
                    event.accepted = true;
                }
                Keys.onDownPressed: event => {
                    controller.selectedIndex = Math.min(controller.choices.length - 1, controller.selectedIndex + 1);
                    choicesView.positionViewAtIndex(controller.selectedIndex, ListView.Contain);
                    event.accepted = true;
                }

                Column {
                    id: header

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Theme.spacingL
                    spacing: Theme.spacingXS

                    StyledText {
                        width: parent.width
                        text: controller.chooserTitle || "Демонстрация экрана"
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: "Выберите экран или окно для демонстрации"
                        color: Theme.surfaceTextMedium
                        font.pixelSize: Theme.fontSizeSmall
                    }
                }

                DankActionButton {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: Theme.spacingM
                    anchors.rightMargin: Theme.spacingM
                    iconName: "close"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: controller.cancel()
                }

                Rectangle {
                    id: listBackground

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: header.bottom
                    anchors.bottom: footer.top
                    anchors.leftMargin: Theme.spacingL
                    anchors.rightMargin: Theme.spacingL
                    anchors.topMargin: Theme.spacingL
                    anchors.bottomMargin: Theme.spacingM
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHigh
                    border.width: 1
                    border.color: Theme.outline

                    ListView {
                        id: choicesView

                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        clip: true
                        spacing: Theme.spacingS
                        model: controller.choices

                        delegate: Rectangle {
                            id: choiceCard

                            required property int index
                            required property var modelData
                            width: choicesView.width
                            height: 76
                            radius: Theme.cornerRadius
                            color: controller.selectedIndex === index ? Theme.primaryContainer : Theme.surfaceContainer
                            border.width: controller.selectedIndex === index ? 2 : 1
                            border.color: controller.selectedIndex === index ? Theme.primary : Theme.outline

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingM

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 44
                                    height: 44
                                    radius: 12
                                    color: controller.selectedIndex === choiceCard.index ? Theme.primary : Theme.surfaceContainerHighest

                                    DankIcon {
                                        anchors.centerIn: parent
                                        name: choiceCard.modelData.kind === "window" ? "select_window" : "monitor"
                                        size: 24
                                        color: controller.selectedIndex === choiceCard.index ? Theme.primaryText : Theme.surfaceText
                                    }
                                }

                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 60
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        width: parent.width
                                        text: choiceCard.modelData.label || choiceCard.modelData.name || choiceCard.modelData.id
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: choiceCard.modelData.kind === "window"
                                            ? "Окно · " + (choiceCard.modelData.appId || "приложение")
                                            : "Экран · " + (choiceCard.modelData.name || choiceCard.modelData.description || "")
                                        color: Theme.surfaceTextMedium
                                        font.pixelSize: Theme.fontSizeSmall
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: controller.selectedIndex = choiceCard.index
                                onDoubleClicked: {
                                    controller.selectedIndex = choiceCard.index;
                                    controller.accept();
                                }
                            }
                        }

                        StyledText {
                            anchors.centerIn: parent
                            visible: controller.choices.length === 0
                            text: "Нет доступных экранов или окон"
                            color: Theme.surfaceTextMedium
                        }
                    }
                }

                Item {
                    id: footer

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingL
                    height: 48

                    DankButton {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: controller.allowRestore ? "✓  Запомнить выбор" : "Запомнить выбор"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: controller.allowRestore = !controller.allowRestore
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingM

                        DankButton {
                            text: "Отмена"
                            backgroundColor: Theme.surfaceContainerHighest
                            textColor: Theme.surfaceText
                            onClicked: controller.cancel()
                        }

                        DankButton {
                            text: "Поделиться"
                            enabled: controller.selectedIndex >= 0
                            backgroundColor: enabled ? Theme.primary : Theme.surfaceContainerHighest
                            textColor: enabled ? Theme.primaryText : Theme.surfaceTextMedium
                            onClicked: controller.accept()
                        }
                    }
                }
            }
        }
    }
}
