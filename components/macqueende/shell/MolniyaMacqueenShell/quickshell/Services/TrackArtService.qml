pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick
import Quickshell.Services.Mpris
import qs.Common

Singleton {
    id: root

    property string _lastArtUrl: ""
    property string resolvedArtUrl: ""
    property alias _bgArtSource: root.resolvedArtUrl
    property bool loading: false
    // sha1s of placeholder art to reject (Chrome's own logo, shown before real cover).
    readonly property var _artHashDenylist: ["764a730860c5b8a7bbee690ee5a443672ae37dc8"]

    function djb2Hash(str) {
        if (!str) return "";
        let hash = 5381;
        for (let i = 0; i < str.length; i++) {
            hash = ((hash << 5) + hash) + str.charCodeAt(i);
            hash = hash & 0x7FFFFFFF;
        }
        return hash.toString(16).padStart(8, '0');
    }

    function getArtworkUrl(player) {
        if (!player) return "";

        let artUrl = player.trackArtUrl || "";
        if (artUrl !== "") {
            return artUrl;
        }

        if (player.metadata && player.metadata["mpris:artUrl"]) {
            artUrl = player.metadata["mpris:artUrl"].toString();
            if (artUrl !== "") return artUrl;
        }

        // YouTube publishes no artUrl; derive the thumbnail from the video id.
        if (player.metadata && player.metadata["xesam:url"]) {
            const url = player.metadata["xesam:url"].toString();
            if (url.includes("youtube.com") || url.includes("youtu.be")) {
                const regExp = /^.*(youtu.be\/|v\/|u\/\w\/|embed\/|watch\?v=|\&v=)([^#\&\?]*).*/;
                const match = url.match(regExp);
                if (match && match[2].length === 11) {
                    return "https://img.youtube.com/vi/" + match[2] + "/hqdefault.jpg";
                }
            }
        }

        return "";
    }

    function _commit(u, artKey, srcUrl) {
        resolvedArtUrl = u;
        _committedArtKey = u !== "" ? artKey : "";
        _committedSrcUrl = u !== "" ? srcUrl : "";
    }

    function loadArtwork(url, artKey, requestSerial, forceRefresh) {
        if (!url || url === "") {
            // Keep stale art; only blank once the empty url debounce settles.
            _lastArtUrl = "";
            loading = false;
            _clearDebounce.restart();
            return;
        }
        _clearDebounce.stop();
        // Same url must re-issue under a new serial; the bump cancelled the in-flight load.
        if (url === _lastArtUrl && requestSerial === _lastIssuedSerial)
            return;
        _lastArtUrl = url;
        _lastIssuedSerial = requestSerial;

        if (url.startsWith("http://") || url.startsWith("https://")) {
            loading = true;
            const targetUrl = url;
            const hash = djb2Hash(url);
            const cacheDir = Paths.strip(Paths.imagecache);
            const filePath = cacheDir + "/remote_" + hash;
            const localFileUrl = "file://" + filePath;

            const cacheProbe = forceRefresh ? ["false"] : ["test", "-f", filePath];
            Proc.runCommand(null, cacheProbe, (output, exitCode) => {
                if (_lastArtUrl !== targetUrl || _requestSerial !== requestSerial)
                    return;

                if (exitCode === 0) {
                    _commit(localFileUrl, artKey, targetUrl);
                    loading = false;
                } else {
                    const dlCmd = "mkdir -p \"$(dirname \"$1\")\" && curl -f -s -L -o \"$1\" \"$2\" && mv \"$1\" \"$3\" || { rm -f \"$1\"; exit 1; }";

                    // YouTube: try the 16:9 maxres thumbnail before falling back.
                    if (targetUrl.includes("img.youtube.com/vi/")) {
                        const videoId = targetUrl.split("/vi/")[1].split("/")[0];
                        const maxresUrl = "https://img.youtube.com/vi/" + videoId + "/maxresdefault.jpg";
                        const mqUrl = "https://img.youtube.com/vi/" + videoId + "/mqdefault.jpg";
                        const tmpPath = filePath + ".tmp";

                        Proc.runCommand(null, ["sh", "-c", dlCmd, "sh", tmpPath, maxresUrl, filePath], (maxOutput, maxExitCode) => {
                            if (_lastArtUrl !== targetUrl || _requestSerial !== requestSerial)
                                return;

                            if (maxExitCode === 0) {
                                _commit(localFileUrl, artKey, targetUrl);
                                loading = false;
                            } else {
                                Proc.runCommand(null, ["sh", "-c", dlCmd, "sh", tmpPath, mqUrl, filePath], (mqOutput, mqExitCode) => {
                                    if (_lastArtUrl !== targetUrl || _requestSerial !== requestSerial)
                                        return;

                                    _commit(mqExitCode === 0 ? localFileUrl : targetUrl, artKey, targetUrl);
                                    loading = false;
                                }, 50, 15000);
                            }
                        }, 50, 15000);
                    } else {
                        const tmpPath = filePath + ".tmp";
                        Proc.runCommand(null, ["sh", "-c", dlCmd, "sh", tmpPath, targetUrl, filePath], (dlOutput, dlExitCode) => {
                            if (_lastArtUrl !== targetUrl || _requestSerial !== requestSerial)
                                return;

                            _commit(dlExitCode === 0 ? localFileUrl : targetUrl, artKey, targetUrl);
                            loading = false;
                        }, 50, 15000);
                    }
                }
            }, 50, 5000);
            return;
        }

        loading = true;
        const localUrl = url;
        const filePath = url.startsWith("file://") ? url.substring(7) : url;
        const cacheDir = Paths.strip(Paths.imagecache);
        const committedPrefix = "file://" + cacheDir + "/art_";
        const previousSha = forceRefresh && resolvedArtUrl.startsWith(committedPrefix)
            ? resolvedArtUrl.substring(committedPrefix.length) : "";
        // Some MPRIS clients overwrite one temporary file for every track.
        // Wait for its bytes to change instead of accepting the old cover
        // under the new track key.
        const script = "f=\"$1\"; d=\"$2\"; old=\"$3\"; i=0; while [ \"$i\" -lt 24 ]; do if [ -f \"$f\" ]; then s=$(sha1sum \"$f\" | cut -c1-40); if [ -z \"$old\" ] || [ \"$s\" != \"$old\" ] || [ \"$i\" -ge 20 ]; then break; fi; fi; sleep 0.15; i=$((i + 1)); done; [ -f \"$f\" ] || exit 1; s=$(sha1sum \"$f\" | cut -c1-40); if [ ! -f \"$d/art_$s\" ]; then mkdir -p \"$d\" && cp \"$f\" \"$d/art_$s.tmp\" && mv \"$d/art_$s.tmp\" \"$d/art_$s\" || exit 1; fi; echo \"$s\"";
        Proc.runCommand(null, ["sh", "-c", script, "sh", filePath, cacheDir, previousSha], (output, exitCode) => {
            if (_lastArtUrl !== localUrl || _requestSerial !== requestSerial)
                return;
            loading = false;
            if (exitCode !== 0)
                return;
            const sha = (output || "").trim();
            if (_artHashDenylist.indexOf(sha) !== -1)
                return;
            _commit("file://" + cacheDir + "/art_" + sha, artKey, localUrl);
        }, 50, 5000);
    }

    Timer {
        id: _clearDebounce
        interval: 800
        onTriggered: {
            if (root._lastArtUrl === "")
                root._commit("", "", "");
        }
    }

    property MprisPlayer activePlayer: MprisController.activePlayer

    property string _committedArtKey: ""
    property string _pendingArtKey: ""
    property string _committedSrcUrl: ""
    property int _requestSerial: 0
    property int _lastIssuedSerial: -1
    property int _metadataRetryCount: 0
    readonly property string activeTrackKey: _pendingArtKey
    readonly property string activeArtUrl: _pendingArtKey !== ""
        && _pendingArtKey === _committedArtKey ? resolvedArtUrl : ""

    onActivePlayerChanged: _updateArtUrl()

    Connections {
        target: root.activePlayer
        ignoreUnknownSignals: true
        function onTrackTitleChanged() { root._updateArtUrl(); }
        function onTrackArtUrlChanged() { root._updateArtUrl(); }
        function onMetadataChanged() { root._updateArtUrl(); }
    }

    function _trackKey() {
        return _trackKeyFor(activePlayer);
    }

    function _trackKeyFor(p) {
        if (!p)
            return "";
        // dbusName is constant per player; uniqueId is per-track and would churn the key.
        const playerId = p.dbusName || p.identity || "";
        const tid = p.metadata && p.metadata["mpris:trackid"] ? p.metadata["mpris:trackid"].toString() : "";
        const mediaUrl = p.metadata && p.metadata["xesam:url"] ? p.metadata["xesam:url"].toString() : "";
        return playerId + " " + tid + " " + (p.trackTitle || "") + " "
            + (p.trackArtist || "") + " " + (p.trackAlbum || "") + " " + mediaUrl;
    }

    function artReadyFor(player) {
        const key = _trackKeyFor(player);
        return key !== "" && key === _committedArtKey && !loading && activeArtUrl !== "";
    }

    function _updateArtUrl(forceSameSource) {
        const key = _trackKey();
        if (key !== _pendingArtKey) {
            _requestSerial++;
            loading = false;
            _metadataRetryCount = 0;
            if (key !== "")
                _artMetadataRetry.restart();
            else
                _artMetadataRetry.stop();
        }
        _pendingArtKey = key;
        const url = getArtworkUrl(activePlayer);
        // Ignore Chrome's same-track thumbnail size updates.
        if (key !== "" && key === _committedArtKey)
            return;
        if (key !== "" && url !== "" && url === _committedSrcUrl) {
            // Chrome can publish track metadata before its new artwork URL.
            if (!forceSameSource)
                return;
        }
        loadArtwork(url, key, _requestSerial, !!forceSameSource);
    }

    Timer {
        id: _artMetadataRetry
        interval: 180
        repeat: true
        onTriggered: {
            root._metadataRetryCount++;
            root._updateArtUrl(root._metadataRetryCount >= 6);
            if (root._pendingArtKey === root._committedArtKey || root._metadataRetryCount >= 24)
                stop();
        }
    }
}
