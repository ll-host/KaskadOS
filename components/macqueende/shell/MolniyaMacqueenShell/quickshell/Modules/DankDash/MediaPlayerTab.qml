import QtQuick
import QtQuick.Effects
import Quickshell.Services.Mpris
import Quickshell.Widgets
import qs.Common
import qs.Services
import qs.Widgets

Item {
    id: root

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    property MprisPlayer activePlayer: MprisController.activePlayer
    readonly property real stableLength: MprisController.activePlayerStableLength
    property var allPlayers: MprisController.availablePlayers
    property var targetScreen: null
    property real popoutX: 0
    property real popoutY: 0
    property real popoutWidth: 0
    property real popoutHeight: 0
    property real contentOffsetY: 0
    property string section: ""
    property int barPosition: SettingsData.Position.Top
    property bool lyricsPanelOpen: false

    readonly property color accent: MediaAccentService.accent
    readonly property color onAccent: MediaAccentService.onAccent
    readonly property color accentHover: MediaAccentService.accentHover
    readonly property color accentPressed: MediaAccentService.accentPressed

    signal showVolumeDropdown(point pos, var screen, bool rightEdge, var player, var players)
    signal showAudioDevicesDropdown(point pos, var screen, bool rightEdge)
    signal showPlayersDropdown(point pos, var screen, bool rightEdge, var player, var players)
    signal hideDropdowns
    signal dropdownButtonExited
    signal dropdownButtonEntered

    property bool volumeExpanded: false
    property bool devicesExpanded: false
    property bool playersExpanded: false

    function resetDropdownStates() {
        volumeExpanded = false;
        devicesExpanded = false;
        playersExpanded = false;
        lyricsPanelOpen = false;
    }

    function localizedLyricsError(message) {
        const normalized = String(message || "").toLowerCase();
        if (normalized.includes("not synchronized"))
            return I18n.tr("Lyrics are available, but not synchronized");
        return I18n.tr("Lyrics not found");
    }

    readonly property bool isRightEdge: {
        if (barPosition === SettingsData.Position.Right)
            return true;
        if (barPosition === SettingsData.Position.Left)
            return false;
        return section === "right";
    }
    readonly property bool __isChromeBrowser: {
        if (!activePlayer?.identity)
            return false;
        const id = activePlayer.identity.toLowerCase();
        return id.includes("chrome") || id.includes("chromium");
    }
    readonly property bool volumeAvailable: !!((activePlayer && activePlayer.volumeSupported && !__isChromeBrowser) || (AudioService.sink && AudioService.sink.audio))
    readonly property bool usePlayerVolume: activePlayer && activePlayer.volumeSupported && !__isChromeBrowser
    readonly property real currentVolume: usePlayerVolume ? activePlayer.volume : (AudioService.sink?.audio?.volume ?? 0)

    property bool isSwitching: false
    property int lyricIndex: -1
    readonly property int lyricDisplayIndex: lyricIndex >= 0 ? lyricIndex : (LyricsService.hasLyrics ? 0 : -1)

    function updateLyrics() {
        if (!activePlayer) {
            LyricsService.loadTrack("", "", "", 0);
            lyricIndex = -1;
            return;
        }
        LyricsService.loadTrack(activePlayer.trackArtist, activePlayer.trackTitle,
                                activePlayer.trackAlbum, stableLength);
        lyricIndex = LyricsService.indexForTime(activePlayer.position || 0);
    }

    onStableLengthChanged: updateLyrics()
    Component.onCompleted: updateLyrics()

    // Derived "no players" state: always correct, no timers.
    readonly property int _playerCount: allPlayers ? allPlayers.length : 0
    readonly property bool _noneAvailable: _playerCount === 0
    readonly property bool showNoPlayerNow: (!_switchHold) && (_noneAvailable || !activePlayer)

    property bool _switchHold: false
    Timer {
        id: _switchHoldTimer
        interval: 1500
        repeat: false
        onTriggered: _switchHold = false
    }

    onActivePlayerChanged: {
        if (!activePlayer) {
            isSwitching = false;
            _switchHold = true;
            _switchHoldTimer.restart();
            return;
        }
        isSwitching = true;
        _switchHold = true;
        _switchHoldTimer.restart();
        Qt.callLater(updateLyrics);
    }

    function maybeFinishSwitch() {
        if (activePlayer && activePlayer.trackTitle !== "") {
            isSwitching = false;
            _switchHold = false;
        }
    }

    readonly property real ratio: {
        if (!activePlayer || stableLength <= 0) {
            return 0;
        }
        const pos = (activePlayer.position || 0) % Math.max(1, stableLength);
        const calculatedRatio = pos / stableLength;
        return Math.max(0, Math.min(1, calculatedRatio));
    }

    implicitWidth: SettingsData.showWeekNumber ? 736 : 700
    implicitHeight: 410

    Connections {
        target: activePlayer
        ignoreUnknownSignals: true
        function onTrackTitleChanged() {
            _switchHoldTimer.restart();
            maybeFinishSwitch();
            root.updateLyrics();
        }
        function onTrackArtistChanged() { root.updateLyrics(); }
        function onTrackAlbumChanged() { root.updateLyrics(); }
    }

    Connections {
        target: LyricsService
        function onLinesChanged() { root.lyricIndex = LyricsService.indexForTime(root.activePlayer?.position || 0); }
    }

    Timer {
        interval: 250
        repeat: true
        running: root.visible && !!root.activePlayer
        onTriggered: root.lyricIndex = LyricsService.indexForTime(root.activePlayer?.position || 0)
    }

    Connections {
        target: MprisController
        function onAvailablePlayersChanged() {
            if ((MprisController.availablePlayers?.length || 0) === 0)
                isSwitching = false;
            _switchHold = true;
            _switchHoldTimer.restart();
        }
    }

    function getAudioDeviceIcon(device) {
        if (!device || !device.name)
            return "speaker";

        const name = device.name.toLowerCase();

        if (name.includes("bluez") || name.includes("bluetooth"))
            return "headset";
        if (name.includes("hdmi"))
            return "tv";
        if (name.includes("usb"))
            return "headset";
        if (name.includes("analog") || name.includes("built-in"))
            return "speaker";

        return "speaker";
    }

    function getVolumeIcon() {
        if (!volumeAvailable)
            return "volume_off";

        const volume = currentVolume;

        if (usePlayerVolume) {
            if (volume === 0.0)
                return "music_off";
            return "music_note";
        }

        if (volume === 0.0)
            return "volume_off";
        if (volume <= 0.33)
            return "volume_down";
        if (volume <= 0.66)
            return "volume_up";
        return "volume_up";
    }

    function adjustVolume(step) {
        if (!volumeAvailable)
            return;
        const maxVol = usePlayerVolume ? 100 : AudioService.sinkMaxVolume;
        const current = Math.round(currentVolume * 100);
        const newVolume = Math.min(maxVol, Math.max(0, current + step));

        SessionData.suppressOSDTemporarily();
        if (usePlayerVolume) {
            activePlayer.volume = newVolume / 100;
        } else if (AudioService.sink?.audio) {
            AudioService.sink.audio.volume = newVolume / 100;
        }
    }

    function triggerVolumeDropdown() {
        if (!volumeAvailable)
            return;
        if (volumeExpanded)
            return;
        hideDropdowns();
        volumeExpanded = true;
        const buttonsOnRight = !isRightEdge;
        const btnY = volumeButton.y + volumeButton.height / 2;
        const screenX = buttonsOnRight ? (popoutX + popoutWidth) : popoutX;
        const screenY = popoutY + contentOffsetY + btnY;
        showVolumeDropdown(Qt.point(screenX, screenY), targetScreen, buttonsOnRight, activePlayer, allPlayers);
    }

    function toggleMute() {
        if (!volumeAvailable)
            return;
        SessionData.suppressOSDTemporarily();
        if (currentVolume > 0) {
            volumeButton.previousVolume = currentVolume;
            if (usePlayerVolume) {
                activePlayer.volume = 0;
            } else if (AudioService.sink?.audio) {
                AudioService.sink.audio.volume = 0;
            }
        } else {
            const restoreVolume = volumeButton.previousVolume > 0 ? volumeButton.previousVolume : 0.5;
            if (usePlayerVolume) {
                activePlayer.volume = restoreVolume;
            } else if (AudioService.sink?.audio) {
                AudioService.sink.audio.volume = restoreVolume;
            }
        }
    }

    function handleKeyEvent(event) {
        if (event.key === Qt.Key_Escape && lyricsPanelOpen) {
            lyricsPanelOpen = false;
            return true;
        }

        if (!activePlayer)
            return false;

        // 1. Number keys 0-9 to seek to 0%-90%
        if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
            if (activePlayer.canSeek && stableLength > 0) {
                const ratio = (event.key - Qt.Key_0) * 0.1;
                const targetPosition = ratio * stableLength;
                activePlayer.position = Math.max(0.1, Math.min(targetPosition, stableLength * 0.99));
                return true;
            }
        }

        // 2. Left / Right arrows to seek backward / forward 5s
        if (event.key === Qt.Key_Left) {
            if (activePlayer.canSeek) {
                activePlayer.position = Math.max(0.1, activePlayer.position - 5);
                return true;
            }
        }
        if (event.key === Qt.Key_Right) {
            if (activePlayer.canSeek && stableLength > 0) {
                activePlayer.position = Math.max(0.1, Math.min(stableLength - 1, activePlayer.position + 5));
                return true;
            }
        }

        // 3. Up / Down arrows to adjust volume
        if (event.key === Qt.Key_Up) {
            adjustVolume(5);
            triggerVolumeDropdown();
            dropdownButtonExited();
            return true;
        }
        if (event.key === Qt.Key_Down) {
            adjustVolume(-5);
            triggerVolumeDropdown();
            dropdownButtonExited();
            return true;
        }

        // 4. Spacebar to play/pause
        if (event.key === Qt.Key_Space) {
            if (activePlayer.canTogglePlaying) {
                activePlayer.togglePlaying();
                return true;
            }
        }

        // 5. M key to toggle mute
        if (event.key === Qt.Key_M) {
            toggleMute();
            triggerVolumeDropdown();
            dropdownButtonExited();
            return true;
        }

        return false;
    }

    property bool isSeeking: false

    Timer {
        interval: 1000
        running: activePlayer?.playbackState === MprisPlaybackState.Playing && !isSeeking
        repeat: true
        onTriggered: activePlayer?.positionChanged()
    }

    Item {
        id: bgContainer
        anchors.fill: parent

        readonly property string curArt: TrackArtService.activeArtUrl
        // Two layers crossfade: new art loads into the hidden one and fades in once decoded.
        property bool _showA: true
        visible: layerA.ready || layerB.ready

        onCurArtChanged: syncArt()
        Component.onCompleted: syncArt()

        function syncArt() {
            if (curArt === "") {
                layerA.art = "";
                layerB.art = "";
                return;
            }
            const front = _showA ? layerA : layerB;
            const back = _showA ? layerB : layerA;
            if (front.art == curArt)
                return;
            if (back.art == curArt) {
                // Already decoded in the hidden layer; flip once ready (else promote() does).
                if (back.ready)
                    _showA = !_showA;
                return;
            }
            back.art = curArt;
        }

        // Flip to the hidden layer only when it holds the current art, ignoring stale
        // Ready re-emits (e.g. popout re-expose) that would otherwise ping-pong _showA.
        function promote(layer) {
            const back = _showA ? layerB : layerA;
            if (layer !== back)
                return;
            if (layer.art != curArt)
                return;
            _showA = (layer === layerA);
            root.maybeFinishSwitch();
        }

        BgBlurLayer {
            id: layerA
            front: bgContainer._showA
            onLoaded: bgContainer.promote(layerA)
        }

        BgBlurLayer {
            id: layerB
            front: !bgContainer._showA
            onLoaded: bgContainer.promote(layerB)
        }

        Rectangle {
            anchors.fill: parent
            radius: Theme.cornerRadius
            color: "#080607"
            opacity: 0.74
        }
    }

    component BgBlurLayer: ClippingRectangle {
        id: layer
        property alias art: layerImg.source
        readonly property bool ready: layerImg.status === Image.Ready && layerImg.source != ""
        property bool front: false
        signal loaded

        anchors.fill: parent
        radius: Theme.cornerRadius
        color: "transparent"
        antialiasing: true
        opacity: front ? 0.48 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: 350
                easing.type: Easing.InOutQuad
            }
        }

        Image {
            id: layerImg
            anchors.centerIn: parent
            width: Math.max(parent.width, parent.height) * 1.1
            height: width
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            visible: false
            onStatusChanged: {
                if (status === Image.Ready && source != "")
                    layer.loaded();
            }
        }

        MultiEffect {
            anchors.centerIn: parent
            width: layerImg.width
            height: layerImg.height
            source: layerImg
            blurEnabled: true
            blurMax: 64
            blur: 0.8
            saturation: -0.2
            brightness: -0.25
        }
    }

    Column {
        anchors.centerIn: parent
        spacing: Theme.spacingM
        visible: showNoPlayerNow

        DankIcon {
            name: "music_note"
            size: Theme.iconSize * 3
            color: Theme.surfaceTextSecondary
            anchors.horizontalCenter: parent.horizontalCenter
        }

        StyledText {
            text: I18n.tr("No Active Players")
            font.pixelSize: Theme.fontSizeLarge
            color: Theme.surfaceTextMedium
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    Item {
        id: playerStage
        anchors.fill: parent
        visible: !_noneAvailable && !showNoPlayerNow

        DankAlbumArt {
            id: albumArt
            x: 35
            y: 22
            width: 220
            height: 220
            albumSize: 154
            activePlayer: root.activePlayer
        }

        Row {
            id: playbackControls
            x: 64
            y: root.height - 79
            spacing: 13

            Rectangle {
                width: 40
                height: 40
                radius: 20
                anchors.verticalCenter: parent.verticalCenter
                color: prevBtnArea.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.92) : Theme.withAlpha(Theme.surfaceContainerHigh, 0.72)

                DankIcon {
                    anchors.centerIn: parent
                    name: "skip_previous"
                    size: 22
                    color: Theme.surfaceText
                }

                MouseArea {
                    id: prevBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: MprisController.previousOrRewind()
                }
            }

            Rectangle {
                width: 54
                height: 54
                radius: 18
                anchors.verticalCenter: parent.verticalCenter
                color: root.accent

                DankIcon {
                    anchors.centerIn: parent
                    name: activePlayer && activePlayer.playbackState === MprisPlaybackState.Playing ? "pause" : "play_arrow"
                    size: 28
                    color: root.onAccent
                    weight: 600
                }

                StateLayer {
                    disabled: !root.activePlayer || !root.activePlayer.canTogglePlaying
                    stateColor: root.onAccent
                    cornerRadius: parent.radius
                    onClicked: root.activePlayer.togglePlaying()
                }

                ElevationShadow {
                    anchors.fill: parent
                    z: -1
                    level: Theme.elevationLevel2
                    fallbackOffset: 4
                    targetRadius: parent.radius
                    targetColor: parent.color
                    shadowOpacity: 0.36
                    shadowEnabled: Theme.elevationEnabled
                }
            }

            Rectangle {
                width: 40
                height: 40
                radius: 20
                anchors.verticalCenter: parent.verticalCenter
                color: nextBtnArea.containsMouse ? Theme.withAlpha(Theme.surfaceContainerHigh, 0.92) : Theme.withAlpha(Theme.surfaceContainerHigh, 0.72)

                DankIcon {
                    anchors.centerIn: parent
                    name: "skip_next"
                    size: 22
                    color: Theme.surfaceText
                }

                MouseArea {
                    id: nextBtnArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: MprisController.next()
                }
            }
        }

        Item {
            id: trackDetails
            x: 286
            y: 39
            width: root.width - x - 75
            height: root.height - 69

            StyledText {
                id: trackTitle
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: MprisController.stableTitle || I18n.tr("Unknown Track")
                font.pixelSize: 25
                font.weight: Font.Bold
                color: Theme.surfaceText
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            StyledText {
                id: trackArtist
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: trackTitle.bottom
                anchors.topMargin: 4
                text: MprisController.stableArtist || I18n.tr("Unknown Artist")
                font.pixelSize: 12
                font.weight: Font.Medium
                color: root.accent
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Column {
                id: inlineLyrics
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: trackArtist.bottom
                anchors.topMargin: 17
                height: 165
                spacing: 0

                Repeater {
                    model: 5

                    Item {
                        required property int index
                        readonly property int sourceIndex: root.lyricDisplayIndex + index - 2
                        readonly property bool currentLine: index === 2
                        readonly property var lyricLine: sourceIndex >= 0 && sourceIndex < LyricsService.lines.length
                            ? LyricsService.lines[sourceIndex]
                            : null
                        width: inlineLyrics.width
                        height: currentLine ? 53 : 28

                        Rectangle {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: parent.currentLine ? Math.min(32, parent.height - 12) : 18
                            radius: 2
                            color: root.accent
                            visible: parent.currentLine && !!parent.lyricLine
                        }

                        StyledText {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: parent.currentLine && parent.lyricLine ? 10 : 0
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                if (parent.lyricLine)
                                    return parent.lyricLine.text || "♪";
                                if (!parent.currentLine)
                                    return "";
                                if (LyricsService.loading)
                                    return I18n.tr("Loading lyrics…");
                                return root.localizedLyricsError(LyricsService.error);
                            }
                            font.pixelSize: parent.currentLine ? 19 : 13
                            font.weight: parent.currentLine ? Font.DemiBold : Font.Normal
                            color: parent.currentLine ? Theme.surfaceText : Theme.surfaceTextSecondary
                            opacity: parent.currentLine ? 1 : (parent.index === 1 || parent.index === 3 ? 0.56 : 0.36)
                            wrapMode: parent.currentLine ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
                            elide: Text.ElideRight
                            maximumLineCount: parent.currentLine ? 2 : 1
                            lineHeight: parent.currentLine ? 0.96 : 1

                            Behavior on opacity { NumberAnimation { duration: 180 } }
                            Behavior on color { ColorAnimation { duration: 180 } }
                        }

                        MouseArea {
                            anchors.fill: parent
                            enabled: !!parent.lyricLine && !!root.activePlayer?.canSeek
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: root.activePlayer.position = parent.lyricLine.time + 0.01
                        }
                    }
                }
            }

            DankSeekbar {
                id: seekbar
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: timeLabels.top
                anchors.bottomMargin: 2
                height: 20
                activePlayer: root.activePlayer
                isSeeking: root.isSeeking
                onIsSeekingChanged: root.isSeeking = isSeeking
            }

            Item {
                id: timeLabels
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 18

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (!activePlayer)
                            return "0:00";
                        const rawPos = Math.max(0, activePlayer.position || 0);
                        const pos = stableLength ? rawPos % Math.max(1, stableLength) : rawPos;
                        const minutes = Math.floor(pos / 60);
                        const seconds = Math.floor(pos % 60);
                        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                    }
                    font.pixelSize: 10
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                        if (!activePlayer || stableLength <= 0)
                            return "--:--";
                        const minutes = Math.floor(stableLength / 60);
                        const seconds = Math.floor(stableLength % 60);
                        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds;
                    }
                    font.pixelSize: 10
                    color: Theme.surfaceVariantText
                }
            }
        }

        Rectangle {
            id: playerSelectorButton
            width: 42
            height: 42
            radius: 21
            x: root.width - width - 14
            y: 134
            z: 100
            visible: (allPlayers?.length || 0) >= 1
            color: playerSelectorArea.containsMouse || playersExpanded ? "#352526" : "#241a1b"
            border.width: 1
            border.color: playersExpanded
                ? Theme.withAlpha(Theme.surfaceText, 0.16)
                : Theme.withAlpha(Theme.surfaceText, 0.05)

            DankIcon {
                anchors.centerIn: parent
                name: "queue_music"
                size: 19
                color: Theme.surfaceText
            }

            MouseArea {
                id: playerSelectorArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (playersExpanded) {
                        const players = (root.allPlayers || []).filter(p => p && !MprisController.isIdle(p));
                        if (players.length > 1) {
                            let currentIndex = players.indexOf(root.activePlayer);
                            MprisController.setActivePlayer(players[(currentIndex + 1) % players.length]);
                        }
                        return;
                    }
                    hideDropdowns();
                    playersExpanded = true;
                    const buttonsOnRight = !isRightEdge;
                    showPlayersDropdown(Qt.point(buttonsOnRight ? popoutX + popoutWidth : popoutX,
                                                  popoutY + contentOffsetY + playerSelectorButton.y + playerSelectorButton.height / 2),
                                        targetScreen, buttonsOnRight, activePlayer, allPlayers);
                }
                onEntered: {
                    dropdownButtonEntered();
                    if (playersExpanded)
                        return;
                    hideDropdowns();
                    playersExpanded = true;
                    const buttonsOnRight = !isRightEdge;
                    showPlayersDropdown(Qt.point(buttonsOnRight ? popoutX + popoutWidth : popoutX,
                                                  popoutY + contentOffsetY + playerSelectorButton.y + playerSelectorButton.height / 2),
                                        targetScreen, buttonsOnRight, activePlayer, allPlayers);
                }
                onExited: {
                    if (playersExpanded)
                        dropdownButtonExited();
                }
            }
        }

        Rectangle {
            id: volumeButton
            width: 42
            height: 42
            radius: 21
            x: root.width - width - 14
            y: 184
            z: 101
            enabled: volumeAvailable
            color: volumeButtonArea.containsMouse || volumeExpanded
                ? "#352526"
                : "#241a1b"
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceText, 0.05)

            property real previousVolume: 0.0

            DankIcon {
                anchors.centerIn: parent
                name: currentVolume <= 0 ? "volume_off" : (currentVolume <= 0.5 ? "volume_down" : "volume_up")
                size: 18
                color: volumeAvailable ? Theme.surfaceText : Theme.surfaceTextSecondary
            }

            MouseArea {
                id: volumeButtonArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                    dropdownButtonEntered();
                    if (volumeExpanded)
                        return;
                    hideDropdowns();
                    volumeExpanded = true;
                    const buttonsOnRight = !isRightEdge;
                    showVolumeDropdown(Qt.point(buttonsOnRight ? popoutX + popoutWidth : popoutX,
                                                 popoutY + contentOffsetY + volumeButton.y + volumeButton.height / 2),
                                       targetScreen, buttonsOnRight, activePlayer, allPlayers);
                }
                onExited: {
                    if (volumeExpanded)
                        dropdownButtonExited();
                }
                onClicked: toggleMute()
                property real wheelAccum: 0
                onWheel: wheelEvent => {
                    wheelEvent.accepted = true;
                    wheelAccum += wheelEvent.angleDelta.y;
                    const notches = wheelAccum > 0 ? Math.floor(wheelAccum / 120) : Math.ceil(wheelAccum / 120);
                    if (notches === 0)
                        return;
                    wheelAccum -= notches * 120;
                    root.adjustVolume(notches * AudioService.wheelVolumeStep);
                }
            }
        }

        Rectangle {
            id: audioDevicesButton
            width: 42
            height: 42
            radius: 21
            x: root.width - width - 14
            y: 234
            z: 100
            color: audioDevicesArea.containsMouse || devicesExpanded
                ? "#352526"
                : "#241a1b"
            border.width: 1
            border.color: Theme.withAlpha(Theme.surfaceText, 0.05)

            DankIcon {
                anchors.centerIn: parent
                name: "speaker"
                size: 18
                color: Theme.surfaceText
            }

            MouseArea {
                id: audioDevicesArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onPressed: mouse => {
                    if (mouse.button === Qt.RightButton)
                        mouse.accepted = true;
                }
                onWheel: wheelEvent => {
                    if (wheelEvent.angleDelta.y !== 0) {
                        AudioService.cycleAudioOutputDirection(wheelEvent.angleDelta.y < 0);
                        wheelEvent.accepted = true;
                    }
                }
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        if (AudioService.sink?.audio) {
                            SessionData.suppressOSDTemporarily();
                            AudioService.sink.audio.muted = !AudioService.sink.audio.muted;
                        }
                        return;
                    }
                    if (devicesExpanded) {
                        const sinks = AudioService.getAvailableSinks();
                        if (sinks && sinks.length > 1) {
                            let currentIndex = -1;
                            for (let i = 0; i < sinks.length; i++) {
                                if (sinks[i]?.name === AudioService.sink?.name) {
                                    currentIndex = i;
                                    break;
                                }
                            }
                            AudioService.setSink(sinks[(currentIndex + 1) % sinks.length]);
                        }
                        return;
                    }
                    hideDropdowns();
                    devicesExpanded = true;
                    const buttonsOnRight = !isRightEdge;
                    showAudioDevicesDropdown(Qt.point(buttonsOnRight ? popoutX + popoutWidth : popoutX,
                                                       popoutY + contentOffsetY + audioDevicesButton.y + audioDevicesButton.height / 2),
                                             targetScreen, buttonsOnRight);
                }
                onEntered: {
                    dropdownButtonEntered();
                    if (devicesExpanded)
                        return;
                    hideDropdowns();
                    devicesExpanded = true;
                    const buttonsOnRight = !isRightEdge;
                    showAudioDevicesDropdown(Qt.point(buttonsOnRight ? popoutX + popoutWidth : popoutX,
                                                       popoutY + contentOffsetY + audioDevicesButton.y + audioDevicesButton.height / 2),
                                             targetScreen, buttonsOnRight);
                }
                onExited: {
                    if (devicesExpanded)
                        dropdownButtonExited();
                }
            }
        }
    }
}
