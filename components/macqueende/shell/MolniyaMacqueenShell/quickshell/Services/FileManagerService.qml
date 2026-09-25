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
    property string viewMode: "files"
    property bool showHidden: false
    property var entries: []
    property var selectedEntry: null
    property var devices: []
    property var clipboardEntry: null
    property bool clipboardMove: false
    property var operation: null

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

    Component.onCompleted: {
        _updateAvailability();
        refreshDevices();
    }

    Timer {
        interval: 1500
        running: root.available
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshDevices()
    }

    Timer {
        interval: 250
        running: root.operation !== null
              && ["scanning", "running"].includes(root.operation.state)
        repeat: true
        onTriggered: root.pollOperation()
    }

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
        viewMode = "files";
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

    function refresh() {
        if (viewMode === "trash")
            openTrash();
        else
            navigate(currentPath);
    }

    function openTrash() {
        if (!available)
            return;
        loading = true;
        viewMode = "trash";
        selectedEntry = null;
        DMSService.filesTrashList(response => {
            loading = false;
            if (response?.result)
                entries = response.result;
            else
                ToastService.showError(response?.error || "Не удалось открыть корзину.", "", "", "files");
        });
    }

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

    function restoreSelected() {
        if (!selectedEntry || viewMode !== "trash")
            return;
        DMSService.filesTrashRestore(selectedEntry.name, selectedEntry.trashDir, response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else {
                ToastService.showInfo("Объект восстановлен.", selectedEntry.originalPath || "", "", "files");
                openTrash();
            }
        });
    }

    function deleteSelectedPermanently() {
        deleteTrashEntry(selectedEntry);
    }

    function deleteTrashEntry(entry) {
        if (!entry || viewMode !== "trash")
            return;
        DMSService.filesTrashDelete(entry.name, entry.trashDir, response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else
                openTrash();
        });
    }

    function emptyTrash() {
        DMSService.filesTrashEmpty(response => {
            if (response?.error)
                ToastService.showError(response.error, "", "", "files");
            else {
                ToastService.showInfo("Корзина очищена.", "", "", "files");
                openTrash();
            }
        });
    }

    function rememberSelected(move) {
        if (!selectedEntry || viewMode !== "files")
            return;
        clipboardEntry = selectedEntry;
        clipboardMove = move === true;
        ToastService.showInfo(clipboardMove ? "Выбрано для перемещения" : "Выбрано для копирования",
                              selectedEntry.name, "", "files");
    }

    function paste() {
        if (!clipboardEntry || viewMode !== "files" || operationActive())
            return;
        DMSService.filesTransfer(clipboardEntry.path, currentPath, clipboardMove, response => {
            if (response?.result) {
                operation = response.result;
                if (clipboardMove)
                    clipboardEntry = null;
            } else {
                ToastService.showError(response?.error || "Не удалось начать операцию.", "", "", "files");
            }
        });
    }

    function pollOperation() {
        if (!operation?.id)
            return;
        DMSService.filesOperation(operation.id, response => {
            if (!response?.result)
                return;
            operation = response.result;
            if (operation.state === "completed") {
                ToastService.showInfo(operation.kind === "move" ? "Перемещение завершено." : "Копирование завершено.",
                                      operation.name || "", "", "files");
                refresh();
            } else if (operation.state === "failed") {
                ToastService.showError("Файловая операция не выполнена.", operation.error || "", "", "files");
            }
        });
    }

    function cancelOperation() {
        if (!operation?.id)
            return;
        DMSService.filesCancelOperation(operation.id, () => pollOperation());
    }

    function dismissOperation() {
        if (!operationActive())
            operation = null;
    }

    function operationActive() {
        return operation !== null && ["scanning", "running"].includes(operation.state);
    }

    function refreshDevices() {
        if (!available)
            return;
        DMSService.filesDevices(response => {
            if (response?.result)
                devices = response.result;
        });
    }

    function openDevice(device) {
        if (!device)
            return;
        if (device.mounted && device.mountPoint) {
            navigate(device.mountPoint);
            return;
        }
        DMSService.filesMount(device.path, response => {
            if (response?.result) {
                refreshDevices();
                const mountPoint = response.result.value || "";
                if (mountPoint)
                    navigate(mountPoint);
            } else {
                ToastService.showError("Не удалось подключить накопитель.", response?.error || "", "", "files");
            }
        });
    }

    function safelyRemove(device) {
        if (!device)
            return;
        DMSService.filesSafelyRemove(device.path, response => {
            if (response?.error) {
                ToastService.showError("Накопитель пока нельзя извлечь.", response.error, "", "files");
            } else {
                if (device.mountPoint && currentPath.startsWith(device.mountPoint))
                    navigate(homePath);
                ToastService.showInfo("Накопитель можно безопасно извлечь.", device.label || device.name, "", "files");
                refreshDevices();
            }
        });
    }

    function compatibilityLabel(device) {
        if (!device)
            return "";
        if (device.compatibility === "windows") return "Windows";
        if (device.compatibility === "kaskados") return "KaskadOS";
        if (device.compatibility === "universal") return "Windows · KaskadOS · другие";
        return device.fileSystem ? device.fileSystem.toUpperCase() : "Накопитель";
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
