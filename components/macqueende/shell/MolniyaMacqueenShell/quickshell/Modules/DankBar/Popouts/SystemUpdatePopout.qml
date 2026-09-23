import QtQuick
import Quickshell.Wayland
import qs.Common
import qs.Modals
import qs.Services
import qs.Widgets

DankPopout {
    id: systemUpdatePopout

    layerNamespace: "dms:system-update"

    property var parentWidget: null
    property var triggerScreen: null

    Ref {
        service: SystemUpdateService
    }

    property bool _reopenAfterUpgrade: false

    readonly property bool polkitModalOpen: polkitAuthSurfaceModal.shouldBeVisible
    readonly property bool anyModalOpen: polkitModalOpen

    Connections {
        target: PolkitService.agent
        enabled: PolkitService.polkitAvailable && systemUpdatePopout.shouldBeVisible

        function onAuthenticationRequestStarted() {
            polkitAuthSurfaceModal.open();
        }
    }

    PolkitAuthSurfaceModal {
        id: polkitAuthSurfaceModal
        parentPopout: systemUpdatePopout
    }

    backgroundInteractive: !anyModalOpen

    customKeyboardFocus: anyModalOpen ? WlrKeyboardFocus.None : null

    Connections {
        target: SystemUpdateService
        function onIsUpgradingChanged() {
            if (SystemUpdateService.isUpgrading) {
                return;
            }
            if (!systemUpdatePopout._reopenAfterUpgrade) {
                return;
            }
            systemUpdatePopout._reopenAfterUpgrade = false;
            systemUpdatePopout.open();
        }
    }

    popupWidth: 420
    popupHeight: {
        if (SystemUpdateService.isUpgrading || SystemUpdateService.updateCount > 0)
            return 540;
        if (SystemUpdateService.hasError)
            return 420;
        return 310;
    }
    triggerWidth: 55
    positioning: ""
    screen: triggerScreen
    shouldBeVisible: false

    onBackgroundClicked: {
        if (anyModalOpen)
            return;
        close();
    }

    content: Component {
        Rectangle {
            id: updaterPanel

            color: "transparent"
            focus: true

            readonly property bool upgradeRunsInTerminal: SystemUpdateService.useCustomCommand || (SystemUpdateService.backends || []).some(b => b.runsInTerminal === true)

            property int nowUnix: Math.floor(Date.now() / 1000)

            Connections {
                target: systemUpdatePopout
                function onShouldBeVisibleChanged() {
                    if (systemUpdatePopout.shouldBeVisible) {
                        updaterPanel.nowUnix = Math.floor(Date.now() / 1000);
                    }
                }
            }

            function lastCheckedText() {
                const last = SystemUpdateService.lastCheckUnix;
                if (!last) {
                    return "";
                }
                const delta = Math.max(0, nowUnix - last);
                if (delta < 90) {
                    return "Проверено только что";
                }
                if (delta < 3600) {
                    const minutes = Math.round(delta / 60);
                    const form = minutes % 10 === 1 && minutes % 100 !== 11 ? "минуту"
                        : [2, 3, 4].includes(minutes % 10) && ![12, 13, 14].includes(minutes % 100) ? "минуты" : "минут";
                    return `Проверено ${minutes} ${form} назад`;
                }
                if (delta < 86400) {
                    const hours = Math.round(delta / 3600);
                    const form = hours % 10 === 1 && hours % 100 !== 11 ? "час"
                        : [2, 3, 4].includes(hours % 10) && ![12, 13, 14].includes(hours % 100) ? "часа" : "часов";
                    return `Проверено ${hours} ${form} назад`;
                }
                const days = Math.round(delta / 86400);
                const form = days % 10 === 1 && days % 100 !== 11 ? "день"
                    : [2, 3, 4].includes(days % 10) && ![12, 13, 14].includes(days % 100) ? "дня" : "дней";
                return `Проверено ${days} ${form} назад`;
            }

            function updateWord(count) {
                if (count % 10 === 1 && count % 100 !== 11)
                    return "обновление";
                if ([2, 3, 4].includes(count % 10) && ![12, 13, 14].includes(count % 100))
                    return "обновления";
                return "обновлений";
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    systemUpdatePopout.close();
                    event.accepted = true;
                }
            }

            Component.onCompleted: {
                if (systemUpdatePopout.shouldBeVisible) {
                    forceActiveFocus();
                }
            }

            Item {
                id: header
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingL
                height: 48

                Rectangle {
                    id: headerIconContainer
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 40
                    radius: 13
                    color: SystemUpdateService.hasError
                        ? Theme.withAlpha(Theme.error, 0.12)
                        : Theme.primaryContainer

                    DankIcon {
                        anchors.centerIn: parent
                        name: SystemUpdateService.hasError ? "error"
                            : SystemUpdateService.updateCount > 0 ? "system_update_alt" : "check_circle"
                        size: 22
                        color: SystemUpdateService.hasError ? Theme.error : Theme.onPrimaryContainer
                    }
                }

                Column {
                    anchors.left: headerIconContainer.right
                    anchors.leftMargin: Theme.spacingM
                    anchors.right: headerActions.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: "Обновления системы"
                        font.pixelSize: Theme.fontSizeLarge
                        color: Theme.surfaceText
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: {
                            if (SystemUpdateService.isUpgrading)
                                return "Установка обновлений";
                            if (SystemUpdateService.isChecking)
                                return "Идёт проверка";
                            if (SystemUpdateService.hasError)
                                return "Нужна проверка";
                            if (SystemUpdateService.updateCount === 0)
                                return "Система в актуальном состоянии";
                            return `Доступно: ${SystemUpdateService.updateCount} ${updaterPanel.updateWord(SystemUpdateService.updateCount)}`;
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: SystemUpdateService.hasError ? Theme.error : Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                Row {
                    id: headerActions
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    DankActionButton {
                        id: refreshButton
                        buttonSize: 36
                        iconName: "refresh"
                        iconSize: 19
                        iconColor: Theme.surfaceText
                        backgroundColor: Theme.surfaceContainerHighest
                        enabled: !SystemUpdateService.isChecking && !SystemUpdateService.isUpgrading
                        opacity: enabled ? 1.0 : 0.5
                        tooltipText: "Проверить обновления"
                        onClicked: SystemUpdateService.checkForUpdates()

                        RotationAnimator on rotation {
                            from: 0
                            to: 360
                            duration: 1000
                            loops: Animation.Infinite
                            running: SystemUpdateService.isChecking

                            onRunningChanged: {
                                if (!running)
                                    refreshButton.rotation = 0;
                            }
                        }
                    }
                }
            }

            StyledText {
                id: checkTimeRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: header.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingS
                visible: SystemUpdateService.lastCheckUnix > 0 && !SystemUpdateService.isUpgrading
                text: updaterPanel.lastCheckedText()
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
            }

            Row {
                id: buttonsRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: checkTimeRow.visible ? checkTimeRow.bottom : header.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: primaryButton.visible ? Theme.spacingM : 0
                height: primaryButton.visible ? 44 : 0
                visible: height > 0

                Rectangle {
                    id: primaryButton
                    visible: SystemUpdateService.isUpgrading || SystemUpdateService.updateCount > 0
                    width: parent.width
                    height: parent.height
                    radius: Theme.cornerRadius
                    color: SystemUpdateService.isUpgrading
                        ? (primaryMouseArea.containsMouse ? Theme.errorPressed : Theme.withAlpha(Theme.error, 0.12))
                        : (primaryMouseArea.containsMouse ? Theme.primaryHover : Theme.primary)
                    opacity: primaryMouseArea.enabled ? 1.0 : 0.5

                    StyledText {
                        anchors.centerIn: parent
                        text: SystemUpdateService.isUpgrading
                            ? "Остановить обновление"
                            : `Обновить всё (${SystemUpdateService.updateCount})`
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: SystemUpdateService.isUpgrading ? Theme.error : Theme.onPrimary
                    }

                    MouseArea {
                        id: primaryMouseArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: SystemUpdateService.isUpgrading || SystemUpdateService.updateCount > 0
                        onClicked: {
                            if (SystemUpdateService.isUpgrading) {
                                SystemUpdateService.cancelUpdates();
                                return;
                            }
                            const opts = {
                                includeFlatpak: SettingsData.updaterIncludeFlatpak,
                                includeAUR: SettingsData.updaterAllowAUR,
                                terminal: SessionData.terminalOverride
                            };
                            if (updaterPanel.upgradeRunsInTerminal) {
                                systemUpdatePopout._reopenAfterUpgrade = true;
                                SystemUpdateService.runUpdates(opts);
                                systemUpdatePopout.close();
                                return;
                            }
                            SystemUpdateService.runUpdates(opts);
                        }
                    }

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.shortDuration
                            easing.type: Theme.standardEasing
                        }
                    }
                }

            }

            Rectangle {
                id: bodyArea
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: buttonsRow.visible ? buttonsRow.bottom : (checkTimeRow.visible ? checkTimeRow.bottom : header.bottom)
                anchors.bottom: parent.bottom
                anchors.leftMargin: Theme.spacingL
                anchors.rightMargin: Theme.spacingL
                anchors.topMargin: Theme.spacingM
                anchors.bottomMargin: Theme.spacingL
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerLow
                border.width: 1
                border.color: Theme.outlineLight

                Column {
                    id: statusContent
                    anchors.centerIn: parent
                    width: parent.width - Theme.spacingXL * 2
                    spacing: Theme.spacingM
                    visible: !SystemUpdateService.isUpgrading && (SystemUpdateService.updateCount === 0 || SystemUpdateService.hasError || SystemUpdateService.isChecking)

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 58
                        height: 58
                        radius: 20
                        color: SystemUpdateService.hasError
                            ? Theme.withAlpha(Theme.error, 0.12)
                            : Theme.primaryContainer

                        DankIcon {
                            id: statusContentIcon
                            anchors.centerIn: parent
                            name: SystemUpdateService.isChecking ? "refresh"
                                : SystemUpdateService.hasError ? "error" : "check_circle"
                            size: 30
                            color: SystemUpdateService.hasError ? Theme.error : Theme.onPrimaryContainer

                            RotationAnimator on rotation {
                                from: 0
                                to: 360
                                duration: 1000
                                loops: Animation.Infinite
                                running: SystemUpdateService.isChecking

                                onRunningChanged: {
                                    if (!running)
                                        statusContentIcon.rotation = 0;
                                }
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            width: parent.width
                            text: {
                                if (SystemUpdateService.hasError)
                                    return "Не удалось проверить обновления";
                                if (!SystemUpdateService.helperAvailable)
                                    return "Служба обновлений недоступна";
                                if (SystemUpdateService.isChecking)
                                    return "Проверяем обновления…";
                                return "Всё обновлено";
                            }
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.fontSizeLarge
                            font.weight: Font.DemiBold
                            color: SystemUpdateService.hasError ? Theme.error : Theme.surfaceText
                            wrapMode: Text.WordWrap
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (SystemUpdateService.hasError)
                                    return SystemUpdateService.errorHint || SystemUpdateService.errorMessage || "Повторите проверку чуть позже";
                                if (!SystemUpdateService.helperAvailable)
                                    return "Не найден поддерживаемый менеджер пакетов";
                                if (SystemUpdateService.isChecking)
                                    return "Это может занять несколько секунд";
                                return "Новых пакетов для установки нет";
                            }
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                DankListView {
                    id: packagesList
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: ignoredSection.top
                    anchors.margins: Theme.spacingS
                    visible: !SystemUpdateService.isUpgrading && SystemUpdateService.updateCount > 0 && !SystemUpdateService.hasError && !SystemUpdateService.isChecking
                    clip: true
                    spacing: Theme.spacingXS
                    model: SystemUpdateService.availableUpdates

                    delegate: Rectangle {
                        id: packageRow
                        width: ListView.view.width
                        height: 56
                        radius: Theme.cornerRadius
                        color: rowHoverHandler.hovered ? Theme.primaryHoverLight : Theme.surfaceContainer

                        required property var modelData

                        HoverHandler {
                            id: rowHoverHandler
                        }

                        Row {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingS

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 58
                                height: 24
                                radius: 12
                                color: Theme.primaryContainer

                                StyledText {
                                    anchors.centerIn: parent
                                    text: modelData.repo === "flatpak" ? "Flatpak"
                                        : modelData.repo === "aur" ? "AUR" : "Система"
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.onPrimaryContainer
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - 58 - Theme.spacingS * 2 - 28
                                spacing: Theme.spacingXXS

                                StyledText {
                                    width: parent.width
                                    text: modelData.name || ""
                                    font.pixelSize: Theme.fontSizeMedium
                                    color: Theme.surfaceText
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        text: {
                                            const from = modelData.fromVersion || "";
                                            const to = modelData.toVersion || "";
                                            if (from && to)
                                                return `${from} →`;
                                            return "";
                                        }
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                        visible: text !== ""
                                    }

                                    StyledText {
                                        text: modelData.toVersion || modelData.fromVersion || ""
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.primary
                                        font.weight: Font.Medium
                                        elide: Text.ElideRight
                                        width: parent.width - (parent.children[0].visible ? parent.children[0].implicitWidth + 4 : 0)
                                    }
                                }
                            }
                        }

                        MouseArea {
                            id: packageMouseArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: packageRow.modelData.changelogUrl ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: {
                                if (packageRow.modelData.changelogUrl) {
                                    Qt.openUrlExternally(packageRow.modelData.changelogUrl);
                                }
                            }
                        }

                        DankActionButton {
                            anchors.right: packageRow.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: packageRow.verticalCenter
                            buttonSize: 24
                            iconName: "visibility_off"
                            iconSize: 16
                            iconColor: Theme.surfaceVariantText
                            visible: rowHoverHandler.hovered && SystemUpdateService.canIgnorePackage(packageRow.modelData)
                            tooltipText: "Скрыть это обновление"
                            onClicked: SystemUpdateService.ignorePackage(packageRow.modelData.name)
                        }
                    }
                }

                Column {
                    id: ignoredSection
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Theme.spacingS
                    spacing: Theme.spacingXS

                    readonly property var ignoredNames: SettingsData.updaterIgnoredPackages || []
                    readonly property bool shown: ignoredNames.length > 0 && !SystemUpdateService.isUpgrading && !SystemUpdateService.isChecking
                    property bool expanded: false

                    visible: shown
                    height: shown ? implicitHeight : 0

                    Rectangle {
                        id: ignoredToggle
                        width: parent.width
                        height: 32
                        radius: Theme.cornerRadius
                        color: ignoredToggleArea.containsMouse ? Theme.primaryHoverLight : Theme.surfaceLight

                        DankIcon {
                            id: ignoredToggleIcon
                            anchors.left: parent.left
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            name: "visibility_off"
                            size: 16
                            color: Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.left: ignoredToggleIcon.right
                            anchors.leftMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            text: `Скрытые обновления: ${ignoredSection.ignoredNames.length}`
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankIcon {
                            anchors.right: parent.right
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            name: ignoredSection.expanded ? "expand_less" : "expand_more"
                            size: 16
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: ignoredToggleArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: ignoredSection.expanded = !ignoredSection.expanded
                        }

                        Behavior on color {
                            ColorAnimation {
                                duration: Theme.shortDuration
                                easing.type: Theme.standardEasing
                            }
                        }
                    }

                    DankListView {
                        width: parent.width
                        height: ignoredSection.expanded ? Math.min(contentHeight, 150) : 0
                        visible: ignoredSection.expanded
                        clip: true
                        spacing: Theme.spacingXS
                        model: ignoredSection.ignoredNames

                        delegate: Rectangle {
                            id: ignoredRow
                            width: ListView.view.width
                            height: 32
                            radius: Theme.cornerRadius
                            color: Theme.surfaceLight

                            required property string modelData

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.right: restoreButton.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: ignoredRow.modelData
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            DankActionButton {
                                id: restoreButton
                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingXS
                                anchors.verticalCenter: parent.verticalCenter
                                buttonSize: 24
                                iconName: "visibility"
                                iconSize: 16
                                iconColor: Theme.surfaceVariantText
                                tooltipText: `Снова показывать ${ignoredRow.modelData}`
                                onClicked: SystemUpdateService.unignorePackage(ignoredRow.modelData)
                            }
                        }
                    }
                }

                Column {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    spacing: Theme.spacingS
                    visible: SystemUpdateService.isUpgrading && updaterPanel.upgradeRunsInTerminal

                    DankIcon {
                        anchors.horizontalCenter: parent.horizontalCenter
                        name: "terminal"
                        size: 32
                        color: Theme.primary
                    }

                    StyledText {
                        width: parent.width
                        text: SystemUpdateService.operationLabel.length > 0
                            ? SystemUpdateService.operationLabel
                            : "Обновление выполняется в терминале"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Medium
                        color: Theme.surfaceText
                        horizontalAlignment: Text.AlignHCenter
                    }

                    StyledText {
                        width: parent.width
                        text: "Для обновления AUR может потребоваться ответ в окне терминала. После завершения это окно обновится автоматически."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        horizontalAlignment: Text.AlignHCenter
                    }
                }

                DankFlickable {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingM
                    visible: SystemUpdateService.isUpgrading && !updaterPanel.upgradeRunsInTerminal
                    contentWidth: width
                    contentHeight: logText.implicitHeight
                    clip: true

                    onContentHeightChanged: {
                        if (contentHeight > height) {
                            contentY = contentHeight - height;
                        }
                    }

                    StyledText {
                        id: logText
                        width: parent.width
                        text: {
                            const stage = SystemUpdateService.operationLabel;
                            const attempt = SystemUpdateService.upgradeMaxAttempts > 1
                                ? " · попытка " + SystemUpdateService.upgradeAttempt
                                    + " из " + SystemUpdateService.upgradeMaxAttempts
                                : "";
                            const header = stage.length > 0 ? stage + attempt : "";
                            const log = (SystemUpdateService.recentLog || []).join("\n");
                            return header.length > 0 ? header + "\n\n" + log : log;
                        }
                        font.family: Theme.monoFontFamily || "monospace"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                    }
                }
            }
        }
    }
}
