pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root

    readonly property string homePath: Paths.strip(StandardPaths.writableLocation(StandardPaths.HomeLocation))
    property bool available: false
    property bool loading: false
    property string currentPath: homePath
    property string parentPath: ""
    property bool showHidden: false
    property var entries: []
    property var selectedEntry: null

    signal windowRequested(string path)

    Connections {
        target: DMSService
        function onCapabilitiesReceived() { root._updateAvailability(); }
        function onConnectionStateChanged() { root._updateAvailability(); }
        function onFilesStateUpdate(data) {
            if (data?.show)
                root.openWindow(data.path || root.homePath);
        }
    }

    Component.onCompleted: _updateAvailability()

    function _updateAvailability() {
        available = DMSService.isConnected
                 && Array.isArray(DMSService.capabilities)
                 && DMSService.capabilities.includes("files");
    }

    function openWindow(path) {
        const target = path || homePath;
        windowRequested(target);
    }

    function navigate(path) {
        if (!available || !path)
            return;
        loading = true;
        selectedEntry = null;
        DMSService.filesList(path, showHidden, response => {
            loading = false;
            if (response?.result) {
                currentPath = response.result.path;
                parentPath = response.result.parent || "";
                entries = response.result.entries || [];
            } else {
                ToastService.showError(response?.error || "Не удалось открыть папку.", "", "", "files");
            }
        });
    }

    function refresh() { navigate(currentPath); }

    function setShowHidden(value) {
        showHidden = value;
        refresh();
    }

    function activate(entry) {
        if (!entry)
            return;
        if (entry.directory) {
            navigate(entry.path);
            return;
        }
        const lower = entry.name.toLowerCase();
        if (lower.includes(".pkg.tar.")) {
            SoftwareService.installLocal(entry.path);
            return;
        }
        if (lower.endsWith(".exe")) {
            WindowsAppsService.openExecutable(entry.path);
            return;
        }
        if (isArchive(lower)) {
            extract(entry);
            return;
        }
        openFile(entry.path);
    }

    function isArchive(name) {
        return [".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".txz"]
            .some(suffix => name.endsWith(suffix));
    }

    function openFile(path) {
        DMSService.filesOpen(path, response => {
            if (response?.error)
                ToastService.showError("Не удалось открыть файл.", "", "", "files");
        });
    }

    function makeDirectory(name) {
        DMSService.filesMkdir(currentPath, name, response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else
                refresh();
        });
    }

    function renameSelected(name) {
        if (!selectedEntry)
            return;
        DMSService.filesRename(selectedEntry.path, name, response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else
                refresh();
        });
    }

    function trashSelected() {
        if (!selectedEntry)
            return;
        DMSService.filesTrash(selectedEntry.path, response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else {
                ToastService.showInfo("Перемещено в корзину: " + selectedEntry.name, "", "", "files");
                refresh();
            }
        });
    }

    function extract(entry) {
        DMSService.filesExtract(entry.path, response => {
            if (response?.error)
                ToastService.showError("Не удалось распаковать архив.", "", "", "files");
            else {
                ToastService.showInfo("Архив распакован.", "", "", "files");
                refresh();
            }
        });
    }

    function archiveSelected(format) {
        if (!selectedEntry)
            return;
        DMSService.filesArchive(selectedEntry.path, format, response => {
            if (response?.error)
                ToastService.showError("Не удалось создать архив.", "", "", "files");
            else {
                ToastService.showInfo("Архив создан.", "", "", "files");
                refresh();
            }
        });
    }
}
