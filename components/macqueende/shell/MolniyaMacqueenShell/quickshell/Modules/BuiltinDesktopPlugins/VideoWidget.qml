import QtQuick
import QtMultimedia
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    property real widgetWidth: 480
    property real widgetHeight: 270
    property real defaultWidth: 480
    property real defaultHeight: 270
    property real minWidth: 180
    property real minHeight: 120

    property string instanceId: ""
    property var instanceData: null

    readonly property var cfg: instanceData?.config ?? ({})
    readonly property string configuredPath: cfg.videoPath ?? ""
    readonly property bool muted: cfg.muted ?? true
    readonly property real videoOpacity: Math.max(0, Math.min(1, cfg.opacity ?? 1.0))
    readonly property string configuredFillMode: cfg.fillMode ?? "crop"
    property string playbackError: ""
    readonly property url videoSource: {
        const path = configuredPath.trim();
        if (!path)
            return "";
        if (path.startsWith("file://"))
            return path;
        return "file://" + path;
    }

    function setMuted(value) {
        if (!instanceId)
            return;
        SettingsData.updateDesktopWidgetInstanceConfig(instanceId, {
            muted: value
        });
    }

    Rectangle {
        id: videoFrame
        anchors.fill: parent
        radius: Theme.cornerRadius
        color: "black"
        opacity: root.videoOpacity
        clip: true

        Video {
            id: videoPlayer
            anchors.fill: parent
            source: root.videoSource
            volume: root.muted ? 0 : 1
            loops: MediaPlayer.Infinite
            fillMode: {
                switch (root.configuredFillMode) {
                case "fit":
                    return VideoOutput.PreserveAspectFit;
                case "stretch":
                    return VideoOutput.Stretch;
                default:
                    return VideoOutput.PreserveAspectCrop;
                }
            }

            Component.onCompleted: {
                if (source.toString())
                    play();
            }

            onSourceChanged: {
                root.playbackError = "";
                stop();
                if (source.toString())
                    play();
            }

            onErrorOccurred: (error, errorString) => root.playbackError = errorString
        }
    }

    Connections {
        target: SessionService

        function onSessionResumed() {
            if (videoPlayer.source.toString())
                videoPlayer.play();
        }
    }

    Column {
        anchors.centerIn: parent
        width: Math.max(0, parent.width - Theme.spacingXL * 2)
        spacing: Theme.spacingS
        visible: root.videoSource.toString() === "" || root.playbackError !== ""

        DankIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "movie"
            size: Theme.iconSizeLarge
            color: Theme.surfaceVariantText
        }

        StyledText {
            width: parent.width
            text: root.playbackError || I18n.tr("Choose a video in widget settings")
            color: Theme.surfaceVariantText
            font.pixelSize: Theme.fontSizeSmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }

    Rectangle {
        id: soundButton
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spacingS
        width: 40
        height: 40
        radius: width / 2
        color: soundArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.outlineLight
        visible: root.videoSource.toString() !== "" && root.playbackError === ""

        DankIcon {
            anchors.centerIn: parent
            name: root.muted ? "volume_off" : "volume_up"
            size: Theme.iconSizeMedium
            color: Theme.surfaceText
        }

        MouseArea {
            id: soundArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setMuted(!root.muted)
        }
    }
}
