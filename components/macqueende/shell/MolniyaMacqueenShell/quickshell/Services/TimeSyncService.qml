pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Services

Singleton {
    id: root

    property bool loaded: false
    property bool available: false
    property bool automatic: false
    property bool timeSynchronized: false
    property bool changing: false
    property int requestGeneration: 0
    property string timezone: ""
    property string error: ""

    readonly property bool backendAvailable: DMSService.isConnected
        && Array.isArray(DMSService.capabilities)
        && DMSService.capabilities.includes("timedate")

    Component.onCompleted: refresh()
    onBackendAvailableChanged: refresh()

    Connections {
        target: DMSService
        function onCapabilitiesReceived() { root.refresh(); }
        function onConnectionStateChanged() { root.refresh(); }
    }

    Timer {
        interval: 10000
        repeat: true
        running: root.backendAvailable
        onTriggered: root.refresh()
    }

    function applyState(state) {
        if (!state)
            return;
        available = state.available === true;
        automatic = state.automatic === true;
        timeSynchronized = state.synchronized === true;
        timezone = state.timezone || "";
        error = "";
        loaded = true;
    }

    function refresh() {
        if (changing)
            return;
        if (!backendAvailable) {
            requestGeneration++;
            loaded = false;
            available = false;
            automatic = false;
            timeSynchronized = false;
            timezone = "";
            return;
        }
        const generation = ++requestGeneration;
        DMSService.timeStatus(response => {
            if (generation !== root.requestGeneration)
                return;
            if (response?.result) {
                root.applyState(response.result);
            } else {
                root.error = response?.error || "Не удалось прочитать состояние времени";
                root.loaded = true;
                root.available = false;
            }
        });
    }

    function setAutomatic(enabled) {
        if (!available || changing)
            return;
        changing = true;
        const generation = ++requestGeneration;
        error = "";
        DMSService.timeSetAutomatic(enabled, response => {
            if (generation !== root.requestGeneration)
                return;
            root.changing = false;
            if (response?.result) {
                root.applyState(response.result);
            } else {
                root.error = response?.error || "Не удалось изменить синхронизацию времени";
                ToastService.showError("Не удалось изменить настройку времени", root.error, "", "schedule");
                root.refresh();
            }
        });
    }
}
