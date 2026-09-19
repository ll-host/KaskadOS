import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Rectangle {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property bool editMode: false
    signal powerButtonClicked
    signal lockRequested
    signal editModeToggled
    signal settingsButtonClicked

    implicitHeight: 70
    radius: Theme.cornerRadius
    color: Theme.nestedSurface
    border.color: Theme.outlineMedium
    border.width: Theme.layerOutlineWidth

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

            Typography {
                width: parent.width
                text: UserInfoService.hostname || "localhost"
                style: Typography.Style.Caption
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
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
