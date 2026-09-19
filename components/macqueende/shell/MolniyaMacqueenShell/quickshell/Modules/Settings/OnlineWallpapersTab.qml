import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    DankFlickable {
        anchors.fill: parent
        clip: true
        contentWidth: width
        contentHeight: contentColumn.implicitHeight + Theme.spacingXL * 2

        Column {
            id: contentColumn
            width: Math.min(700, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            topPadding: Theme.spacingXL
            bottomPadding: Theme.spacingXL
            spacing: Theme.spacingL

            WallhavenBrowser {
                width: parent.width
                showCloseButton: false
                onApplyWallpaper: path => {
                    if (path)
                        SessionData.setWallpaper(path);
                }
            }
        }
    }
}
