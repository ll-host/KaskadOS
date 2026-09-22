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

    Component.onCompleted: {
        if (mode === "installed")
            SoftwareService.loadInstalled();
    }

    ConfirmModal {
        id: actionConfirm
    }

    function requestAction(item) {
        if (!item || SoftwareService.itemOperationState(item) !== "idle")
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
            height: SoftwareService.operationBusy ? 88 : 0
            visible: height > 0
            radius: Theme.cornerRadius
            color: Theme.primaryContainer
            clip: true

            Column {
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 5

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankIcon {
                        id: operationIcon
                        anchors.verticalCenter: parent.verticalCenter
                        name: SoftwareService.operation?.action === "remove" ? "delete" : "progress_activity"
                        size: 20
                        color: Theme.onPrimaryContainer

                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 1200
                            loops: Animation.Infinite
                            running: SoftwareService.operationRunning
                        }
                    }

                    Column {
                        width: parent.width - cancelButton.width - operationIcon.width - Theme.spacingS * 2
                        spacing: 1

                        StyledText {
                            width: parent.width
                            text: SoftwareService.operation?.item?.name || SoftwareService.operation?.item?.packageName || "Подготовка операции"
                            color: Theme.onPrimaryContainer
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            text: (SoftwareService.operation?.message || "Выполняется")
                                + (SoftwareService.operation?.total > 0
                                   ? " · " + Math.min(SoftwareService.operation.completed + 1, SoftwareService.operation.total)
                                     + " из " + SoftwareService.operation.total
                                     + " · осталось: " + SoftwareService.remainingCount
                                   : "")
                            color: Theme.withAlpha(Theme.onPrimaryContainer, 0.78)
                            font.pixelSize: Theme.fontSizeSmall
                            elide: Text.ElideRight
                        }
                    }

                    DankActionButton {
                        id: cancelButton
                        anchors.verticalCenter: parent.verticalCenter
                        buttonSize: 32
                        iconName: "close"
                        iconColor: Theme.onPrimaryContainer
                        backgroundColor: Theme.withAlpha(Theme.onPrimaryContainer, 0.08)
                        tooltipText: "Отменить текущую операцию"
                        onClicked: SoftwareService.cancel()
                    }
                }

                Row {
                    width: parent.width
                    spacing: Theme.spacingS

                    M3WaveProgress {
                        width: parent.width - progressPercent.width - Theme.spacingS
                        height: 14
                        value: SoftwareService.operation?.progressKnown ? SoftwareService.operation.progress / 100 : 0.45
                        actualValue: value
                        isPlaying: SoftwareService.operationRunning
                        amp: 1.1
                        lineWidth: 2
                        wavelength: 18
                    }

                    StyledText {
                        id: progressPercent
                        anchors.verticalCenter: parent.verticalCenter
                        text: SoftwareService.operation?.progressKnown
                            ? SoftwareService.operation.progress + "%"
                            : (SoftwareService.operation?.completed || 0) + "/" + (SoftwareService.operation?.total || 1)
                        color: Theme.onPrimaryContainer
                        font.pixelSize: Theme.fontSizeSmall
                        font.weight: Font.Medium
                    }
                }
            }
        }

        Row {
            width: parent.width
            height: 36
            spacing: Theme.spacingS

            Row {
                id: sectionTabs
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXXS

                Repeater {
                    model: [
                        {"label": "Каталог", "value": "store", "icon": "storefront"},
                        {"label": "Установленные", "value": "installed", "icon": "inventory_2"}
                    ]

                    DankButton {
                        required property var modelData
                        text: modelData.label
                        iconName: modelData.icon
                        backgroundColor: root.mode === modelData.value ? Theme.primary : Theme.surfaceContainerHighest
                        textColor: root.mode === modelData.value ? Theme.primaryText : Theme.surfaceText
                        onClicked: {
                            SoftwareService.section = modelData.value;
                        }
                    }
                }
            }

            Item {
                width: Math.max(0, parent.width - sectionTabs.width
                    - (localPackageButton.visible ? localPackageButton.width : 0)
                    - resultStatus.width - Theme.spacingS * 3)
                height: 1
            }

            Row {
                id: resultStatus
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                DankIcon {
                    id: searchSpinner
                    anchors.verticalCenter: parent.verticalCenter
                    visible: SoftwareService.searching || (root.mode === "installed" && SoftwareService.loadingInstalled)
                    name: "progress_activity"
                    size: 17
                    color: Theme.primary

                    RotationAnimator on rotation {
                        from: 0
                        to: 360
                        duration: 900
                        loops: Animation.Infinite
                        running: searchSpinner.visible
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: SoftwareService.searching ? "Ищем…"
                        : root.mode === "installed" && SoftwareService.loadingInstalled ? "Загружаем…"
                        : root.query.trim().length >= 2 || root.mode === "installed" ? root.visibleItems.length + " шт." : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            DankButton {
                id: localPackageButton
                anchors.verticalCenter: parent.verticalCenter
                visible: root.mode === "store"
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
                    readonly property string operationState: SoftwareService.itemOperationState(softwareItem.modelData)
                    iconName: operationState === "running" ? "progress_activity"
                        : operationState === "requesting" ? "hourglass_top"
                        : operationState === "queued" ? "schedule"
                        : operationState === "processed" ? "check"
                        : softwareItem.modelData.installed ? "delete" : "download"
                    iconColor: operationState === "idle" && softwareItem.modelData.installed ? Theme.error : Theme.onPrimary
                    backgroundColor: operationState === "idle" && softwareItem.modelData.installed
                        ? Theme.withAlpha(Theme.error, 0.1) : Theme.primary
                    enabled: operationState === "idle"
                    tooltipText: operationState === "running" ? "Выполняется"
                        : operationState === "requesting" ? "Добавляем в очередь"
                        : operationState === "queued" ? "В очереди · позиция " + SoftwareService.itemQueuePosition(softwareItem.modelData)
                        : operationState === "processed" ? "Операция обработана"
                        : softwareItem.modelData.installed ? "Удалить" : "Добавить в очередь установки"
                    onClicked: {
                        root.selectedIndex = softwareItem.index;
                        root.activateSelected();
                    }
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: (SoftwareService.searching || (root.mode === "installed" && SoftwareService.loadingInstalled))
                    && root.visibleItems.length === 0
                color: Theme.withAlpha(Theme.surface, 0.88)
                radius: Theme.cornerRadius
                z: 10

                Column {
                    anchors.centerIn: parent
                    spacing: Theme.spacingM

                    DankIcon {
                        id: emptySearchSpinner
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "progress_activity"
                        size: 34
                        color: Theme.primary

                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 900
                            loops: Animation.Infinite
                            running: emptySearchSpinner.visible
                        }
                    }

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.mode === "installed" ? "Загружаем установленные пакеты"
                            : "Ищем пакеты в " + SoftwareService.sourceFilterLabel(SoftwareService.sourceFilter)
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
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
