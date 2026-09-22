pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Services

Singleton {
    id: root

    property bool available: false
    property bool searching: false
    property string query: ""
    property string sourceFilter: "all"
    property string section: "store"
    property var searchResults: []
    property string searchProblem: ""
    property var installedItems: []
    property var sources: []
    property var operation: ({"phase": "idle"})
    property bool loadingInstalled: false
    property bool _completionHandled: false
    property var _submittedKeys: ({})

    readonly property bool operationRunning: operation?.phase === "preparing" || operation?.phase === "running"
    readonly property bool operationBusy: operationRunning || (operation?.queue?.length || 0) > 0
    readonly property int queuedCount: operation?.queue?.length || 0
    readonly property int remainingCount: Math.max(0, (operation?.total || 0) - (operation?.completed || 0))

    Connections {
        target: DMSService
        function onCapabilitiesReceived() { root._updateAvailability(); }
        function onConnectionStateChanged() { root._updateAvailability(); }
    }

    Component.onCompleted: _updateAvailability()

    Timer {
        id: searchDebounce
        interval: 280
        repeat: false
        onTriggered: root._performSearch()
    }

    Timer {
        interval: 800
        repeat: true
        running: root.operationBusy
        onTriggered: root.refreshOperation()
    }

    function _updateAvailability() {
        available = DMSService.isConnected
                 && Array.isArray(DMSService.capabilities)
                 && DMSService.capabilities.includes("software");
    }

    function sourceLabel(source) {
        switch (source) {
        case "pacman": return "Pacman";
        case "aur": return "AUR";
        case "flatpak": return "Flatpak";
        case "local": return "Локальный пакет";
        case "foreign": return "AUR / локальный";
        default: return source || "Неизвестно";
        }
    }

    function sourceFilterLabel(source) {
        switch (source) {
        case "pacman": return "Pacman";
        case "aur": return "AUR";
        case "flatpak": return "Flatpak";
        default: return "Все источники";
        }
    }

    function sourceAvailable(source) {
        return source === "all" || (sources || []).includes(source);
    }

    function setSourceFilter(value) {
        const next = ["all", "pacman", "aur", "flatpak"].includes(value) ? value : "all";
        if (sourceFilter === next)
            return;
        sourceFilter = next;
        searchProblem = "";
        if (query.length >= 2) {
            searching = true;
            searchDebounce.restart();
        }
    }

    function setQuery(value) {
        query = (value || "").trim();
        searchProblem = "";
        if (query.length < 2) {
            searchDebounce.stop();
            searchResults = [];
            searching = false;
            return;
        }
        searching = true;
        searchDebounce.restart();
    }

    function _performSearch() {
        if (!available || query.length < 2) {
            searching = false;
            return;
        }
        const expected = query;
        const expectedSource = sourceFilter;
        DMSService.softwareSearch(expected, expectedSource, response => {
            if (expected !== query || expectedSource !== sourceFilter)
                return;
            searching = false;
            if (response?.result) {
                searchResults = response.result.items || [];
                sources = response.result.sources || [];
                searchProblem = response.result.problem || "";
                if (searchProblem.length > 0)
                    ToastService.showWarning(searchProblem, "", "", "software-search");
            } else {
                searchResults = [];
                searchProblem = "Не удалось выполнить поиск приложений.";
                ToastService.showWarning("Не удалось выполнить поиск приложений.", "", "", "software-search");
            }
        });
    }

    function loadInstalled() {
        if (!available || loadingInstalled)
            return;
        loadingInstalled = true;
        DMSService.softwareInstalled(response => {
            loadingInstalled = false;
            if (response?.result) {
                installedItems = response.result.items || [];
                sources = response.result.sources || [];
            } else {
                ToastService.showWarning("Не удалось прочитать список установленных пакетов.", "", "", "software-installed");
            }
        });
    }

    function install(item) {
        if (!available || !item || itemOperationState(item) !== "idle")
            return;
        _completionHandled = false;
        _rememberSubmitted(item);
        DMSService.softwareInstall(item, response => {
            if (response?.result) {
                operation = response.result;
                _handleCompletion();
                if ((operation?.queue?.length || 0) > 0)
                    ToastService.showInfo("Добавлено в очередь: " + (item.name || item.packageName), "", "", "software-queue");
            } else {
                _forgetSubmitted(item);
                ToastService.showError(response?.error || "Не удалось начать установку.", "", "", "software-operation");
            }
        });
    }

    function remove(item) {
        if (!available || !item || itemOperationState(item) !== "idle")
            return;
        _completionHandled = false;
        _rememberSubmitted(item);
        DMSService.softwareRemove(item, response => {
            if (response?.result) {
                operation = response.result;
                _handleCompletion();
            } else {
                _forgetSubmitted(item);
                ToastService.showError(response?.error || "Не удалось начать удаление.", "", "", "software-operation");
            }
        });
    }

    function installLocal(path) {
        if (!available || !path)
            return;
        _completionHandled = false;
        DMSService.softwareInstallLocal(path, response => {
            if (response?.result) {
                operation = response.result;
                _handleCompletion();
            } else {
                ToastService.showError(response?.error || "Не удалось открыть пакет.", "", "", "software-operation");
            }
        });
    }

    function cancel() {
        if (operationRunning)
            DMSService.softwareCancel(null);
    }

    function refreshOperation() {
        if (!available)
            return;
        DMSService.softwareState(response => {
            if (!response?.result)
                return;
            operation = response.result;
            _handleCompletion();
        });
    }

    function _handleCompletion() {
        const phase = operation?.phase || "idle";
        if ((phase !== "complete" && phase !== "error") || _completionHandled)
            return;
        _completionHandled = true;
        _submittedKeys = {};
        if (phase === "complete") {
            ToastService.showInfo(operation.message || "Операция завершена.", "", "", "software-operation");
            loadInstalled();
            if (query.length >= 2)
                _performSearch();
        } else {
            ToastService.showError(operation.message || "Операция не завершена.", "Подробности доступны в журнале операции.", "", "software-operation");
        }
    }

    function itemKey(item) {
        if (!item)
            return "";
        return (item.source || "") + ":" + (item.id || item.packageName || "");
    }

    function itemOperationState(item) {
        const key = itemKey(item);
        if (key.length === 0)
            return "idle";
        if (operationRunning && itemKey(operation?.item) === key)
            return "running";
        const queued = operation?.queue || [];
        for (let i = 0; i < queued.length; i++) {
            if (itemKey(queued[i].item) === key)
                return "queued";
        }
        if (_submittedKeys[key])
            return operationBusy ? "processed" : "requesting";
        return "idle";
    }

    function _rememberSubmitted(item) {
        const key = itemKey(item);
        if (key.length === 0)
            return;
        const next = Object.assign({}, _submittedKeys);
        next[key] = true;
        _submittedKeys = next;
    }

    function _forgetSubmitted(item) {
        const key = itemKey(item);
        if (!_submittedKeys[key])
            return;
        const next = Object.assign({}, _submittedKeys);
        delete next[key];
        _submittedKeys = next;
    }

    function itemQueuePosition(item) {
        const key = itemKey(item);
        const queued = operation?.queue || [];
        for (let i = 0; i < queued.length; i++) {
            if (itemKey(queued[i].item) === key)
                return queued[i].position || (i + 1);
        }
        return 0;
    }
}
