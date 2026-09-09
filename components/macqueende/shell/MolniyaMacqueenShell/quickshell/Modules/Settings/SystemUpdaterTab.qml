import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

Item {
    id: root

    readonly property var intervalOptions: [
        {
            label: I18n.tr("Every 15 minutes"),
            seconds: 900
        },
        {
            label: I18n.tr("Every 30 minutes"),
            seconds: 1800
        },
        {
            label: I18n.tr("Every hour"),
            seconds: 3600
        },
        {
            label: I18n.tr("Every 4 hours"),
            seconds: 14400
        },
        {
            label: I18n.tr("Once a day"),
            seconds: 86400
        }
    ]

    readonly property string customIntervalLabel: I18n.tr("Custom")
    property bool customIntervalSelected: false

    Component.onCompleted: {
        customIntervalSelected = !intervalOptions.some(o => o.seconds === SettingsData.updaterIntervalSeconds);
    }

    function intervalLabelFor(seconds) {
        for (const opt of intervalOptions) {
            if (opt.seconds === seconds) {
                return opt.label;
            }
        }
        return customIntervalLabel;
    }

    function intervalSecondsFor(label) {
        for (const opt of intervalOptions) {
            if (opt.label === label) {
                return opt.seconds;
            }
        }
        return 1800;
    }

    function validScheduleDate(value) {
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
        if (!match)
            return false;
        const year = Number(match[1]);
        const month = Number(match[2]) - 1;
        const day = Number(match[3]);
        const date = new Date(year, month, day);
        return date.getFullYear() === year && date.getMonth() === month && date.getDate() === day;
    }

    DankFlickable {
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn
            topPadding: 4
            width: Math.min(550, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingXL

            SettingsCard {
                width: parent.width
                iconName: "schedule"
                title: "Автоматическое обновление"
                settingKey: "automaticUpdates"

                SettingsToggleRow {
                    text: "Обновлять автоматически"
                    description: "Проверять и устанавливать обновления без терминала по выбранному расписанию."
                    checked: SettingsData.updaterAutomaticEnabled
                    onToggled: checked => SettingsData.set("updaterAutomaticEnabled", checked)
                }

                SettingsSliderRow {
                    text: "Периодичность"
                    description: "Через сколько дней должен наступать новый сеанс обслуживания."
                    minimum: 1
                    maximum: 30
                    step: 1
                    value: SettingsData.updaterScheduleDays
                    defaultValue: 1
                    unit: " дн."
                    onSliderValueChanged: value => SettingsData.set("updaterScheduleDays", value)
                }

                FocusScope {
                    width: parent.width - Theme.spacingM * 2
                    height: scheduleTimeColumn.implicitHeight
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM

                    Column {
                        id: scheduleTimeColumn
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: "Время начала окна обслуживания"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Medium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: "Если включено ожидание бездействия, в это время система только становится готовой к обновлению."
                            width: parent.width
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DankTextField {
                                id: scheduleHourField
                                width: (parent.width - Theme.spacingS) / 2
                                placeholderText: "Часы: 0–23"
                                text: SettingsData.updaterScheduleHour.toString().padStart(2, "0")
                                onEditingFinished: {
                                    const hour = Math.max(0, Math.min(23, parseInt(text, 10) || 0));
                                    text = hour.toString().padStart(2, "0");
                                    SettingsData.set("updaterScheduleHour", hour);
                                }
                            }

                            DankTextField {
                                id: scheduleMinuteField
                                width: (parent.width - Theme.spacingS) / 2
                                placeholderText: "Минуты: 0–59"
                                text: SettingsData.updaterScheduleMinute.toString().padStart(2, "0")
                                onEditingFinished: {
                                    const minute = Math.max(0, Math.min(59, parseInt(text, 10) || 0));
                                    text = minute.toString().padStart(2, "0");
                                    SettingsData.set("updaterScheduleMinute", minute);
                                }
                            }
                        }

                        DankTextField {
                            id: scheduleStartDateField
                            width: parent.width
                            placeholderText: "Не раньше даты: ГГГГ-ММ-ДД (необязательно)"
                            text: SettingsData.updaterScheduleStartDate
                            onEditingFinished: {
                                const value = text.trim();
                                if (value.length === 0 || root.validScheduleDate(value)) {
                                    SettingsData.set("updaterScheduleStartDate", value);
                                } else {
                                    text = SettingsData.updaterScheduleStartDate;
                                }
                            }
                        }
                    }
                }

                SettingsToggleRow {
                    text: "Ждать бездействия"
                    description: "Начинать установку только когда пользователь не работает и не воспроизводится медиа."
                    checked: SettingsData.updaterIdleFallbackEnabled
                    onToggled: checked => SettingsData.set("updaterIdleFallbackEnabled", checked)
                }

                SettingsSliderRow {
                    visible: SettingsData.updaterIdleFallbackEnabled
                    text: "Время бездействия"
                    description: "Пользователь сам определяет, через сколько минут компьютер считается свободным для обновления."
                    minimum: 5
                    maximum: 180
                    step: 5
                    value: SettingsData.updaterIdleMinutes
                    defaultValue: 30
                    unit: " мин"
                    onSliderValueChanged: value => SettingsData.set("updaterIdleMinutes", value)
                }

                SettingsToggleRow {
                    text: "На ноутбуке — только от сети"
                    description: "Не начинать автоматическую установку во время работы от аккумулятора."
                    checked: SettingsData.updaterOnlyOnAC
                    onToggled: checked => SettingsData.set("updaterOnlyOnAC", checked)
                }

                Rectangle {
                    width: parent.width - Theme.spacingM * 2
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    height: confirmationRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: SettingsData.updaterScheduleConfirmed
                           ? Theme.withAlpha(Theme.primaryContainer, 0.65)
                           : Theme.withAlpha(Theme.warning, 0.12)

                    Row {
                        id: confirmationRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: SettingsData.updaterScheduleConfirmed ? "check_circle" : "notification_important"
                            size: 22
                            color: SettingsData.updaterScheduleConfirmed ? Theme.primary : Theme.warning
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - confirmScheduleButton.width - Theme.spacingS * 2 - 22
                            text: SettingsData.updaterScheduleConfirmed
                                ? "Расписание подтверждено"
                                : "Подтвердите расписание, чтобы включить автоматический запуск"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                        }

                        DankButton {
                            id: confirmScheduleButton
                            visible: !SettingsData.updaterScheduleConfirmed
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Подтвердить"
                            iconName: "check"
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            onClicked: SystemUpdateService.confirmDefaultSchedule()
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "refresh"
                title: I18n.tr("System Updater")
                settingKey: "systemUpdater"

                StyledText {
                    width: parent.width - Theme.spacingM * 2
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    visible: SystemUpdateService.backends.length > 0
                    text: {
                        const names = (SystemUpdateService.backends || []).map(b => b.displayName).join(", ");
                        return I18n.tr("Detected backends: %1").arg(names);
                    }
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    width: parent.width - Theme.spacingM * 2
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    height: manualCheckRow.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.72)

                    Row {
                        id: manualCheckRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        spacing: Theme.spacingS

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: {
                                if (SystemUpdateService.isChecking)
                                    return "sync";
                                if (SystemUpdateService.hasError)
                                    return "error";
                                if (SystemUpdateService.updateCount > 0)
                                    return "system_update_alt";
                                return "check_circle";
                            }
                            size: 22
                            color: SystemUpdateService.hasError ? Theme.error : Theme.primary
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - manualCheckButton.width - Theme.spacingS * 2 - 22
                            spacing: Theme.spacingXXS

                            StyledText {
                                width: parent.width
                                text: {
                                    if (SystemUpdateService.isChecking)
                                        return "Проверяю обновления…";
                                    if (SystemUpdateService.hasError)
                                        return "Не удалось проверить обновления";
                                    if (SystemUpdateService.updateCount > 0)
                                        return "Найдено обновлений: " + SystemUpdateService.updateCount;
                                    if (SystemUpdateService.lastCheckUnix > 0)
                                        return "Система обновлена";
                                    return "Проверка ещё не запускалась";
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Font.Medium
                                color: SystemUpdateService.hasError ? Theme.error : Theme.surfaceText
                                elide: Text.ElideRight
                            }

                            StyledText {
                                width: parent.width
                                text: SystemUpdateService.updateCount > 0
                                    ? "Откройте значок обновлений на панели, чтобы начать установку."
                                    : "Проверка выполняется без терминала."
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                elide: Text.ElideRight
                            }
                        }

                        DankButton {
                            id: manualCheckButton
                            anchors.verticalCenter: parent.verticalCenter
                            text: SystemUpdateService.isChecking ? "Проверяю…" : "Проверить сейчас"
                            iconName: "refresh"
                            enabled: SystemUpdateService.helperAvailable
                                && !SystemUpdateService.isChecking
                                && !SystemUpdateService.isUpgrading
                            backgroundColor: Theme.primary
                            textColor: Theme.primaryText
                            onClicked: SystemUpdateService.checkForUpdates()
                        }
                    }
                }

                SettingsDropdownRow {
                    text: I18n.tr("Check interval")
                    description: I18n.tr("How often the server polls for new updates.")
                    options: root.intervalOptions.map(o => o.label).concat([root.customIntervalLabel])
                    currentValue: root.customIntervalSelected ? root.customIntervalLabel : root.intervalLabelFor(SettingsData.updaterIntervalSeconds)
                    onValueChanged: label => {
                        if (label === root.customIntervalLabel) {
                            root.customIntervalSelected = true;
                            return;
                        }
                        root.customIntervalSelected = false;
                        const secs = root.intervalSecondsFor(label);
                        SettingsData.set("updaterIntervalSeconds", secs);
                        SystemUpdateService.setInterval(secs);
                    }
                }

                FocusScope {
                    width: parent.width - Theme.spacingM * 2
                    height: customIntervalColumn.implicitHeight
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    visible: root.customIntervalSelected

                    Column {
                        id: customIntervalColumn
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Custom interval in minutes (minimum 5)")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankTextField {
                            id: customIntervalField
                            width: parent.width
                            placeholderText: "30"
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.outlineMedium
                            focusedBorderColor: Theme.primary

                            Component.onCompleted: {
                                text = Math.round(SettingsData.updaterIntervalSeconds / 60).toString();
                            }

                            onTextEdited: {
                                const minutes = parseInt(text, 10);
                                if (isNaN(minutes) || minutes < 5) {
                                    return;
                                }
                                const secs = minutes * 60;
                                SettingsData.set("updaterIntervalSeconds", secs);
                                SystemUpdateService.setInterval(secs);
                            }

                            MouseArea {
                                anchors.fill: parent
                                onPressed: mouse => {
                                    customIntervalField.forceActiveFocus();
                                    mouse.accepted = false;
                                }
                            }
                        }
                    }
                }

                SettingsToggleRow {
                    text: I18n.tr("Check on startup")
                    description: I18n.tr("When enabled, checks updates on startup. When disabled, only the interval above or a manual refresh runs a check.")
                    checked: SettingsData.updaterCheckOnStart
                    onToggled: checked => SettingsData.set("updaterCheckOnStart", checked)
                }

                SettingsToggleRow {
                    text: I18n.tr("Include Flatpak updates")
                    description: I18n.tr("Apply Flatpak updates alongside system updates when running 'Update All'.")
                    visible: (SystemUpdateService.backends || []).some(b => b.repo === "flatpak")
                    checked: SettingsData.updaterIncludeFlatpak
                    onToggled: checked => SettingsData.set("updaterIncludeFlatpak", checked)
                }

                SettingsToggleRow {
                    text: I18n.tr("Include AUR updates")
                    description: I18n.tr("Run paru/yay with AUR enabled when 'Update All' is clicked.")
                    visible: (SystemUpdateService.backends || []).some(b => b.id === "paru" || b.id === "yay")
                    checked: SettingsData.updaterAllowAUR
                    onToggled: checked => SettingsData.set("updaterAllowAUR", checked)
                }

                TerminalPickerRow {}
            }

            SettingsCard {
                id: ignoredPackagesCard
                width: parent.width
                iconName: "inventory_2"
                title: I18n.tr("Ignored Packages")
                settingKey: "systemUpdaterIgnoredPackages"
                tags: ["system", "update", "package", "ignore"]

                function addIgnoredPackage() {
                    const name = newIgnoredPackageField.text.trim();
                    if (name === "") {
                        return;
                    }
                    if (!/^[A-Za-z0-9@._+:-]+$/.test(name)) {
                        ignoredPackageError.visible = true;
                        return;
                    }
                    ignoredPackageError.visible = false;
                    SystemUpdateService.ignorePackage(name);
                    newIgnoredPackageField.text = "";
                }

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        text: {
                            if (SettingsData.updaterUseCustomCommand) {
                                return I18n.tr("Ignored packages only apply to the built-in updater. Your custom command controls its own exclusions.");
                            }
                            return (SettingsData.updaterIgnoredPackages || []).length > 0 ? I18n.tr("Ignored packages are hidden from the updater and skipped by 'Update All'.") : I18n.tr("No packages ignored. Add one here or hover an update in the popout and click the hide button.");
                        }
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                        bottomPadding: Theme.spacingS
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        DankTextField {
                            id: newIgnoredPackageField
                            width: parent.width - addIgnoredBtn.width - Theme.spacingS
                            height: 36
                            placeholderText: I18n.tr("Package name (e.g., docker)")
                            font.pixelSize: Theme.fontSizeSmall
                            onAccepted: ignoredPackagesCard.addIgnoredPackage()
                            onTextEdited: ignoredPackageError.visible = false
                        }

                        DankActionButton {
                            id: addIgnoredBtn
                            buttonSize: 36
                            iconName: "add"
                            iconSize: 20
                            backgroundColor: Theme.primary
                            iconColor: Theme.onPrimary
                            tooltipText: I18n.tr("Ignore package")
                            onClicked: ignoredPackagesCard.addIgnoredPackage()
                        }
                    }

                    StyledText {
                        id: ignoredPackageError
                        visible: false
                        text: I18n.tr("Invalid package name — letters, digits and @._+:- only.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                    }

                    SettingsCard {
                        width: parent.width
                        iconName: "visibility_off"
                        title: I18n.tr("Ignored (%1)").arg((SettingsData.updaterIgnoredPackages || []).length)
                        collapsible: true
                        expanded: false
                        visible: (SettingsData.updaterIgnoredPackages || []).length > 0
                        color: Theme.withAlpha(Theme.surfaceContainer, 0.5)

                        Repeater {
                            model: SettingsData.updaterIgnoredPackages

                            delegate: Rectangle {
                                required property string modelData
                                required property int index

                                width: parent.width
                                height: 40
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.surfaceContainer, 0.5)

                                DankIcon {
                                    id: ignoredIcon
                                    anchors.left: parent.left
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "visibility_off"
                                    size: 18
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    anchors.left: ignoredIcon.right
                                    anchors.leftMargin: Theme.spacingS
                                    anchors.right: removeIgnoredBtn.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: parent.modelData
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                DankActionButton {
                                    id: removeIgnoredBtn
                                    anchors.right: parent.right
                                    anchors.rightMargin: Theme.spacingXS
                                    anchors.verticalCenter: parent.verticalCenter
                                    buttonSize: 32
                                    iconName: "delete"
                                    iconSize: 18
                                    iconColor: Theme.error
                                    backgroundColor: "transparent"
                                    tooltipText: I18n.tr("Stop ignoring %1").arg(parent.modelData)
                                    onClicked: {
                                        const list = (SettingsData.updaterIgnoredPackages || []).slice();
                                        list.splice(parent.index, 1);
                                        SettingsData.set("updaterIgnoredPackages", list);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                width: parent.width
                iconName: "tune"
                title: I18n.tr("Advanced")
                settingKey: "systemUpdaterAdvanced"

                SettingsToggleRow {
                    text: I18n.tr("Use Custom Command")
                    description: I18n.tr("Open a terminal and run a custom command instead of the in-shell upgrade flow.")
                    checked: SettingsData.updaterUseCustomCommand
                    onToggled: checked => {
                        if (!checked) {
                            updaterCustomCommand.text = "";
                            updaterTerminalCustomClass.text = "";
                            SettingsData.set("updaterCustomCommand", "");
                            SettingsData.set("updaterTerminalAdditionalParams", "");
                        }
                        SettingsData.set("updaterUseCustomCommand", checked);
                    }
                }

                Rectangle {
                    width: parent.width - Theme.spacingM * 2
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    visible: SettingsData.updaterUseCustomCommand
                    height: warnText.implicitHeight + Theme.spacingS * 2
                    radius: Theme.cornerRadius
                    color: Theme.warningHover

                    StyledText {
                        id: warnText
                        anchors.fill: parent
                        anchors.margins: Theme.spacingS
                        text: I18n.tr("Custom command and terminal params are split on whitespace; paths with spaces will break.")
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                        wrapMode: Text.WordWrap
                    }
                }

                FocusScope {
                    width: parent.width - Theme.spacingM * 2
                    height: customCommandColumn.implicitHeight
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    visible: SettingsData.updaterUseCustomCommand

                    Column {
                        id: customCommandColumn
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Custom update command")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankTextField {
                            id: updaterCustomCommand
                            width: parent.width
                            placeholderText: "topgrade --no-retry"
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.outlineMedium
                            focusedBorderColor: Theme.primary

                            Component.onCompleted: {
                                if (SettingsData.updaterCustomCommand) {
                                    text = SettingsData.updaterCustomCommand;
                                }
                            }

                            onTextEdited: SettingsData.set("updaterCustomCommand", text.trim())

                            MouseArea {
                                anchors.fill: parent
                                onPressed: mouse => {
                                    updaterCustomCommand.forceActiveFocus();
                                    mouse.accepted = false;
                                }
                            }
                        }
                    }
                }

                FocusScope {
                    width: parent.width - Theme.spacingM * 2
                    height: terminalParamsColumn.implicitHeight
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    visible: SettingsData.updaterUseCustomCommand

                    Column {
                        id: terminalParamsColumn
                        width: parent.width
                        spacing: Theme.spacingXS

                        StyledText {
                            text: I18n.tr("Terminal additional parameters")
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        DankTextField {
                            id: updaterTerminalCustomClass
                            width: parent.width
                            placeholderText: "-T updater"
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.outlineMedium
                            focusedBorderColor: Theme.primary

                            Component.onCompleted: {
                                if (SettingsData.updaterTerminalAdditionalParams) {
                                    text = SettingsData.updaterTerminalAdditionalParams;
                                }
                            }

                            onTextEdited: SettingsData.set("updaterTerminalAdditionalParams", text.trim())

                            MouseArea {
                                anchors.fill: parent
                                onPressed: mouse => {
                                    updaterTerminalCustomClass.forceActiveFocus();
                                    mouse.accepted = false;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
