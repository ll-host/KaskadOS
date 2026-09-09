import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Column {
    id: root

    readonly property var notes: ChangelogService.releaseNotes || ({})
    readonly property var features: notes.features || []
    readonly property var upgradeNotes: notes.notes || []
    readonly property real logoSize: Math.round(Theme.iconSize * 2.8)
    readonly property real badgeHeight: Math.round(Theme.fontSizeSmall * 1.7)

    topPadding: Theme.spacingL
    spacing: Theme.spacingL

    Column {
        width: parent.width
        spacing: Theme.spacingM

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingM

            Rectangle {
                width: root.logoSize
                height: root.logoSize
                radius: width / 2
                color: Theme.primaryContainer
                anchors.verticalCenter: parent.verticalCenter

                DankIcon {
                    anchors.centerIn: parent
                    name: "deployed_code_update"
                    size: Theme.iconSizeLarge
                    color: Theme.primary
                }
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                Row {
                    spacing: Theme.spacingS

                    StyledText {
                        text: "MacqueenDE " + ChangelogService.currentVersion
                        font.pixelSize: Theme.fontSizeXLarge + 2
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Rectangle {
                        visible: ChangelogService.channel.length > 0
                        width: channelText.implicitWidth + Theme.spacingM * 2
                        height: root.badgeHeight
                        radius: root.badgeHeight / 2
                        color: Theme.primaryContainer
                        anchors.verticalCenter: parent.verticalCenter

                        StyledText {
                            id: channelText
                            anchors.centerIn: parent
                            text: ChangelogService.channel
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.primary
                        }
                    }
                }

                StyledText {
                    width: Math.min(420, implicitWidth)
                    text: root.notes.summary || "MacqueenDE обновлён."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outlineMedium
        opacity: 0.3
    }

    Column {
        visible: root.features.length > 0
        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            text: "Что изменилось"
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        Grid {
            width: parent.width
            columns: 2
            rowSpacing: Theme.spacingS
            columnSpacing: Theme.spacingS

            Repeater {
                model: root.features

                delegate: ChangelogFeatureCard {
                    required property var modelData

                    width: (root.width - Theme.spacingS) / 2
                    iconName: String(modelData.icon || "new_releases")
                    title: String(modelData.title || "")
                    description: String(modelData.description || "")
                }
            }
        }
    }

    Rectangle {
        visible: root.upgradeNotes.length > 0
        width: parent.width
        height: 1
        color: Theme.outlineMedium
        opacity: 0.3
    }

    Column {
        visible: root.upgradeNotes.length > 0
        width: parent.width
        spacing: Theme.spacingS

        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: ChangelogService.sessionRestartRequired ? "restart_alt" : "info"
                size: Theme.iconSizeSmall
                color: Theme.primary
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: ChangelogService.sessionRestartRequired
                    ? "Завершение обновления"
                    : "Примечания"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Rectangle {
            width: parent.width
            height: notesColumn.implicitHeight + Theme.spacingM * 2
            radius: Theme.cornerRadius
            color: Theme.primaryHover
            border.width: 1
            border.color: Theme.withAlpha(Theme.primary, 0.2)

            Column {
                id: notesColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingM
                spacing: Theme.spacingS

                Repeater {
                    model: root.upgradeNotes

                    delegate: ChangelogUpgradeNote {
                        required property var modelData

                        width: notesColumn.width
                        text: String(modelData)
                    }
                }
            }
        }
    }
}
