import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets

DankModal {
    id: root

    shouldBeVisible: false
    allowStacking: true
    useOverlayLayer: true
    modalWidth: 470
    modalHeight: contentLoader.item ? contentLoader.item.implicitHeight + Theme.spacingL * 2 : 330

    content: Component {
        FocusScope {
            implicitHeight: contentColumn.implicitHeight
            focus: true

            Keys.onEscapePressed: event => {
                root.close();
                event.accepted = true;
            }

            Column {
                id: contentColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Theme.spacingL
                spacing: Theme.spacingM

                Rectangle {
                    width: 52
                    height: 52
                    radius: 26
                    color: Theme.primaryContainer

                    DankIcon {
                        anchors.centerIn: parent
                        name: "system_update"
                        size: 28
                        color: Theme.onPrimaryContainer
                    }
                }

                StyledText {
                    width: parent.width
                    text: "Автоматические обновления"
                    font.pixelSize: Theme.fontSizeXLarge
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }

                StyledText {
                    width: parent.width
                    text: "По умолчанию KaskadOS проверяет обновления раз в день после 03:00 и начинает установку, когда компьютер не используется 30 минут. На ноутбуке установка ждёт подключения питания."
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Rectangle {
                    width: parent.width
                    height: detailsRow.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest

                    Row {
                        id: detailsRow
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        DankIcon {
                            name: "verified_user"
                            size: 20
                            color: Theme.primary
                        }

                        StyledText {
                            width: parent.width - 28
                            text: "Если обновление прервётся или останутся пакеты, система проверит результат и повторит попытку в этом же сеансе."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    spacing: Theme.spacingS

                    DankButton {
                        text: "Настроить"
                        iconName: "tune"
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        onClicked: {
                            root.close();
                            PopoutService.openSettingsWithTab("updater");
                        }
                    }

                    DankButton {
                        text: "Подходит"
                        iconName: "check"
                        backgroundColor: Theme.primary
                        textColor: Theme.primaryText
                        onClicked: {
                            SystemUpdateService.confirmDefaultSchedule();
                            root.close();
                        }
                    }
                }
            }
        }
    }
}
