pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.FileBrowser
import qs.Widgets
import qs.Modules.Settings.Widgets

Column {
    id: root

    property string instanceId: ""
    property var instanceData: null

    readonly property var cfg: instanceData?.config ?? ({})

    function updateConfig(key, value) {
        if (!instanceId)
            return;
        var updates = {};
        updates[key] = value;
        SettingsData.updateDesktopWidgetInstanceConfig(instanceId, updates);
    }

    function cleanPath(path) {
        const cleaned = path.toString().replace(/^file:\/\//, "");
        try {
            return decodeURI(cleaned);
        } catch (error) {
            return cleaned;
        }
    }

    width: parent?.width ?? 400
    spacing: 0

    FileBrowserModal {
        id: videoBrowser
        browserTitle: I18n.tr("Select Video")
        browserIcon: "movie"
        browserType: "video_widget"
        showHiddenFiles: true
        fileExtensions: ["*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.m4v"]

        onFileSelected: path => {
            root.updateConfig("videoPath", root.cleanPath(path));
            close();
        }
    }

    Item {
        width: parent.width
        height: videoPathColumn.height + Theme.spacingM * 2

        Column {
            id: videoPathColumn
            x: Theme.spacingM
            width: parent.width - Theme.spacingM * 2
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                text: I18n.tr("Video file")
                color: Theme.surfaceText
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: videoPathField
                    width: parent.width - browseButton.width - clearButton.width - Theme.spacingS * 2
                    text: root.cfg.videoPath ?? ""
                    placeholderText: I18n.tr("Choose a local video")
                    backgroundColor: Theme.surfaceContainerHighest
                    onEditingFinished: root.updateConfig("videoPath", root.cleanPath(text))
                }

                DankButton {
                    id: browseButton
                    iconName: "folder_open"
                    buttonHeight: 38
                    horizontalPadding: Theme.spacingM
                    onClicked: videoBrowser.open()
                }

                DankButton {
                    id: clearButton
                    iconName: "close"
                    buttonHeight: 38
                    horizontalPadding: Theme.spacingM
                    enabled: (root.cfg.videoPath ?? "") !== ""
                    onClicked: root.updateConfig("videoPath", "")
                }
            }
        }
    }

    SettingsDivider {}

    SettingsToggleRow {
        text: I18n.tr("Play sound")
        description: I18n.tr("Sound is muted by default and can also be toggled on the widget")
        checked: !(root.cfg.muted ?? true)
        onToggled: checked => root.updateConfig("muted", !checked)
    }

    SettingsDivider {}

    SettingsSliderRow {
        text: I18n.tr("Opacity")
        minimum: 0
        maximum: 100
        value: Math.round((root.cfg.opacity ?? 1.0) * 100)
        unit: "%"
        defaultValue: 100
        onSliderValueChanged: value => root.updateConfig("opacity", value / 100)
    }

    SettingsDivider {}

    SettingsDropdownRow {
        text: I18n.tr("Video scaling")
        options: [I18n.tr("Crop"), I18n.tr("Fit"), I18n.tr("Stretch")]
        currentValue: {
            switch (root.cfg.fillMode ?? "crop") {
            case "fit":
                return I18n.tr("Fit");
            case "stretch":
                return I18n.tr("Stretch");
            default:
                return I18n.tr("Crop");
            }
        }
        onValueChanged: value => {
            if (value === I18n.tr("Fit"))
                root.updateConfig("fillMode", "fit");
            else if (value === I18n.tr("Stretch"))
                root.updateConfig("fillMode", "stretch");
            else
                root.updateConfig("fillMode", "crop");
        }
    }

    SettingsDivider {}

    SettingsDisplayPicker {
        displayPreferences: root.cfg.displayPreferences ?? ["all"]
        onPreferencesChanged: preferences => root.updateConfig("displayPreferences", preferences)
    }
}
