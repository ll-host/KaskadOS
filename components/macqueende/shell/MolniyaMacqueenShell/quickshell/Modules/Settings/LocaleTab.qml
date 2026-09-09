import Macqueen.Ipc
import QtQuick
import qs.Common
import qs.Modules.Settings.Widgets
import qs.Widgets

Item {
    id: localeTab

    readonly property string _systemDefaultLabel: I18n.tr("System Default")
    property bool shortcutRecording: false

    function startShortcutRecording() {
        shortcutRecording = true;
        shortcutField.forceActiveFocus();
        Macqueen.setShortcutCaptureActive(true);
    }

    function stopShortcutRecording() {
        if (!shortcutRecording)
            return;

        shortcutRecording = false;
        Macqueen.setShortcutCaptureActive(false);
    }

    function availableLayoutOptions() {
        const configured = Macqueen.keyboardLayouts.map((layout) => {
            return layout.code;
        });
        return Macqueen.availableKeyboardLayouts.filter((layout) => {
            return !configured.includes(layout.code);
        }).map((layout) => {
            return `${layout.name} (${layout.code})`;
        });
    }

    function codeForLayoutOption(option) {
        const match = option.match(/\(([^()]+)\)$/);
        return match ? match[1] : "";
    }

    function addLayout(code) {
        if (!code)
            return ;

        const current = Macqueen.keyboardLayouts.map((layout) => {
            return layout.code;
        });
        if (!current.includes(code))
            Macqueen.setKeyboardLayouts(current.concat([code]));

    }

    function removeLayout(code) {
        const current = Macqueen.keyboardLayouts.map((layout) => {
            return layout.code;
        });
        if (current.length <= 1)
            return ;

        Macqueen.setKeyboardLayouts(current.filter((layout) => {
            return layout !== code;
        }));
    }

    function _localeDisplayName(localeCode) {
        if (!I18n.presentLocales[localeCode])
            return ;

        const nativeName = I18n.presentLocales[localeCode].nativeLanguageName;
        return nativeName[0].toUpperCase() + nativeName.slice(1);
    }

    function _allLocaleOptions() {
        return [_systemDefaultLabel].concat(Object.keys(I18n.presentLocales).map(_localeDisplayName));
    }

    function _codeForDisplayName(displayName) {
        if (displayName === _systemDefaultLabel)
            return "";

        for (const code of Object.keys(I18n.presentLocales)) {
            if (_localeDisplayName(code) === displayName)
                return code;

        }
        return "";
    }

    Component.onDestruction: {
        if (shortcutRecording)
            Macqueen.setShortcutCaptureActive(false);
    }

    Connections {
        target: Macqueen

        function onShortcutCaptured(shortcut) {
            if (!localeTab.shortcutRecording)
                return;

            localeTab.stopShortcutRecording();
            Macqueen.setKeyboardLayoutShortcut(shortcut);
        }
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
                tab: "locale"
                tags: ["locale", "language", "country"]
                title: I18n.tr("General")
                iconName: "language"

                SettingsDropdownRow {
                    id: localeDropdown

                    tab: "locale"
                    tags: ["locale", "language", "country"]
                    settingKey: "locale"
                    text: I18n.tr("Current Locale")
                    description: I18n.tr("Change the locale used by the DMS interface.")
                    options: localeTab._allLocaleOptions()
                    enableFuzzySearch: true
                    Component.onCompleted: {
                        currentValue = SessionData.locale ? localeTab._localeDisplayName(SessionData.locale) : localeTab._systemDefaultLabel;
                    }
                    onValueChanged: (value) => {
                        SessionData.set("locale", localeTab._codeForDisplayName(value));
                    }
                }

                SettingsDropdownRow {
                    id: timeLocaleDropdown

                    tab: "locale"
                    tags: ["locale", "time", "date", "format", "region"]
                    settingKey: "timeLocale"
                    text: I18n.tr("Time & Date Locale")
                    description: I18n.tr("Change the locale used for date and time formatting, independent of the interface language.")
                    options: localeTab._allLocaleOptions()
                    enableFuzzySearch: true
                    Component.onCompleted: {
                        currentValue = SessionData.timeLocale ? localeTab._localeDisplayName(SessionData.timeLocale) : localeTab._systemDefaultLabel;
                    }
                    onValueChanged: (value) => {
                        SessionData.set("timeLocale", localeTab._codeForDisplayName(value));
                    }
                }

            }

            SettingsCard {
                visible: Macqueen.available
                tab: "locale"
                tags: ["keyboard", "layout", "language", "input", "раскладка", "клавиатура"]
                title: I18n.tr("Keyboard Layouts")
                iconName: "keyboard"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Choose the languages used for typing. Click a layout to make it active.")
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                    }

                    Rectangle {
                        visible: Macqueen.protocolVersion >= 10
                        width: parent.width
                        height: shortcutRow.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Row {
                            id: shortcutRow

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            spacing: Theme.spacingM
                            height: Math.max(shortcutDescription.implicitHeight, shortcutField.height, resetShortcutButton.height)

                            Column {
                                id: shortcutDescription

                                width: Math.max(120, parent.width - shortcutField.width - resetShortcutButton.width - parent.spacing * 2)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    width: parent.width
                                    text: "Смена раскладки"
                                    color: Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    wrapMode: Text.WordWrap
                                }

                                StyledText {
                                    width: parent.width
                                    text: localeTab.shortcutRecording ? "Нажмите новое сочетание клавиш" : "Нажмите на сочетание, чтобы изменить"
                                    color: localeTab.shortcutRecording ? Theme.primary : Theme.surfaceVariantText
                                    font.pixelSize: Theme.fontSizeSmall
                                    wrapMode: Text.WordWrap
                                }
                            }

                            FocusScope {
                                id: shortcutField

                                width: 142
                                height: 40
                                anchors.verticalCenter: parent.verticalCenter
                                activeFocusOnTab: true

                                Keys.onPressed: event => {
                                    if (event.key === Qt.Key_Escape) {
                                        localeTab.stopShortcutRecording();
                                        event.accepted = true;
                                    }
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Theme.cornerRadius
                                    color: localeTab.shortcutRecording ? Theme.primaryContainer : Theme.surfaceContainerHighest
                                    border.width: localeTab.shortcutRecording || shortcutField.activeFocus ? 2 : 1
                                    border.color: localeTab.shortcutRecording ? Theme.primary : Theme.outlineVariant
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    width: parent.width - Theme.spacingM * 2
                                    text: localeTab.shortcutRecording ? "Запись…" : (Macqueen.keyboardLayoutShortcut || "Alt+Shift")
                                    color: localeTab.shortcutRecording ? Theme.primary : Theme.surfaceText
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    horizontalAlignment: Text.AlignHCenter
                                    elide: Text.ElideRight
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (localeTab.shortcutRecording)
                                            localeTab.stopShortcutRecording();
                                        else
                                            localeTab.startShortcutRecording();
                                    }
                                }
                            }

                            DankButton {
                                id: resetShortcutButton

                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "refresh"
                                text: "Сброс"
                                buttonHeight: 40
                                horizontalPadding: 9
                                backgroundColor: "transparent"
                                textColor: Theme.surfaceVariantText
                                onClicked: {
                                    localeTab.stopShortcutRecording();
                                    Macqueen.resetKeyboardLayoutShortcut();
                                }
                            }
                        }
                    }

                    Repeater {
                        model: Macqueen.keyboardLayouts

                        delegate: Rectangle {
                            required property var modelData

                            width: parent ? parent.width : 0
                            height: 48
                            radius: Theme.cornerRadius
                            color: modelData.active ? Theme.primaryContainer : Theme.surfaceContainerHigh

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Macqueen.setCurrentKeyboardLayout(modelData.index)
                            }

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.name || modelData.code.toUpperCase()
                                color: modelData.active ? Theme.primary : Theme.surfaceText
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: modelData.active ? Font.DemiBold : Font.Normal
                            }

                            StyledText {
                                anchors.right: removeButton.left
                                anchors.rightMargin: Theme.spacingM
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData.code.toUpperCase()
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            DankButton {
                                id: removeButton

                                anchors.right: parent.right
                                anchors.rightMargin: Theme.spacingS
                                anchors.verticalCenter: parent.verticalCenter
                                iconName: "delete"
                                buttonHeight: 32
                                horizontalPadding: 6
                                backgroundColor: "transparent"
                                textColor: enabled ? Theme.error : Theme.surfaceVariantText
                                enabled: Macqueen.keyboardLayouts.length > 1
                                onClicked: localeTab.removeLayout(modelData.code)
                            }

                        }

                    }

                    SettingsDropdownRow {
                        id: addLayoutDropdown

                        width: parent.width
                        tab: "locale"
                        tags: ["keyboard", "layout", "add", "language"]
                        settingKey: "keyboardLayoutToAdd"
                        text: I18n.tr("Add keyboard layout")
                        description: I18n.tr("Select any layout installed by the system.")
                        options: localeTab.availableLayoutOptions()
                        enableFuzzySearch: true
                        emptyText: I18n.tr("Choose a layout…")
                        onValueChanged: (value) => {
                            localeTab.addLayout(localeTab.codeForLayoutOption(value));
                            currentValue = "";
                        }
                    }

                    StyledText {
                        visible: Macqueen.keyboardLayouts.length === 1
                        width: parent.width
                        text: I18n.tr("The last keyboard layout cannot be removed.")
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                        wrapMode: Text.WordWrap
                    }

                }

            }

        }

    }

}
