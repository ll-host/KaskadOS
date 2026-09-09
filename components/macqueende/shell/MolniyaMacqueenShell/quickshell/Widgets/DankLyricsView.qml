import QtQuick
import qs.Common
import qs.Services

Item {
    id: root

    property var activePlayer
    property int currentIndex: -1
    property color accent: MediaAccentService.accent
    readonly property string trackTitle: activePlayer?.trackTitle || MprisController.stableTitle || ""
    readonly property string trackArtist: activePlayer?.trackArtist || MprisController.stableArtist || ""
    readonly property int lyricCount: LyricsService.lines?.length || 0
    readonly property real lyricProgress: lyricCount > 0 && currentIndex >= 0 ? Math.min(1, (currentIndex + 1) / lyricCount) : 0

    function localizedLyricsError(message) {
        const normalized = String(message || "").toLowerCase();
        if (normalized.includes("not synchronized"))
            return I18n.tr("Lyrics are available, but not synchronized");
        return I18n.tr("Lyrics not found");
    }

    onCurrentIndexChanged: {
        if (currentIndex >= 0)
            lyrics.positionViewAtIndex(currentIndex, ListView.Center);
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"

        gradient: Gradient {
            GradientStop {
                position: 0
                color: Theme.withAlpha(root.accent, 0.12)
            }
            GradientStop {
                position: 0.3
                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.04)
            }
            GradientStop {
                position: 1
                color: Theme.withAlpha(Theme.surfaceContainerHighest, 0.18)
            }
        }
    }

    Item {
        id: lyricsHeader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: 14
        anchors.rightMargin: 50
        anchors.topMargin: 11
        height: 50

        Rectangle {
            id: headerIcon
            width: 34
            height: 34
            radius: 11
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.withAlpha(root.accent, 0.15)

            DankIcon {
                anchors.centerIn: parent
                name: "lyrics"
                size: 18
                color: root.accent
            }
        }

        Column {
            anchors.left: headerIcon.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Row {
                width: parent.width
                spacing: 7

                StyledText {
                    text: I18n.tr("Lyrics")
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }

                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: syncRow.implicitWidth
                    height: 16
                    visible: LyricsService.hasLyrics

                    Row {
                        id: syncRow
                        anchors.centerIn: parent
                        spacing: 4

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 5
                            height: 5
                            radius: 3
                            color: root.accent
                        }

                        StyledText {
                            text: root.currentIndex >= 0
                                ? (root.currentIndex + 1) + " / " + root.lyricCount
                                : "SYNC"
                            font.pixelSize: Math.max(8, Theme.fontSizeSmall - 2)
                            font.weight: Font.Medium
                            color: root.accent
                        }
                    }
                }
            }

            StyledText {
                width: parent.width
                text: root.trackTitle
                    ? (root.trackArtist ? root.trackTitle + " · " + root.trackArtist : root.trackTitle)
                    : I18n.tr("Current track")
                elide: Text.ElideRight
                maximumLineCount: 1
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                opacity: 0.72
            }
        }
    }

    Rectangle {
        id: headerProgressTrack
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: lyricsHeader.bottom
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        anchors.topMargin: 7
        height: 1
        radius: 1
        color: Theme.withAlpha(Theme.surfaceText, 0.1)
        visible: LyricsService.hasLyrics

        Rectangle {
            width: parent.width * root.lyricProgress
            height: parent.height
            radius: parent.radius
            color: root.accent

            Behavior on width {
                NumberAnimation {
                    duration: 320
                    easing.type: Easing.OutCubic
                }
            }
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: Theme.spacingS
        visible: LyricsService.loading || !LyricsService.hasLyrics
        width: parent.width - Theme.spacingL * 2

        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 54
            height: 54
            radius: 18
            color: Theme.withAlpha(root.accent, LyricsService.loading ? 0.16 : 0.09)

            DankIcon {
                id: emptyStateIcon
                anchors.centerIn: parent
                name: LyricsService.loading ? "progress_activity" : "lyrics"
                size: Theme.iconSize * 1.45
                color: LyricsService.loading ? root.accent : Theme.surfaceTextSecondary

                RotationAnimation on rotation {
                    running: LyricsService.loading
                    from: 0
                    to: 360
                    duration: 900
                    loops: Animation.Infinite
                }
            }
        }

        StyledText {
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            text: LyricsService.loading ? I18n.tr("Loading lyrics…")
                                        : root.localizedLyricsError(LyricsService.error)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: Theme.surfaceTextSecondary
            font.pixelSize: Theme.fontSizeSmall
        }
    }

    ListView {
        id: lyrics
        anchors.fill: parent
        anchors.topMargin: 76
        anchors.bottomMargin: 12
        anchors.leftMargin: 10
        anchors.rightMargin: 10
        visible: LyricsService.hasLyrics
        clip: true
        model: LyricsService.lines
        spacing: 1
        currentIndex: root.currentIndex
        cacheBuffer: height * 2
        highlightMoveDuration: 460
        highlightMoveVelocity: -1
        preferredHighlightBegin: height * 0.42
        preferredHighlightEnd: height * 0.58
        highlightRangeMode: ListView.ApplyRange
        boundsBehavior: Flickable.StopAtBounds

        delegate: Item {
            required property var modelData
            required property int index
            width: ListView.view.width
            readonly property bool currentLine: index === root.currentIndex
            readonly property int lineDistance: root.currentIndex < 0 ? 1 : Math.abs(index - root.currentIndex)
            readonly property bool pastLine: root.currentIndex >= 0 && index < root.currentIndex
            height: lyricText.implicitHeight + (currentLine ? 22 : 16)

            Rectangle {
                id: lineSurface
                anchors.fill: parent
                radius: Math.max(8, Theme.cornerRadius - 2)
                opacity: currentLine ? 1 : (lineArea.containsMouse ? 0.45 : 0)
                gradient: Gradient {
                    orientation: Gradient.Horizontal
                    GradientStop {
                        position: 0
                        color: Theme.withAlpha(root.accent, 0.16)
                    }
                    GradientStop {
                        position: 0.72
                        color: Theme.withAlpha(root.accent, 0.035)
                    }
                    GradientStop {
                        position: 1
                        color: "transparent"
                    }
                }

                Behavior on opacity {
                    NumberAnimation { duration: 180 }
                }
            }

            Rectangle {
                width: 3
                height: currentLine ? Math.min(30, parent.height - 12) : 4
                radius: 2
                anchors.left: parent.left
                anchors.leftMargin: 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.accent
                opacity: currentLine ? 1 : (lineArea.containsMouse ? 0.45 : 0)

                Behavior on opacity {
                    NumberAnimation { duration: 180 }
                }

                Behavior on height {
                    NumberAnimation {
                        duration: 220
                        easing.type: Easing.OutCubic
                    }
                }
            }

            StyledText {
                id: lyricText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: currentLine ? 17 : 14
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text || "♪"
                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                horizontalAlignment: Text.AlignLeft
                color: currentLine ? root.accent : Theme.surfaceText
                font.pixelSize: currentLine ? Theme.fontSizeLarge : Theme.fontSizeMedium
                font.weight: currentLine ? Font.DemiBold : Font.Normal
                lineHeight: currentLine ? 1.08 : 1.04
                opacity: {
                    if (currentLine)
                        return 1;
                    if (pastLine)
                        return Math.max(0.2, 0.44 - lineDistance * 0.055);
                    return Math.max(0.3, 0.68 - lineDistance * 0.07);
                }

                Behavior on color {
                    ColorAnimation { duration: 220 }
                }
                Behavior on opacity {
                    NumberAnimation { duration: 220 }
                }
            }

            MouseArea {
                id: lineArea
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                hoverEnabled: true
                onClicked: {
                    if (root.activePlayer?.canSeek)
                        root.activePlayer.position = modelData.time + 0.01;
                }
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: headerProgressTrack.bottom
        height: 34
        z: 2
        visible: LyricsService.hasLyrics
        enabled: false
        gradient: Gradient {
            GradientStop {
                position: 0
                color: Theme.withAlpha(Theme.floatingSurface, 0.88)
            }
            GradientStop {
                position: 1
                color: "transparent"
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 38
        z: 2
        visible: LyricsService.hasLyrics
        enabled: false
        gradient: Gradient {
            GradientStop {
                position: 0
                color: "transparent"
            }
            GradientStop {
                position: 1
                color: Theme.withAlpha(Theme.floatingSurface, 0.9)
            }
        }
    }
}
