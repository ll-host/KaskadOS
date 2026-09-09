import QtQuick
import Quickshell.Services.Mpris
import qs.Services

// Adapted from Caelestia's radial CoverVisualiser concept (GPL-3.0).
Item {
    id: root

    property var activePlayer
    property color color: MediaAccentService.accent
    property int barCount: 48
    property real innerRadius: Math.min(width, height) * 0.31
    property real maxLength: Math.min(width, height) * 0.17
    readonly property bool playing: activePlayer?.playbackState === MprisPlaybackState.Playing

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.translate(width / 2, height / 2);
            ctx.strokeStyle = root.color;
            ctx.lineCap = "round";
            ctx.lineWidth = Math.max(2, Math.min(width, height) * 0.014);

            const values = CavaService.values;
            for (let i = 0; i < root.barCount; i++) {
                // CAVA provides one real frequency value per ray, just like Caelestia.
                const raw = values[i] || 0;
                const level = root.playing ? Math.max(0.08, Math.min(1, Math.sqrt(raw / 100))) : 0.04;
                const angle = i * Math.PI * 2 / root.barCount - Math.PI / 2;
                const length = 3 + level * root.maxLength;
                const cos = Math.cos(angle);
                const sin = Math.sin(angle);
                ctx.beginPath();
                ctx.moveTo(cos * root.innerRadius, sin * root.innerRadius);
                ctx.lineTo(cos * (root.innerRadius + length), sin * (root.innerRadius + length));
                ctx.stroke();
            }
        }

        Connections {
            target: CavaService
            function onValuesChanged() { canvas.requestPaint(); }
        }

        Connections {
            target: MediaAccentService
            function onAccentChanged() { canvas.requestPaint(); }
        }
    }

    onPlayingChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
}
