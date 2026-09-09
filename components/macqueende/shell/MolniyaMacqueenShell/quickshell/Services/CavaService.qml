pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common

Singleton {
    id: root

    property list<int> values: Array(48)
    readonly property var compactValues: {
        if (values.length < 48)
            return values;
        const result = [];
        for (let band = 0; band < 6; band++) {
            let sum = 0;
            for (let i = 0; i < 8; i++)
                sum += values[band * 8 + i] || 0;
            result.push(sum / 8);
        }
        return result;
    }
    property int refCount: 0
    property bool cavaAvailable: false
    readonly property string _confPath: `${Paths.strip(StandardPaths.writableLocation(StandardPaths.TempLocation))}/dms-cava-${Date.now()}-${Math.floor(Math.random() * 1000000)}.conf`

    Process {
        id: cavaCheck

        command: ["sh", "-c", "command -v cava"]
        running: false
        onExited: exitCode => {
            root.cavaAvailable = exitCode === 0 && Quickshell.env("DMS_DISABLE_CAVA") !== "1";
        }
    }

    Component.onCompleted: {
        cavaCheck.running = true;
    }

    Process {
        id: cavaProcess

        running: root.cavaAvailable && root.refCount > 0
        command: ["sh", "-c", `cat <<'CAVACONF' > ${root._confPath}
[general]
framerate=25
bars=48
autosens=1
sensitivity=100
sleep_timer=3
lower_cutoff_freq=50
higher_cutoff_freq=12000

[output]
method=raw
raw_target=/dev/stdout
data_format=ascii
ascii_max_range=100
channels=mono
mono_option=average

[smoothing]
noise_reduction=20
integral=90
gravity=70
ignore=2
monstercat=1.5
CAVACONF
exec cava -p ${root._confPath} < /dev/null`]

        onRunningChanged: {
            if (!running) {
                root.values = Array(48).fill(0);
            }
        }

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                if (root.refCount <= 0 || data.length === 0)
                    return;

                const parts = data.split(";");
                if (parts.length < 48)
                    return;

                const points = [];
                for (let i = 0; i < 48; i++)
                    points.push(parseInt(parts[i], 10));
                if (points.every((v, i) => v === root.values[i]))
                    return;

                root.values = points;
            }
        }
    }
}
