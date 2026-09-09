pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

FocusScope {
    id: root

    property string mode: "store"
    property string query: ""
    property int selectedIndex: 0
    readonly property var sourceFilters: [
        {"label": "Все", "value": "all"},
        {"label": "Pacman", "value": "pacman"},
        {"label": "AUR", "value": "aur"},
        {"label": "Flatpak", "value": "flatpak"}
    ]
    signal localPackageRequested

    ConfirmModal {
        id: actionConfirm
    }

    function requestAction(item) {
        if (!item || SoftwareService.operationRunning)
            return;
        if (item.installed) {
            actionConfirm.showWithOptions({
                "title": "Удалить " + (item.name || item.packageName) + "?",
                "message": "Менеджер пакетов сначала проверит зависимости и не удалит пакет, если от него зависит система.",
                "confirmText": "Удалить",
                "cancelText": "Отмена",
                "confirmColor": Theme.error,
                "onConfirm": () => SoftwareService.remove(item)
            });
            return;
        }
        if (item.source === "aur") {
            actionConfirm.showWithOptions({
                "title": "Установить пакет из AUR?",
                "message": "AUR — пользовательский репозиторий. Перед установкой будет выполнен его сценарий сборки.",
                "confirmText": "Установить",
                "cancelText": "Отмена",
                "confirmColor": Theme.primary,
                "onConfirm": () => SoftwareService.install(item)
            });
            return;
        }
        SoftwareService.install(item);
    }

    readonly property var visibleItems: {
        let source = mode === "installed" ? (SoftwareService.installedItems || []) : (SoftwareService.searchResults || []);
        if (SoftwareService.sourceFilter !== "all")
            source = source.filter(item => item.source === SoftwareService.sourceFilter);
        if (mode !== "installed" || query.trim().length === 0)
            return source;
        const needle = query.trim().toLowerCase();
        return source.filter(item => (item.name || "").toLowerCase().includes(needle)
                                  || (item.packageName || "").toLowerCase().includes(needle)
                                  || (item.description || "").toLowerCase().includes(needle));
    }

    function sourceFilterIndex() {
        const index = sourceFilters.findIndex(item => item.value === SoftwareService.sourceFilter);
        return index >= 0 ? index : 0;
    }

    onModeChanged: {
        selectedIndex = 0;
        if (mode === "installed")
            SoftwareService.loadInstalled();
        else
            SoftwareService.setQuery(query);
    }

    onQueryChanged: {
        selectedIndex = 0;
        if (mode === "store")
            SoftwareService.setQuery(query);
    }

    function selectNext() {
        if (visibleItems.length > 0)
            selectedIndex = Math.min(visibleItems.length - 1, selectedIndex + 1);
        softwareList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function selectPrevious() {
        if (visibleItems.length > 0)
            selectedIndex = Math.max(0, selectedIndex - 1);
        softwareList.positionViewAtIndex(selectedIndex, ListView.Contain);
    }

    function activateSelected() {
        const item = visibleItems[selectedIndex];
        root.requestAction(item);
    }

    Column {
        anchors.fill: parent
        spacing: Theme.spacingS

        Rectangle {
            width: parent.width
            height: SoftwareService.operationRunning ? 48 : 0
            visible: height > 0
            radius: Theme.cornerRadius
            color: Theme.primaryContainer
            clip: true

            Row {
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: Theme.spacingS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: SoftwareService.operation?.action === "remove" ? "delete" : "download"
                    size: 20
                    color: Theme.onPrimaryContainer
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - cancelButton.width - 36
                    text: (SoftwareService.operation?.message || "Выполняется операция")
                        + (SoftwareService.operation?.item?.name ? ": " + SoftwareService.operation.item.name : "")
                    color: Theme.onPrimaryContainer
                    font.pixelSize: Theme.fontSizeSmall
                    elide: Text.ElideRight
                }

                DankActionButton {
                    id: cancelButton
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 32
                    iconName: "close"
                    iconColor: Theme.onPrimaryContainer
                    backgroundColor: Theme.withAlpha(Theme.onPrimaryContainer, 0.08)
                    tooltipText: "Отменить"
                    onClicked: SoftwareService.cancel()
                }
            }
        }

        Row {
            width: parent.width
            height: 34
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - localPackageButton.width - Theme.spacingS
                text: root.mode === "installed"
                    ? (SoftwareService.sourceFilter === "all"
                       ? "Все установленные пакеты, включая терминальные"
                       : "Установленные пакеты · " + SoftwareService.sourceFilterLabel(SoftwareService.sourceFilter))
                    : (root.query.trim().length < 2
                       ? "Введите минимум два символа для поиска"
                       : (SoftwareService.searching
                          ? "Поиск · " + SoftwareService.sourceFilterLabel(SoftwareService.sourceFilter) + "…"
                          : "Найдено: " + root.visibleItems.length))
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }

            DankButton {
                id: localPackageButton
                anchors.verticalCenter: parent.verticalCenter
                text: "Установить файл"
                iconName: "package_2"
                backgroundColor: Theme.surfaceContainerHighest
                textColor: Theme.surfaceText
                onClicked: root.localPackageRequested()
            }
        }

        DankFilterChips {
            id: sourceFilterChips
            width: parent.width
            model: root.sourceFilters
            currentIndex: root.sourceFilterIndex()
            showCheck: false
            showCounts: false
            onSelectionChanged: index => {
                if (index < 0 || index >= root.sourceFilters.length)
                    return;
                root.selectedIndex = 0;
                SoftwareService.setSourceFilter(root.sourceFilters[index].value);
            }
        }

        ListView {
            id: softwareList
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Theme.spacingXXS
            model: root.visibleItems

            delegate: Rectangle {
                id: softwareItem
                required property var modelData
                required property int index

                width: softwareList.width
                height: 64
                radius: Theme.cornerRadius
                color: root.selectedIndex === index
                    ? Theme.primaryPressed
                    : itemArea.containsMouse ? Theme.primaryHoverLight : "transparent"

                MouseArea {
                    id: itemArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selectedIndex = softwareItem.index
                    onClicked: root.selectedIndex = softwareItem.index
                    onDoubleClicked: root.activateSelected()
                }

                Rectangle {
                    id: packageIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest

                    DankIcon {
                        anchors.centerIn: parent
                        name: softwareItem.modelData.source === "flatpak" ? "deployed_code"
                            : softwareItem.modelData.source === "aur" ? "construction"
                            : softwareItem.modelData.source === "local" ? "folder_zip"
                            : "package_2"
                        size: 23
                        color: Theme.primary
                    }
                }

                Column {
                    anchors.left: packageIcon.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.right: actionButton.left
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            width: Math.min(implicitWidth, parent.width - sourcePill.width - Theme.spacingS)
                            text: softwareItem.modelData.name || softwareItem.modelData.packageName
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            id: sourcePill
                            anchors.verticalCenter: parent.verticalCenter
                            width: sourceLabel.implicitWidth + Theme.spacingS * 2
                            height: 20
                            radius: 10
                            color: Theme.surfaceVariantAlpha

                            StyledText {
                                id: sourceLabel
                                anchors.centerIn: parent
                                text: SoftwareService.sourceLabel(softwareItem.modelData.source)
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: softwareItem.modelData.description || (softwareItem.modelData.packageName + "  " + (softwareItem.modelData.version || ""))
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                DankActionButton {
                    id: actionButton
                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 36
                    iconName: softwareItem.modelData.installed ? "delete" : "download"
                    iconColor: softwareItem.modelData.installed ? Theme.error : Theme.onPrimary
                    backgroundColor: softwareItem.modelData.installed
                        ? Theme.withAlpha(Theme.error, 0.1) : Theme.primary
                    enabled: !SoftwareService.operationRunning
                    tooltipText: softwareItem.modelData.installed ? "Удалить" : "Установить"
                    onClicked: {
                        root.selectedIndex = softwareItem.index;
                        root.activateSelected();
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: !SoftwareService.searching && root.visibleItems.length === 0
                text: root.mode === "installed"
                    ? "Установленные пакеты не найдены"
                    : (root.query.trim().length < 2
                       ? "Начните поиск приложения"
                       : (SoftwareService.searchProblem.length > 0
                          ? SoftwareService.searchProblem
                       : (!SoftwareService.sourceAvailable(SoftwareService.sourceFilter)
                          ? SoftwareService.sourceFilterLabel(SoftwareService.sourceFilter) + " недоступен"
                          : "Нет результатов · " + SoftwareService.sourceFilterLabel(SoftwareService.sourceFilter))))
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                width: parent.width - Theme.spacingXL * 2
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
            }
        }
    }
}
