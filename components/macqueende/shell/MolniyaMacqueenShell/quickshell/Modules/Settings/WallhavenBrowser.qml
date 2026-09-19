pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Settings.Widgets

SettingsCard {
    id: root

    property bool showCloseButton: true

    signal closeRequested
    signal applyWallpaper(string path)

    tab: "wallpaper"
    tags: ["wallpaper", "online", "wallhaven", "search", "download"]
    title: "Онлайн-обои"
    settingKey: "onlineWallpapers"
    iconName: "travel_explore"

    onVisibleChanged: {
        if (visible && WallhavenService.results.length === 0 && !WallhavenService.loading)
            WallhavenService.search("", 1);
    }

    readonly property Connections wallhavenConnection: Connections {
        target: WallhavenService

        function onWallpaperDownloaded(path) {
            root.applyWallpaper(path);
        }
    }

    headerActions: [
        DankActionButton {
            buttonSize: 32
            iconName: "close"
            iconSize: Theme.iconSizeSmall
            backgroundColor: "transparent"
            iconColor: Theme.surfaceVariantText
            visible: root.showCloseButton
            onClicked: root.closeRequested()
        }
    ]

    StyledText {
        width: parent.width
        text: "Найдите обои, посмотрите превью и примените их прямо здесь."
        color: Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankTextField {
            id: searchField
            width: parent.width - searchButton.width - randomButton.width - Theme.spacingS * 2
            placeholderText: "Горы, космос, минимализм…"
            text: WallhavenService.query
            backgroundColor: Theme.surfaceContainerHighest
            onAccepted: WallhavenService.search(text, 1)
        }

        DankActionButton {
            id: searchButton
            buttonSize: 40
            iconName: "search"
            iconSize: Theme.iconSize
            enabled: !WallhavenService.loading
            backgroundColor: Theme.primary
            iconColor: Theme.onPrimary
            onClicked: WallhavenService.search(searchField.text, 1)
        }

        DankActionButton {
            id: randomButton
            buttonSize: 40
            iconName: "shuffle"
            iconSize: Theme.iconSize
            enabled: !WallhavenService.loading
            backgroundColor: Theme.surfaceContainerHighest
            iconColor: Theme.surfaceText
            onClicked: WallhavenService.random()
        }
    }

    StyledRect {
        width: parent.width
        height: 354
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        clip: true

        GridView {
            id: wallpaperGrid
            anchors.fill: parent
            anchors.margins: Theme.spacingS
            cellWidth: width / 2
            cellHeight: 112
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: WallhavenService.results

            delegate: Item {
                id: wallpaperDelegate
                required property var modelData
                width: wallpaperGrid.cellWidth
                height: wallpaperGrid.cellHeight

                StyledRect {
                    anchors.fill: parent
                    anchors.margins: Theme.spacingXS
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainerHighest
                    border.width: WallhavenService.selectedWallpaper?.id === wallpaperDelegate.modelData.id ? 2 : 0
                    border.color: Theme.primary
                    clip: true

                    Image {
                        anchors.fill: parent
                        source: wallpaperDelegate.modelData.thumbs?.large || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                    }

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 30
                        color: Qt.rgba(0, 0, 0, 0.68)

                        StyledText {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            text: wallpaperDelegate.modelData.resolution || ""
                            color: "white"
                            font.pixelSize: Theme.fontSizeSmall
                            verticalAlignment: Text.AlignVCenter
                            horizontalAlignment: Text.AlignLeft
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: WallhavenService.selectedWallpaper = wallpaperDelegate.modelData
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: WallhavenService.loading
                text: I18n.tr("Loading wallpapers…")
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeMedium
            }

            Column {
                anchors.centerIn: parent
                spacing: Theme.spacingS
                visible: !WallhavenService.loading && WallhavenService.results.length === 0

                DankIcon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    name: "image_search"
                    size: Theme.iconSizeLarge
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: WallhavenService.error || "Ничего не найдено"
                    color: Theme.surfaceVariantText
                    font.pixelSize: Theme.fontSizeMedium
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    width: Math.min(320, wallpaperGrid.width - Theme.spacingL * 2)
                }

                DankButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: WallhavenService.error !== ""
                    text: "Повторить"
                    enabled: !WallhavenService.loading
                    onClicked: WallhavenService.search(searchField.text, WallhavenService.page || 1)
                }
            }
        }
    }

    Row {
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            id: previousButton
            text: "Назад"
            enabled: WallhavenService.page > 1 && !WallhavenService.loading
            onClicked: WallhavenService.previousPage()
        }

        Item {
            width: parent.width - previousButton.width - nextButton.width
                   - applyButton.width - Theme.spacingS * 3
            height: 1

            StyledText {
                anchors.centerIn: parent
                text: "Страница " + WallhavenService.page
                color: Theme.surfaceVariantText
                font.pixelSize: Theme.fontSizeSmall
            }
        }

        DankButton {
            id: nextButton
            text: "Далее"
            enabled: WallhavenService.page < WallhavenService.lastPage && !WallhavenService.loading
            onClicked: WallhavenService.nextPage()
        }

        DankButton {
            id: applyButton
            text: WallhavenService.downloading ? "Загрузка…" : "Скачать и применить"
            enabled: WallhavenService.selectedWallpaper !== null && !WallhavenService.downloading
            onClicked: WallhavenService.download(WallhavenService.selectedWallpaper)
        }
    }

    StyledText {
        width: parent.width
        visible: WallhavenService.selectedWallpaper !== null
        text: {
            const item = WallhavenService.selectedWallpaper;
            return item ? I18n.tr("Selected:") + " " + (item.resolution || item.id) : "";
        }
        color: Theme.primary
        font.pixelSize: Theme.fontSizeSmall
        elide: Text.ElideRight
    }

    StyledText {
        width: parent.width
        visible: WallhavenService.downloadError !== ""
        text: WallhavenService.downloadError
        color: Theme.error
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }
}
