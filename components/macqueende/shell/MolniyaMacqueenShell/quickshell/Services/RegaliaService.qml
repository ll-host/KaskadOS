pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    Component.onCompleted: root.detect()

    readonly property var log: Log.scoped("RegaliaService")
    readonly property string runtimeDirectory: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string socketPath: runtimeDirectory.length > 0 ? runtimeDirectory + "/regalia/regaliad.sock" : ""
    readonly property int minimumApiVersion: 4

    property bool installed: false
    property bool checkingInstallation: true
    property bool daemonOnline: false
    property bool compatible: false
    property bool statusReceived: false
    property bool busy: false
    property bool statusRequestPending: false
    property int apiVersion: 0
    property var capabilities: []
    property bool enabled: false
    property bool connected: false
    property bool engineAvailable: false
    property string engineState: "unavailable"
    property string engineError: ""
    property string restoreError: ""
    property string configurationState: "incomplete"
    property string configurationError: ""
    property var activeServer: null
    property var activeRoute: null
    property string activeServerId: ""
    property string activeRouteId: ""
    property var profiles: []
    property var serverGroups: []
    property var routes: []
    property var applications: []
    property var processes: []
    property bool processesLoading: false
    property bool configurationLoading: false
    property int configurationRequestsPending: 0
    property string lastError: ""
    property var networkTestJob: null
    property var networkTestHistory: []
    property bool networkTestHistoryLoading: false
    property string networkTestError: ""
    property bool connectionAttemptActive: false

    readonly property bool available: installed && daemonOnline && compatible
    readonly property bool networkTestSupported: available && capabilities.includes("network.test")
    readonly property bool networkCompareSupported: networkTestSupported && capabilities.includes("network.test.compare")
    readonly property bool networkTestRunning: networkTestJob?.state === "running"
    readonly property bool configurationReady: configurationState === "ready"
    readonly property string availabilityState: {
        if (checkingInstallation || connectionAttemptActive || (daemonOnline && !statusReceived))
            return "checking";
        if (!installed)
            return "not-installed";
        if (!daemonOnline)
            return "service-offline";
        if (!compatible)
            return "incompatible";
        return "ready";
    }

    property var pendingRequests: ({})
    property int requestCounter: 0

    signal statusChanged
    signal configurationChanged
    signal networkTestChanged

    function detect() {
        if (packageCheck.running || socketProbe.running)
            return;
        disconnectSocket();
        checkingInstallation = true;
        lastError = "";
        packageCheck.running = true;
    }

    function probeDaemon() {
        if (!installed || socketProbe.running)
            return;
        socketProbe.running = true;
    }

    function disconnectSocket() {
        connectionAttemptWindow.stop();
        connectionAttemptActive = false;
        requestSocket.connected = false;
        daemonOnline = false;
        compatible = false;
        statusReceived = false;
        apiVersion = 0;
        capabilities = [];
        statusRequestPending = false;
        statusWatchdog.stop();
        networkTestPoll.stop();
        networkTestHistoryLoading = false;
        if (networkTestRunning) {
            networkTestError = I18n.tr("Regalia service went offline during the connection test");
            networkTestJob = null;
            networkTestChanged();
        }
        pendingRequests = ({});
    }

    function connectSocket() {
        if (!installed || socketPath.length === 0)
            return;
        connectionAttemptWindow.stop();
        connectionAttemptActive = true;
        requestSocket.connected = false;
        // Let DankSocket fully release a connection to an old socket inode
        // before reconnecting after regaliad has been restarted or upgraded.
        Qt.callLater(() => {
            if (!root.installed || root.socketPath.length === 0)
                return;
            requestSocket.connected = true;
            connectionAttemptWindow.restart();
        });
    }

    function sendRequest(method, params, callback) {
        if (!daemonOnline) {
            if (callback)
                callback({"error": {"code": "daemon_offline", "message": "Regalia service is offline"}});
            return;
        }
        requestCounter++;
        const id = Date.now() + requestCounter;
        const request = {"id": id, "method": method};
        if (params !== null && params !== undefined)
            request.params = params;
        if (callback)
            pendingRequests[id] = callback;
        requestSocket.send(request);
    }

    function handleResponse(response) {
        const callback = pendingRequests[response.id];
        if (!callback)
            return;
        delete pendingRequests[response.id];
        callback(response);
    }

    function errorMessage(error) {
        if (!error)
            return "";
        if (typeof error === "string")
            return error;
        return error.message || error.code || JSON.stringify(error);
    }

    function refreshStatus() {
        if (!daemonOnline || statusRequestPending)
            return;
        statusRequestPending = true;
        statusWatchdog.restart();
        sendRequest("status", null, response => {
            statusWatchdog.stop();
            statusRequestPending = false;
            if (response.error) {
                lastError = errorMessage(response.error);
                return;
            }
            applyStatus(response.result || {});
        });
    }

    Timer {
        id: statusWatchdog
        interval: 2500
        repeat: false
        onTriggered: {
            root.lastError = I18n.tr("Regalia service did not respond");
            root.disconnectSocket();
        }
    }

    function applyStatus(status) {
        statusReceived = true;
        apiVersion = status.apiVersion || 0;
        capabilities = status.capabilities || [];
        compatible = apiVersion >= minimumApiVersion && capabilities.includes("vpn.toggle");
        enabled = status.enabled === true;
        connected = status.connected === true;
        engineAvailable = status.engineAvailable === true;
        engineState = status.engine || "unavailable";
        engineError = status.engineError || "";
        restoreError = status.restoreError || "";
        configurationState = status.configuration || "incomplete";
        configurationError = status.configurationError || "";
        activeServer = status.activeServer || null;
        activeRoute = status.activeRoute || null;
        activeServerId = status.activeServerId || "";
        activeRouteId = status.activeRouteId || "";
        lastError = "";
        statusChanged();
        refreshConfiguration();
    }

    function refreshConfiguration() {
        if (!available || configurationLoading)
            return;
        configurationLoading = true;
        configurationRequestsPending = 4;
        requestCollection("profiles.list", result => {
            profiles = result || [];
        });
        requestCollection("servers.list", result => {
            serverGroups = result?.profiles || [];
            activeServerId = result?.activeServerId || activeServerId;
        });
        requestCollection("routes.list", result => {
            routes = result?.items || [];
            activeRouteId = result?.activeRouteId || activeRouteId;
        });
        requestCollection("apps.list", result => {
            applications = result || [];
        });
    }

    function requestCollection(method, applyResult) {
        sendRequest(method, null, response => {
            if (response.error)
                lastError = errorMessage(response.error);
            else
                applyResult(response.result);
            configurationRequestsPending--;
            if (configurationRequestsPending <= 0) {
                configurationRequestsPending = 0;
                configurationLoading = false;
                configurationChanged();
            }
        });
    }

    function refreshProcesses() {
        if (!available || processesLoading)
            return;
        processesLoading = true;
        sendRequest("apps.processes", null, response => {
            processesLoading = false;
            if (response.error) {
                lastError = errorMessage(response.error);
                ToastService.showError(I18n.tr("Failed to scan running processes"), lastError);
                return;
            }
            processes = response.result || [];
        });
    }

    function mutationFailed(title, response) {
        busy = false;
        lastError = errorMessage(response.error);
        ToastService.showError(I18n.tr(title), lastError);
    }

    function finishMutation(message) {
        busy = false;
        lastError = "";
        if (message)
            ToastService.showInfo(I18n.tr(message));
        refreshStatus();
    }

    function createProfile(name, subscriptionUrl) {
        if (!available || busy || name.trim().length === 0 || subscriptionUrl.trim().length === 0)
            return;
        busy = true;
        sendRequest("profiles.create", {"name": name.trim(), "subscriptionUrl": subscriptionUrl.trim()}, response => {
            if (response.error) {
                mutationFailed("Failed to add subscription", response);
                return;
            }
            const id = response.result?.id || "";
            if (id.length === 0) {
                busy = false;
                refreshConfiguration();
                return;
            }
            sendRequest("profiles.refresh", {"id": id}, refreshResponse => {
                if (refreshResponse.error) {
                    mutationFailed("Failed to download subscription", refreshResponse);
                    refreshConfiguration();
                    return;
                }
                finishMutation("Subscription added");
            });
        });
    }

    function refreshProfile(id) {
        if (!available || busy || !id)
            return;
        busy = true;
        sendRequest("profiles.refresh", {"id": id}, response => {
            if (response.error) {
                mutationFailed("Failed to update subscription", response);
                refreshConfiguration();
                return;
            }
            finishMutation("Subscription updated");
        });
    }

    function deleteProfile(id) {
        if (!available || busy || !id)
            return;
        busy = true;
        sendRequest("profiles.delete", {"id": id}, response => {
            if (response.error) {
                mutationFailed("Failed to delete subscription", response);
                return;
            }
            finishMutation("Subscription deleted");
        });
    }

    function selectServer(id) {
        if (!available || busy || !id)
            return;
        busy = true;
        sendRequest("servers.select", {"id": id}, response => {
            if (response.error) {
                mutationFailed("Failed to select server", response);
                return;
            }
            finishMutation("Server selected");
        });
    }

    function createRoute(name, defaultOutbound) {
        if (!available || busy || name.trim().length === 0)
            return;
        busy = true;
        sendRequest("routes.create", {"name": name.trim(), "defaultOutbound": defaultOutbound}, response => {
            if (response.error) {
                mutationFailed("Failed to create routing profile", response);
                return;
            }
            const id = response.result?.id || "";
            if (id.length === 0) {
                finishMutation("Routing profile created");
                return;
            }
            sendRequest("routes.activate", {"id": id}, activateResponse => {
                if (activateResponse.error) {
                    mutationFailed("Failed to activate routing profile", activateResponse);
                    return;
                }
                finishMutation("Routing profile created");
            });
        });
    }

    function activateRoute(id) {
        if (!available || busy || !id)
            return;
        busy = true;
        sendRequest("routes.activate", {"id": id}, response => {
            if (response.error) {
                mutationFailed("Failed to activate routing profile", response);
                return;
            }
            finishMutation("Routing profile selected");
        });
    }

    function deleteRoute(id) {
        if (!available || busy || !id)
            return;
        busy = true;
        sendRequest("routes.delete", {"id": id}, response => {
            if (response.error) {
                mutationFailed("Failed to delete routing profile", response);
                return;
            }
            finishMutation("Routing profile deleted");
        });
    }

    function setRouteApplication(routeId, app, outbound) {
        if (!available || busy || enabled || !routeId || !app?.processPath)
            return;
        busy = true;
        sendRequest("routes.app.set", {
            "routeId": routeId,
            "app": {
                "desktopId": app.desktopId || "",
                "name": app.name || "",
                "icon": app.icon || "",
                "processPath": app.processPath,
                "outbound": outbound
            }
        }, response => {
            if (response.error) {
                mutationFailed("Failed to save application route", response);
                return;
            }
            finishMutation("Application route saved");
        });
    }

    function removeRouteApplication(routeId, processPath) {
        if (!available || busy || enabled || !routeId || !processPath)
            return;
        busy = true;
        sendRequest("routes.app.remove", {
            "routeId": routeId,
            "processPath": processPath
        }, response => {
            if (response.error) {
                mutationFailed("Failed to remove application route", response);
                return;
            }
            finishMutation("Application route removed");
        });
    }

    function setEnabled(value) {
        if (!available || busy)
            return;
        busy = true;
        sendRequest("vpn.setEnabled", {"enabled": value}, response => {
            busy = false;
            if (response.error) {
                lastError = errorMessage(response.error);
                ToastService.showError(I18n.tr("VPN operation failed"), lastError);
                refreshStatus();
                return;
            }
            applyStatus(response.result || {});
        });
    }

    function startNetworkTest(mode, network) {
        if (!networkTestSupported || networkTestRunning)
            return;
        networkTestError = "";
        sendRequest("network.test.start", {"mode": mode, "network": network || {}}, response => {
            if (response.error) {
                networkTestError = errorMessage(response.error);
                ToastService.showError(I18n.tr("Connection test failed"), networkTestError);
                networkTestChanged();
                return;
            }
            networkTestJob = response.result || null;
            networkTestPoll.restart();
            networkTestChanged();
        });
    }

    function cancelNetworkTest() {
        const id = networkTestJob?.id || "";
        if (!networkTestRunning || id.length === 0)
            return;
        sendRequest("network.test.cancel", {"id": id}, response => {
            if (!response.error)
                networkTestJob = response.result || networkTestJob;
            networkTestChanged();
        });
    }

    function pollNetworkTest() {
        const id = networkTestJob?.id || "";
        if (!networkTestRunning || id.length === 0)
            return;
        sendRequest("network.test.status", {"id": id}, response => {
            if (response.error) {
                networkTestError = errorMessage(response.error);
                networkTestPoll.stop();
                networkTestChanged();
                return;
            }
            networkTestJob = response.result || networkTestJob;
            if (networkTestRunning)
                networkTestPoll.restart();
            else {
                networkTestPoll.stop();
                if (networkTestJob?.state === "failed")
                    networkTestError = networkTestJob.error || I18n.tr("Connection test failed");
                refreshNetworkTestHistory();
            }
            networkTestChanged();
        });
    }

    function refreshNetworkTestHistory() {
        if (!networkTestSupported || networkTestHistoryLoading)
            return;
        networkTestHistoryLoading = true;
        sendRequest("network.test.history", null, response => {
            networkTestHistoryLoading = false;
            if (response.error) {
                networkTestError = errorMessage(response.error);
                networkTestChanged();
                return;
            }
            networkTestHistory = response.result?.items || [];
            networkTestChanged();
        });
    }

    function clearNetworkTestHistory() {
        if (!networkTestSupported)
            return;
        sendRequest("network.test.history.clear", null, response => {
            if (response.error) {
                networkTestError = errorMessage(response.error);
                networkTestChanged();
                return;
            }
            networkTestHistory = [];
            networkTestJob = null;
            networkTestChanged();
        });
    }

    function startDaemon() {
        if (!installed || startServiceProcess.running)
            return;
        busy = true;
        lastError = "";
        startServiceProcess.running = true;
    }

    Process {
        id: packageCheck
        command: ["sh", "-c", "command -v regalia >/dev/null 2>&1 && command -v regaliad >/dev/null 2>&1"]
        running: false

        onExited: exitCode => {
            root.installed = exitCode === 0;
            root.checkingInstallation = false;
            if (root.installed)
                root.probeDaemon();
            else
                root.disconnectSocket();
        }
    }

    Process {
        id: socketProbe
        command: ["test", "-S", root.socketPath]
        running: false

        onExited: exitCode => {
            if (exitCode === 0)
                root.connectSocket();
            else
                root.disconnectSocket();
        }
    }

    Process {
        id: startServiceProcess
        command: ["systemctl", "--user", "start", "regaliad.service"]
        running: false

        stderr: StdioCollector {
            id: startServiceError
        }

        onExited: exitCode => {
            root.busy = false;
            if (exitCode !== 0) {
                root.lastError = startServiceError.text.trim() || I18n.tr("Failed to start Regalia service");
                return;
            }
            reconnectDelay.restart();
        }
    }

    Timer {
        id: reconnectDelay
        interval: 500
        repeat: false
        onTriggered: root.probeDaemon()
    }

    Timer {
        id: connectionAttemptWindow
        interval: 5000
        repeat: false
        onTriggered: {
            root.connectionAttemptActive = false;
            if (!requestSocket.linkUp) {
                requestSocket.connected = false;
                root.daemonOnline = false;
                root.lastError = I18n.tr("Could not connect to the Regalia service");
            }
        }
    }

    Timer {
        id: networkTestPoll
        interval: 650
        repeat: false
        onTriggered: root.pollNetworkTest()
    }

    DankSocket {
        id: requestSocket
        path: root.socketPath
        connected: false

        onConnectionStateChanged: {
            root.daemonOnline = linkUp;
            if (linkUp) {
                connectionAttemptWindow.stop();
                root.connectionAttemptActive = false;
                root.statusReceived = false;
                root.lastError = "";
                root.refreshStatus();
            } else {
                root.compatible = false;
                root.statusReceived = false;
                root.statusRequestPending = false;
                statusWatchdog.stop();
                networkTestPoll.stop();
                root.networkTestHistoryLoading = false;
                if (root.networkTestRunning) {
                    root.networkTestError = I18n.tr("Regalia service went offline during the connection test");
                    root.networkTestJob = null;
                    root.networkTestChanged();
                }
                root.pendingRequests = ({});
                // DankSocket normally reconnects forever. Keep retries bounded
                // while the integrated service is being restarted.
                if (!root.connectionAttemptActive)
                    requestSocket.connected = false;
            }
        }

        parser: SplitParser {
            onRead: line => {
                if (!line || line.length === 0)
                    return;
                try {
                    root.handleResponse(JSON.parse(line));
                } catch (error) {
                    root.log.warn("Invalid Regalia response:", line.substring(0, 120));
                }
            }
        }
    }
}
