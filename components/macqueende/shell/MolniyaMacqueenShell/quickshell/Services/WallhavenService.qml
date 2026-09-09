pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// Online wallpaper catalogue backed by Wallhaven's public, SFW API.
Singleton {
    id: root

    property bool loading: false
    property bool downloading: false
    property string error: ""
    property string downloadError: ""
    property string query: ""
    property int page: 1
    property int lastPage: 1
    property var results: []
    property var selectedWallpaper: null
    property int requestToken: 0
    property string downloadedPath: ""

    signal wallpaperDownloaded(string path)

    function encoded(value) {
        return encodeURIComponent((value || "").trim());
    }

    function search(value, requestedPage) {
        query = (value || "").trim();
        page = Math.max(1, requestedPage || 1);
        error = "";
        selectedWallpaper = null;
        requestToken++;

        const sorting = query.length > 0 ? "relevance" : "toplist";
        const url = "https://wallhaven.cc/api/v1/search"
                  + "?q=" + encoded(query)
                  + "&categories=111"
                  + "&purity=100"
                  + "&sorting=" + sorting
                  + (sorting === "toplist" ? "&topRange=1M" : "")
                  + "&page=" + page;

        searchProcess.running = false;
        searchProcess.token = requestToken;
        searchProcess.command = [
            "curl", "-fsSL", "--compressed",
            "--connect-timeout", "6", "--max-time", "25",
            "-H", "User-Agent: MolniyaMacqueenShell/0.1",
            url
        ];
        loading = true;
        Qt.callLater(() => searchProcess.running = true);
    }

    function nextPage() {
        if (!loading && page < lastPage)
            search(query, page + 1);
    }

    function previousPage() {
        if (!loading && page > 1)
            search(query, page - 1);
    }

    function random() {
        error = "";
        selectedWallpaper = null;
        requestToken++;
        const url = "https://wallhaven.cc/api/v1/search"
                  + "?categories=111&purity=100&sorting=random&seed="
                  + Math.floor(Math.random() * 2147483647);
        searchProcess.running = false;
        searchProcess.token = requestToken;
        searchProcess.command = [
            "curl", "-fsSL", "--compressed",
            "--connect-timeout", "6", "--max-time", "25",
            "-H", "User-Agent: MolniyaMacqueenShell/0.1",
            url
        ];
        loading = true;
        page = 1;
        Qt.callLater(() => searchProcess.running = true);
    }

    function download(wallpaper) {
        if (!wallpaper || !wallpaper.path || downloading)
            return;

        downloadError = "";
        downloadedPath = "";
        selectedWallpaper = wallpaper;
        const fileType = wallpaper.file_type || "";
        let extension = fileType.indexOf("png") >= 0 ? "png"
                      : fileType.indexOf("webp") >= 0 ? "webp" : "jpg";
        const safeId = String(wallpaper.id || Date.now()).replace(/[^a-zA-Z0-9_-]/g, "");
        const script =
            "set -eu\n"
          + "pictures=\"$(xdg-user-dir PICTURES 2>/dev/null || true)\"\n"
          + "[ -n \"$pictures\" ] || pictures=\"$HOME/Pictures\"\n"
          + "destination=\"$pictures/Wallpapers/MacqueenDE\"\n"
          + "mkdir -p \"$destination\"\n"
          + "target=\"$destination/wallhaven-$1.$2\"\n"
          + "temporary=\"$target.part\"\n"
          + "curl -fL --silent --show-error --connect-timeout 6 --max-time 180 -o \"$temporary\" \"$3\"\n"
          + "mv \"$temporary\" \"$target\"\n"
          + "printf '%s\\n' \"$target\"\n";

        downloadProcess.command = ["bash", "-c", script, "macqueen-wallpaper",
                                   safeId, extension, wallpaper.path];
        downloading = true;
        downloadProcess.running = true;
    }

    Process {
        id: searchProcess
        property int token: 0
        property bool parsedSuccessfully: false
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (searchProcess.token !== root.requestToken)
                    return;
                try {
                    const response = JSON.parse(text);
                    root.results = response.data || [];
                    root.page = Number(response.meta?.current_page || root.page);
                    root.lastPage = Number(response.meta?.last_page || root.page);
                    root.error = root.results.length > 0 ? "" : qsTr("Nothing found");
                    searchProcess.parsedSuccessfully = true;
                } catch (exception) {
                    root.results = [];
                    root.error = qsTr("Wallhaven returned an invalid response");
                }
            }
        }

        onStarted: parsedSuccessfully = false
        onExited: exitCode => {
            if (token !== root.requestToken)
                return;
            root.loading = false;
            if (exitCode !== 0 && !parsedSuccessfully)
                root.error = qsTr("Could not load online wallpapers. Check your connection.");
        }
    }

    Process {
        id: downloadProcess
        property bool receivedPath: false
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const path = text.trim();
                if (!path)
                    return;
                downloadProcess.receivedPath = true;
                root.downloadedPath = path;
                root.wallpaperDownloaded(path);
            }
        }

        onStarted: receivedPath = false
        onExited: exitCode => {
            root.downloading = false;
            if (exitCode !== 0 || !receivedPath)
                root.downloadError = qsTr("Could not download this wallpaper");
        }
    }
}
