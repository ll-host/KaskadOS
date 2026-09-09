import QtQuick
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property bool editMode: false
    property bool updateInfoChecked: false
    property bool updateInfoLoading: false
    property string lastSystemUpdate: ""
    property string updateInfoError: ""
    property string updateInfoProcessError: ""

    readonly property string pacmanLogParser: "/\\[PACMAN\\] Running 'pacman / { fullUpgrade = ($0 ~ /Running 'pacman -Syu([[:space:]]|')/); transaction = 0 } /\\[ALPM\\] transaction started/ { if (fullUpgrade) transaction = 1 } /\\[ALPM\\] transaction completed/ { if (fullUpgrade && transaction) { timestamp = $1; gsub(/^\\[|\\]$/, \"\", timestamp); last = timestamp; fullUpgrade = 0; transaction = 0 } } END { if (last) print last }"

    signal powerButtonClicked
    signal lockRequested
    signal editModeToggled
    signal settingsButtonClicked

    function refreshLastSystemUpdate() {
        if (lastSystemUpdateProcess.running)
            return;

        updateInfoLoading = true;
        updateInfoError = "";
        updateInfoProcessError = "";
        lastSystemUpdateProcess.running = true;
    }

    function formatLastSystemUpdate(timestamp) {
        const normalizedTimestamp = timestamp.replace(/([+-]\d{2})(\d{2})$/, "$1:$2");
        const updateDate = new Date(normalizedTimestamp);
        if (isNaN(updateDate.getTime()))
            return "";
        return Qt.formatDateTime(updateDate, "dd.MM.yyyy, HH:mm");
    }

    function updateInfoText() {
        if (updateInfoLoading)
            return "Проверка последнего обновления…";
        if (updateInfoError)
            return updateInfoError;
        if (!updateInfoChecked)
            return "Обновление системы: нажмите ↻";
        if (!lastSystemUpdate)
            return "Обновления через pacman -Syu не найдены";

        const formattedDate = formatLastSystemUpdate(lastSystemUpdate);
        return formattedDate ? "Обновлено: " + formattedDate : "Не удалось определить дату обновления";
    }

    implicitHeight: 70
    radius: Theme.cornerRadius
    color: Theme.nestedSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth

    Process {
        id: lastSystemUpdateProcess

        command: ["awk", root.pacmanLogParser, "/var/log/pacman.log"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: root.lastSystemUpdate = text.trim()
        }

        stderr: StdioCollector {
            onStreamFinished: root.updateInfoProcessError = text.trim()
        }

        onExited: exitCode => {
            root.updateInfoLoading = false;
            root.updateInfoChecked = true;
            if (exitCode !== 0)
                root.updateInfoError = root.updateInfoProcessError || "Не удалось прочитать журнал pacman";
        }
    }

    Row {
        anchors.left: parent.left
        anchors.right: actionButtonsRow.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spacingL
        anchors.rightMargin: Theme.spacingS
        spacing: Theme.spacingM

        DankCircularImage {
            id: avatarContainer

            width: 60
            height: 60
            imageSource: {
                if (PortalService.profileImage === "")
                    return "";

                if (PortalService.profileImage.startsWith("/"))
                    return "file://" + PortalService.profileImage;

                return PortalService.profileImage;
            }
            fallbackIcon: "person"
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - avatarContainer.width - parent.spacing
            spacing: Theme.spacingXXS

            Typography {
                width: parent.width
                text: UserInfoService.fullName || UserInfoService.username || I18n.tr("User")
                style: Typography.Style.Subtitle
                color: Theme.surfaceText
                elide: Text.ElideRight
            }

            Row {
                width: parent.width
                spacing: Theme.spacingXXS

                Typography {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - refreshUpdateInfoButton.width - parent.spacing
                    text: root.updateInfoText()
                    style: Typography.Style.Caption
                    color: root.updateInfoError ? Theme.error : Theme.surfaceVariantText
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                }

                DankActionButton {
                    id: refreshUpdateInfoButton

                    buttonSize: 22
                    iconName: root.updateInfoLoading ? "sync" : "refresh"
                    iconSize: 14
                    iconColor: root.updateInfoLoading ? Theme.outline : Theme.primary
                    backgroundColor: "transparent"
                    enabled: !root.updateInfoLoading
                    onClicked: root.refreshLastSystemUpdate()
                }
            }
        }
    }

    Row {
        id: actionButtonsRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Theme.spacingXS
        spacing: Theme.spacingXS

        DankActionButton {
            buttonSize: 36
            iconName: "lock"
            iconSize: Theme.iconSize - 4
            iconColor: Theme.surfaceText
            backgroundColor: "transparent"
            onClicked: {
                root.lockRequested();
            }
        }

        DankActionButton {
            buttonSize: 36
            iconName: "power_settings_new"
            iconSize: Theme.iconSize - 4
            iconColor: Theme.surfaceText
            backgroundColor: "transparent"
            onClicked: root.powerButtonClicked()
        }

        DankActionButton {
            buttonSize: 36
            iconName: "settings"
            iconSize: Theme.iconSize - 4
            iconColor: Theme.surfaceText
            backgroundColor: "transparent"
            onClicked: {
                root.settingsButtonClicked();
                PopoutService.focusOrToggleSettings();
            }
        }

        DankActionButton {
            buttonSize: 36
            iconName: editMode ? "done" : "edit"
            iconSize: Theme.iconSize - 4
            iconColor: editMode ? Theme.primary : Theme.surfaceText
            backgroundColor: "transparent"
            onClicked: root.editModeToggled()
        }
    }
}
