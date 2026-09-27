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
    property var storageDisks: []
    property var selectedDisk: null
    property var selectedRegion: null
    property bool storageLoading: false
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
        onTriggered: {
            root.refreshDevices();
            if (root.viewMode === "storage" && !root.operationActive())
                root.refreshStorage();
        }
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
        else if (viewMode === "storage")
            refreshStorage();
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

    function openStorage() {
        viewMode = "storage";
        selectedEntry = null;
        refreshStorage();
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
                if (operation.kind === "format") {
                    ToastService.showInfo("Форматирование завершено.", operation.detail || "Накопитель готов", "", "files");
                    refreshDevices();
                    if (operation.destination)
                        navigate(operation.destination);
                } else if ((operation.kind || "").startsWith("storage-")) {
                    ToastService.showInfo("Операция с накопителем завершена.", operation.detail || "", "", "files");
                    refreshDevices();
                    refreshStorage();
                } else {
                    ToastService.showInfo(operation.kind === "move" ? "Перемещение завершено." : "Копирование завершено.",
                                          operation.name || "", "", "files");
                    refresh();
                }
            } else if (operation.state === "failed") {
                ToastService.showError(operation.kind === "format" ? "Форматирование не выполнено." : "Файловая операция не выполнена.",
                                       operation.error || "", "", "files");
                if (operation.kind === "format" || (operation.kind || "").startsWith("storage-"))
                    refreshDevices();
                if ((operation.kind || "").startsWith("storage-"))
                    refreshStorage();
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

    function refreshStorage() {
        if (!available)
            return;
        storageLoading = true;
        const selectedDiskPath = selectedDisk?.path || "";
        const selectedRegionPath = selectedRegion?.path || "";
        const selectedRegionOffset = Number(selectedRegion?.offsetBytes || -1);
        DMSService.filesStorage(response => {
            storageLoading = false;
            if (!response?.result) {
                ToastService.showError("Не удалось получить список дисков.", response?.error || "", "", "files");
                return;
            }
            storageDisks = response.result;
            selectedDisk = storageDisks.find(disk => disk.path === selectedDiskPath) || storageDisks[0] || null;
            if (!selectedDisk) {
                selectedRegion = null;
                return;
            }
            selectedRegion = (selectedDisk.regions || []).find(region =>
                (selectedRegionPath && region.path === selectedRegionPath)
                || (!selectedRegionPath && Number(region.offsetBytes) === selectedRegionOffset)) || null;
        });
    }

    function selectStorageDisk(disk) {
        selectedDisk = disk;
        selectedRegion = null;
    }

    function selectStorageRegion(region) {
        selectedRegion = region;
    }

    function mountRegion(region) {
        if (!region?.path)
            return;
        DMSService.filesMount(region.path, response => {
            if (response?.error)
                ToastService.showError("Не удалось подключить раздел.", response.error, "", "files");
            else {
                refreshDevices();
                refreshStorage();
            }
        });
    }

    function unmountRegion(region) {
        if (!region?.path)
            return;
        DMSService.filesUnmount(region.path, response => {
            if (response?.error)
                ToastService.showError("Не удалось отключить раздел.", response.error, "", "files");
            else {
                if (region.mountPoint && currentPath.startsWith(region.mountPoint))
                    navigate(homePath);
                refreshDevices();
                refreshStorage();
            }
        });
    }

    function _acceptStorageOperation(response, failureTitle, callback) {
        if (response?.result) {
            operation = response.result;
            if (callback)
                callback(true);
        } else {
            ToastService.showError(failureTitle, response?.error || "", "", "files");
            if (callback)
                callback(false);
        }
    }

    function createPartition(disk, region, sizeBytes, fileSystem, label, callback) {
        DMSService.filesPartitionCreate(disk.path, Number(region.offsetBytes), Number(sizeBytes), fileSystem, label,
            response => _acceptStorageOperation(response, "Не удалось создать раздел.", callback));
    }

    function deletePartition(region, callback) {
        DMSService.filesPartitionDelete(region.path,
            response => _acceptStorageOperation(response, "Не удалось удалить раздел.", callback));
    }

    function createPartitionTable(disk, table, callback) {
        DMSService.filesPartitionTableCreate(disk.path, table,
            response => _acceptStorageOperation(response, "Не удалось очистить накопитель.", callback));
    }

    function resizePartition(region, sizeBytes, callback) {
        DMSService.filesPartitionResize(region.path, Number(sizeBytes),
            response => _acceptStorageOperation(response, "Не удалось изменить размер раздела.", callback));
    }

    function checkFilesystem(region, repair, callback) {
        const done = response => _acceptStorageOperation(response,
            repair ? "Не удалось исправить файловую систему." : "Не удалось проверить файловую систему.", callback);
        if (repair)
            DMSService.filesFilesystemRepair(region.path, done);
        else
            DMSService.filesFilesystemCheck(region.path, done);
    }

    function setFilesystemLabel(region, label, callback) {
        DMSService.filesFilesystemLabel(region.path, label, response => {
            if (response?.error) {
                ToastService.showError("Не удалось изменить имя раздела.", response.error, "", "files");
                if (callback) callback(false);
            } else {
                refreshDevices();
                refreshStorage();
                if (callback) callback(true);
            }
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

    function safelyRemoveDisk(disk) {
        if (!disk)
            return;
        const activeMount = (disk.regions || []).find(region => region.mountPoint
            && (currentPath === region.mountPoint || currentPath.startsWith(region.mountPoint + "/")));
        if (activeMount)
            navigate(homePath);
        DMSService.filesSafelyRemove(disk.path, response => {
            if (response?.error) {
                ToastService.showError("Накопитель пока нельзя извлечь.", response.error, "", "files");
            } else {
                ToastService.showInfo("Накопитель можно безопасно извлечь.", disk.model || disk.name, "", "files");
                refreshDevices();
                refreshStorage();
            }
        });
    }

    function formatDevice(device, fileSystem, label, callback) {
        if (!device || operationActive()) {
            if (callback)
                callback(false);
            return;
        }
        if (device.mountPoint && (currentPath === device.mountPoint
                || currentPath.startsWith(device.mountPoint + "/")))
            navigate(homePath);
        DMSService.filesFormat(device.path, fileSystem, label, response => {
            if (response?.result) {
                operation = response.result;
                if (callback)
                    callback(true);
            } else {
                ToastService.showError("Не удалось начать форматирование.", response?.error || "", "", "files");
                if (callback)
                    callback(false);
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
