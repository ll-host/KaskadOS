import QtQuick
import Quickshell.Services.Mpris
import qs.Common
import qs.Services

Item {
    id: root

    property MprisPlayer activePlayer
    property string artUrl: TrackArtService.activeArtUrl
    property string artKey: TrackArtService.activeTrackKey
    property string lastValidArtUrl: ""
    property string lastValidArtKey: ""
    readonly property string curArt: artUrl
        || (lastValidArtKey === artKey ? lastValidArtUrl : "")
    property string _prevArt: ""
    property bool _fadePending: false
    readonly property int albumArtStatus: mainArt.imageStatus
    property real albumSize: Math.min(width, height) * 0.58
    property bool showAnimation: true
    property real animationScale: 1.0

    readonly property real blobBaseRadiusFactor: 0.43
    readonly property real blobAmplitudeFactor: 0.115
    readonly property real blobOvershoot: 1.15
    readonly property real blobEnergySensitivity: 1.15
    readonly property real cavaFullScale: 45
    readonly property real blobAttack: 0.75
    readonly property real blobRelease: 0.2
    readonly property real blobBeatBoost: 2.5
    readonly property real blobBeatKick: 4
    readonly property real blobOnsetThreshold: 1.4
    readonly property real blobSpringStiffness: 220
    readonly property real blobSpringDamping: 19
    readonly property real blobMorphSpeed: 0.05
    readonly property real blobMorphBoost: 1.7
    readonly property real blobSpinSpeed: 0.03

    readonly property bool onScreen: visible && (Window.window?.visible ?? false)
    readonly property bool blobActive: CavaService.cavaAvailable && onScreen && activePlayer?.playbackState === MprisPlaybackState.Playing && showAnimation && albumArtStatus === Image.Ready
    property var smoothedBands: [0, 0, 0, 0, 0, 0]
    property var slowBands: [0, 0, 0, 0, 0, 0]
    property var bandTargets: [0, 0, 0, 0, 0, 0]
    property var bandDisplay: [0, 0, 0, 0, 0, 0]
    property var prevLevels: [0, 0, 0, 0, 0, 0]
    readonly property var fluxWeights: [1.0, 1.0, 0.6, 0.6, 0.35, 0.35]
    property real fluxAvg: 0.02
    property real loudCtx: 0.1
    property int beatCooldown: 0
    property real energyTarget: 0
    property real energyPos: 0
    property real energyVel: 0

    onActivePlayerChanged: {
        lastValidArtUrl = "";
        lastValidArtKey = "";
    }

    onArtKeyChanged: {
        // A cached image is valid only for the track key which produced it.
        // Clear every fallback immediately so a delayed old decode cannot
        // survive a next/previous action.
        fadeSafety.stop();
        fadeOut.stop();
        fadeArt.opacity = 0;
        fadeArt.imageSource = "";
        lastValidArtUrl = "";
        lastValidArtKey = "";
        _prevArt = "";
    }

    onCurArtChanged: {
        // Keep the outgoing art covering mainArt until the new art decodes, then fade —
        // hides mainArt's placeholder base so no primary circle flashes mid-load.
        if (_prevArt !== "" && _prevArt !== curArt) {
            fadeArt.imageSource = _prevArt;
            fadeArt.opacity = 1;
            _fadePending = true;
            fadeSafety.restart();
            Qt.callLater(_maybeStartFade); // catch cached (synchronous) loads
        }
        _prevArt = curArt;
    }

    function _maybeStartFade() {
        if (!_fadePending)
            return;
        if (mainArt.imageStatus !== Image.Ready && mainArt.imageStatus !== Image.Error)
            return;
        _fadePending = false;
        fadeSafety.stop();
        fadeOut.restart();
    }

    Timer {
        id: fadeSafety
        interval: 1200
        onTriggered: {
            if (root._fadePending) {
                root._fadePending = false;
                fadeOut.restart();
            }
        }
    }

    NumberAnimation {
        id: fadeOut
        target: fadeArt
        property: "opacity"
        from: 1
        to: 0
        duration: 300
        easing.type: Easing.InOutQuad
    }

    function updateBands() {
        const vals = CavaService.compactValues;
        if (!vals || vals.length < 6)
            return;

        const s = smoothedBands;
        const slow = slowBands;
        const out = bandTargets;
        const prev = prevLevels;
        const w = fluxWeights;
        let flux = 0;
        for (let i = 0; i < 6; i++) {
            const level = Math.min(Math.max(vals[i], 0), cavaFullScale) / cavaFullScale;
            flux += Math.max(0, level - prev[i]) * w[i];
            prev[i] = level;
            const alpha = level > s[i] ? blobAttack : blobRelease;
            s[i] += alpha * (level - s[i]);
            slow[i] += 0.05 * (level - slow[i]);
            const punch = Math.max(0, s[i] - slow[i]) * blobBeatBoost;
            out[i] = Math.min(1, (0.55 * s[i] + punch) * blobEnergySensitivity);
        }

        const ratio = flux / Math.max(fluxAvg, 0.004);
        fluxAvg += 0.06 * (flux - fluxAvg);
        if (beatCooldown > 0) {
            beatCooldown--;
        } else if (ratio > blobOnsetThreshold && flux > 0.008) {
            energyVel += blobBeatKick * Math.min(2.5, ratio - 1);
            beatCooldown = 3;
        }

        const loud = 0.7 * Math.max(prev[0], prev[1]) + 0.3 * Math.max(prev[2], prev[3]);
        loudCtx += 0.03 * (loud - loudCtx);
        const surge = Math.max(0, loud / Math.max(loudCtx, 0.05) - 1);
        energyTarget = Math.min(1, 0.5 * loud + 0.6 * Math.min(1, surge));
    }

    function stepBlob(dt) {
        energyVel += (blobSpringStiffness * (energyTarget - energyPos) - blobSpringDamping * energyVel) * dt;
        energyPos = Math.max(0, Math.min(blobOvershoot, energyPos + energyVel * dt));
        blobEffect.energy = energyPos;

        const d = bandDisplay;
        const t = bandTargets;
        const f = Math.min(1, dt * 14);
        for (let i = 0; i < 6; i++) {
            d[i] += f * (t[i] - d[i]);
        }
        blobEffect.bandsA = Qt.vector4d(d[0], d[1], d[2], d[3]);
        blobEffect.bandsB = Qt.vector2d(d[4], d[5]);

        const speed = 1 + energyPos * blobMorphBoost;
        blobEffect.phase = (blobEffect.phase + dt * blobMorphSpeed * speed) % 1;
        blobEffect.spin = (blobEffect.spin + dt * blobSpinSpeed) % 6.28318530718;
    }

    Loader {
        active: root.onScreen && activePlayer?.playbackState === MprisPlaybackState.Playing && showAnimation
        sourceComponent: Component {
            Ref {
                service: CavaService
            }
        }
    }

    Connections {
        target: CavaService
        enabled: blobEffect.visible
        function onValuesChanged() {
            root.updateBands();
        }
    }

    // Timer, not FrameAnimation — a running animation commits frames every vsync (#2863)
    Timer {
        running: blobEffect.visible && root.onScreen
        interval: 33
        repeat: true
        onTriggered: root.stepBlob(0.033)
    }

    DankRadialVisualizer {
        anchors.fill: parent
        z: 0
        activePlayer: root.activePlayer
        innerRadius: root.albumSize / 2 + 7
        maxLength: Math.max(8, (Math.min(root.width, root.height) - root.albumSize) / 2 - 10)
        opacity: root.showAnimation ? 1 : 0
    }

    ShaderEffect {
        id: blobEffect

        readonly property real span: Math.min(root.width, root.height)

        width: span * (root.blobBaseRadiusFactor + root.blobAmplitudeFactor * root.blobOvershoot) * 2 * root.animationScale + 4
        height: width
        anchors.centerIn: parent
        z: 0
        visible: false

        property real phase: 0
        property real spin: 0
        property real sizePx: width
        property real baseRadiusPx: span * root.blobBaseRadiusFactor * root.animationScale
        property real amplitudePx: span * root.blobAmplitudeFactor * root.animationScale
        property real activation: root.blobActive ? 1 : 0
        property real energy: 0
        property vector4d bandsA: Qt.vector4d(0, 0, 0, 0)
        property vector2d bandsB: Qt.vector2d(0, 0)
        readonly property color accentColor: MediaAccentService.accent
        property vector4d fillColor: Qt.vector4d(accentColor.r, accentColor.g, accentColor.b, accentColor.a)

        Behavior on activation {
            NumberAnimation {
                duration: 550
                easing.type: Easing.InOutQuad
            }
        }

        fragmentShader: Qt.resolvedUrl("../Shaders/qsb/blob.frag.qsb")
    }

    DankCircularImage {
        id: mainArt
        width: albumSize
        height: albumSize
        anchors.centerIn: parent
        z: 1
        imageSource: root.curArt
        fallbackIcon: "album"
        border.color: MediaAccentService.accent
        border.width: 2

        onImageStatusChanged: {
            if (imageStatus === Image.Ready && imageSource !== "") {
                root.lastValidArtUrl = imageSource;
                root.lastValidArtKey = root.artKey;
            }
            root._maybeStartFade();
        }
    }

    // Outgoing art, shown on top only while fading out over the new mainArt.
    DankCircularImage {
        id: fadeArt
        width: albumSize
        height: albumSize
        anchors.centerIn: parent
        z: 2
        fallbackIcon: ""
        border.color: MediaAccentService.accent
        border.width: 2
        opacity: 0
        visible: opacity > 0
    }
}
