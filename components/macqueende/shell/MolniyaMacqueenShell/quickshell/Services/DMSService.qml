pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("DMSService")

    property bool dmsAvailable: false
    property var capabilities: []
    property int apiVersion: 0
    property string cliVersion: ""
    readonly property int expectedApiVersion: 1
    property var availableThemes: []
    property var installedThemes: []
    property bool isConnected: false
    property bool isConnecting: false
    property bool subscribeConnected: false

    readonly property string socketPath: Quickshell.env("DMS_SOCKET")

    property var pendingRequests: ({})
    property var clipboardRequestIds: ({})
    property int requestIdCounter: 0
    property bool shownOutdatedError: false
    property string updateCommand: "dms update"
    property bool checkingUpdateCommand: false

    signal themesListReceived(var themes)
    signal installedThemesReceived(var themes)
    signal themeSearchResultsReceived(var themes)
    signal operationSuccess(string message)
    signal operationError(string error)
    signal connectionStateChanged

    signal networkStateUpdate(var data)
    signal cupsStateUpdate(var data)
    signal loginctlStateUpdate(var data)
    signal capabilitiesReceived
    signal credentialsRequest(var data)
    signal bluetoothPairingRequest(var data)
    signal brightnessStateUpdate(var data)
    signal brightnessDeviceUpdate(var device)
    signal wlrOutputStateUpdate(var data)
    signal evdevStateUpdate(var data)
    signal gammaStateUpdate(var data)
    signal themeAutoStateUpdate(var data)
    signal wallpaperCycleUpdate(var data)
    signal openUrlRequested(string url)
    signal appPickerRequested(var data)
    signal screensaverStateUpdate(var data)
    signal freedesktopStateUpdate(var data)
    signal clipboardStateUpdate(var data)
    signal locationStateUpdate(var data)
    signal sysupdateStateUpdate(var data)
    signal filesStateUpdate(var data)
    signal tailscaleStateUpdate(var data)

    property bool capsLockState: false
    property bool screensaverInhibited: false
    property var screensaverInhibitors: []

    property var activeSubscriptions: ["network", "network.credentials", "loginctl", "freedesktop", "freedesktop.screensaver", "gamma", "theme.auto", "wallpaper", "bluetooth", "bluetooth.pairing", "brightness", "wlroutput", "evdev", "browser", "dbus", "clipboard", "sysupdate", "files"]

    Component.onCompleted: {
        if (socketPath && socketPath.length > 0) {
            detectUpdateCommand();
        }
    }

    function detectUpdateCommand() {
        checkingUpdateCommand = true;
        checkAurHelper.running = true;
    }

    function startSocketConnection() {
        if (socketPath && socketPath.length > 0) {
            testProcess.running = true;
        }
    }

    Process {
        id: checkAurHelper
        command: ["sh", "-c", "command -v paru || command -v yay"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                const helper = text.trim();
                if (helper.includes("paru")) {
                    checkDmsPackage.helper = "paru";
                    checkDmsPackage.running = true;
                } else if (helper.includes("yay")) {
                    checkDmsPackage.helper = "yay";
                    checkDmsPackage.running = true;
                } else {
                    updateCommand = "dms update";
                    checkingUpdateCommand = false;
                    startSocketConnection();
                }
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                updateCommand = "dms update";
                checkingUpdateCommand = false;
                startSocketConnection();
            }
        }
    }

    Process {
        id: checkDmsPackage
        property string helper: ""
        command: ["sh", "-c", "pacman -Qi dms-shell-git 2>/dev/null || pacman -Qi dms-shell-bin 2>/dev/null"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: {
                if (text.includes("dms-shell-git")) {
                    updateCommand = checkDmsPackage.helper + " -S dms-shell-git";
                } else if (text.includes("dms-shell-bin")) {
                    updateCommand = checkDmsPackage.helper + " -S dms-shell-bin";
                } else {
                    updateCommand = "dms update";
                }
                checkingUpdateCommand = false;
                startSocketConnection();
            }
        }

        onExited: exitCode => {
            if (exitCode !== 0) {
                updateCommand = "dms update";
                checkingUpdateCommand = false;
                startSocketConnection();
            }
        }
    }

    Process {
        id: testProcess
        command: ["test", "-S", root.socketPath]

        onExited: exitCode => {
            if (exitCode === 0) {
                root.dmsAvailable = true;
                connectSocket();
            } else {
                root.dmsAvailable = false;
            }
        }
    }

    function connectSocket() {
        if (!dmsAvailable || isConnected || isConnecting) {
            return;
        }

        isConnecting = true;
        requestSocket.connected = true;
    }

    DankSocket {
        id: requestSocket
        path: root.socketPath
        connected: false

        onConnectionStateChanged: {
            if (connected) {
                root.isConnected = true;
                root.isConnecting = false;
                root.connectionStateChanged();
                subscribeSocket.connected = true;
            } else {
                root.isConnected = false;
                root.isConnecting = false;
                root.apiVersion = 0;
                root.capabilities = [];
                root.connectionStateChanged();
            }
        }

        parser: SplitParser {
            onRead: line => {
                if (!line || line.length === 0)
                    return;

                let response;
                try {
                    response = JSON.parse(line);
                } catch (e) {
                    log.warn("Failed to parse request response:", line.substring(0, 100));
                    return;
                }
                const isClipboard = clipboardRequestIds[response.id];
                if (isClipboard)
                    delete clipboardRequestIds[response.id];
                else
                    log.debug("Request socket <<", line);
                handleResponse(response);
            }
        }
    }

    DankSocket {
        id: subscribeSocket
        path: root.socketPath
        connected: false

        onConnectionStateChanged: {
            root.subscribeConnected = connected;
            if (connected) {
                sendSubscribeRequest();
            }
        }

        parser: SplitParser {
            onRead: line => {
                if (!line || line.length === 0)
                    return;

                let response;
                try {
                    response = JSON.parse(line);
                } catch (e) {
                    log.warn("Failed to parse subscription event:", line.substring(0, 100));
                    return;
                }
                if (!line.includes("clipboard"))
                    log.debug("Subscribe socket <<", line);
                handleSubscriptionEvent(response);
            }
        }
    }

    function sendSubscribeRequest() {
        const request = {
            "method": "subscribe",
            "params": {
                "clientId": dbusClientId
            }
        };

        if (activeSubscriptions.length > 0) {
            request.params.services = activeSubscriptions;
            log.debug("Subscribing to services:", JSON.stringify(activeSubscriptions));
        } else {
            log.debug("Subscribing to all services");
        }

        subscribeSocket.send(request);
    }

    function subscribe(services) {
        if (!Array.isArray(services)) {
            services = [services];
        }

        activeSubscriptions = services;

        if (subscribeConnected) {
            subscribeSocket.connected = false;
            Qt.callLater(() => {
                subscribeSocket.connected = true;
            });
        }
    }

    function addSubscription(service) {
        if (activeSubscriptions.includes("all"))
            return;
        if (!activeSubscriptions.includes(service)) {
            const newSubs = [...activeSubscriptions, service];
            subscribe(newSubs);
        }
    }

    function removeSubscription(service) {
        if (activeSubscriptions.includes("all")) {
            const allServices = ["network", "loginctl", "freedesktop", "gamma", "bluetooth", "brightness", "browser", "location"];
            const filtered = allServices.filter(s => s !== service);
            subscribe(filtered);
        } else {
            const filtered = activeSubscriptions.filter(s => s !== service);
            if (filtered.length === 0) {
                log.warn("Cannot remove last subscription");
                return;
            }
            subscribe(filtered);
        }
    }

    function subscribeAll() {
        subscribe(["all"]);
    }

    function subscribeAllExcept(excludeServices) {
        if (!Array.isArray(excludeServices)) {
            excludeServices = [excludeServices];
        }

        const allServices = ["network", "loginctl", "freedesktop", "gamma", "theme.auto", "bluetooth", "cups", "brightness", "browser", "dbus", "location"];
        const filtered = allServices.filter(s => !excludeServices.includes(s));
        subscribe(filtered);
    }

    function handleSubscriptionEvent(response) {
        if (response.error) {
            if (response.error.includes("unknown method") && response.error.includes("subscribe")) {
                if (!shownOutdatedError) {
                    log.error("Server does not support subscribe method");
                    ToastService.showError(I18n.tr("DMS out of date"), I18n.tr("To update, run the following command:"), updateCommand);
                    shownOutdatedError = true;
                }
            }
            return;
        }

        if (!response.result) {
            return;
        }

        const service = response.result.service;
        const data = response.result.data;

        if (service === "server") {
            apiVersion = data.apiVersion || 0;
            cliVersion = data.cliVersion || "";
            capabilities = data.capabilities || [];

            log.info("Connected (API v" + apiVersion + ", CLI " + cliVersion + ") -", JSON.stringify(capabilities));

            if (apiVersion < expectedApiVersion) {
                ToastService.showError(I18n.tr("DMS server is outdated (API v%1, expected v%2)").arg(apiVersion).arg(expectedApiVersion));
            }

            capabilitiesReceived();
        } else if (service === "network") {
            networkStateUpdate(data);
        } else if (service === "network.credentials") {
            credentialsRequest(data);
        } else if (service === "loginctl") {
            loginctlStateUpdate(data);
        } else if (service === "bluetooth.pairing") {
            bluetoothPairingRequest(data);
        } else if (service === "cups") {
            cupsStateUpdate(data);
        } else if (service === "brightness") {
            brightnessStateUpdate(data);
        } else if (service === "brightness.update") {
            if (data.device) {
                brightnessDeviceUpdate(data.device);
            }
        } else if (service === "wlroutput") {
            wlrOutputStateUpdate(data);
        } else if (service === "evdev") {
            if (data.capsLock !== undefined) {
                capsLockState = data.capsLock;
            }
            evdevStateUpdate(data);
        } else if (service === "gamma") {
            gammaStateUpdate(data);
        } else if (service === "theme.auto") {
            themeAutoStateUpdate(data);
        } else if (service === "wallpaper") {
            wallpaperCycleUpdate(data);
        } else if (service === "browser.open_requested") {
            if (data.target) {
                if (data.requestType === "url" || !data.requestType) {
                    openUrlRequested(data.target);
                } else {
                    appPickerRequested(data);
                }
            } else if (data.url) {
                openUrlRequested(data.url);
            }
        } else if (service === "freedesktop.screensaver") {
            screensaverInhibited = data.inhibited || false;
            screensaverInhibitors = data.inhibitors || [];
            screensaverStateUpdate(data);
        } else if (service === "freedesktop") {
            freedesktopStateUpdate(data);
        } else if (service === "dbus") {
            dbusSignalReceived(data.subscriptionId || "", data);
        } else if (service === "clipboard") {
            clipboardStateUpdate(data);
        } else if (service === "location") {
            locationStateUpdate(data);
        } else if (service === "sysupdate") {
            sysupdateStateUpdate(data);
        } else if (service === "files") {
            filesStateUpdate(data);
        } else if (service === "tailscale") {
            tailscaleStateUpdate(data);
        }
    }

    function sendRequest(method, params, callback) {
        if (!isConnected) {
            log.warn("DMSService.sendRequest: Not connected, method:", method);
            if (callback) {
                callback({
                    "error": "not connected to DMS socket"
                });
            }
            return;
        }

        requestIdCounter++;
        const id = Date.now() + requestIdCounter;
        const request = {
            "id": id,
            "method": method
        };

        if (params) {
            request.params = params;
        }

        if (callback)
            pendingRequests[id] = callback;

        if (method.startsWith("clipboard")) {
            clipboardRequestIds[id] = true;
        } else {
            log.debug("DMSService.sendRequest: Sending request id=" + id + " method=" + method);
        }
        requestSocket.send(request);
    }

    function handleResponse(response) {
        const callback = pendingRequests[response.id];

        if (callback) {
            delete pendingRequests[response.id];
            callback(response);
        }
    }

    function ping(callback) {
        sendRequest("ping", null, callback);
    }

    function listThemes(callback) {
        sendRequest("themes.list", null, response => {
            if (response.result) {
                availableThemes = response.result;
                themesListReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function listInstalledThemes(callback) {
        sendRequest("themes.listInstalled", null, response => {
            if (response.result) {
                installedThemes = response.result;
                installedThemesReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function searchThemes(query, callback) {
        sendRequest("themes.search", {
            "query": query
        }, response => {
            if (response.result) {
                themeSearchResultsReceived(response.result);
            }
            if (callback) {
                callback(response);
            }
        });
    }

    function installTheme(themeName, callback) {
        sendRequest("themes.install", {
            "name": themeName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalledThemes();
            }
        });
    }

    function uninstallTheme(themeName, callback) {
        sendRequest("themes.uninstall", {
            "name": themeName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalledThemes();
            }
        });
    }

    function updateTheme(themeName, callback) {
        sendRequest("themes.update", {
            "name": themeName
        }, response => {
            if (callback) {
                callback(response);
            }
            if (!response.error) {
                listInstalledThemes();
            }
        });
    }

    function lockSession(callback) {
        sendRequest("loginctl.lock", null, callback);
    }

    function unlockSession(callback) {
        sendRequest("loginctl.unlock", null, callback);
    }

    function setLockedHint(locked, callback) {
        sendRequest("loginctl.setLockedHint", {
            "locked": locked
        }, callback);
    }

    function bluetoothPair(devicePath, callback) {
        sendRequest("bluetooth.pair", {
            "device": devicePath
        }, callback);
    }

    function bluetoothConnect(devicePath, callback) {
        sendRequest("bluetooth.connect", {
            "device": devicePath
        }, callback);
    }

    function bluetoothDisconnect(devicePath, callback) {
        sendRequest("bluetooth.disconnect", {
            "device": devicePath
        }, callback);
    }

    function bluetoothRemove(devicePath, callback) {
        sendRequest("bluetooth.remove", {
            "device": devicePath
        }, callback);
    }

    function bluetoothTrust(devicePath, callback) {
        sendRequest("bluetooth.trust", {
            "device": devicePath
        }, callback);
    }

    function bluetoothSubmitPairing(token, secrets, accept, callback) {
        sendRequest("bluetooth.pairing.submit", {
            "token": token,
            "secrets": secrets,
            "accept": accept
        }, callback);
    }

    function bluetoothCancelPairing(token, callback) {
        sendRequest("bluetooth.pairing.cancel", {
            "token": token
        }, callback);
    }

    signal dbusSignalReceived(string subscriptionId, var data)

    readonly property string dbusClientId: "dms-qml-" + Date.now() + "-" + Math.floor(Math.random() * 0xffffffff)
    property var dbusSubscriptions: ({})

    function dbusCall(bus, dest, path, iface, method, args, callback) {
        sendRequest("dbus.call", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "method": method,
            "args": args || []
        }, callback);
    }

    function dbusGetProperty(bus, dest, path, iface, property, callback) {
        sendRequest("dbus.getProperty", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "property": property
        }, callback);
    }

    function dbusSetProperty(bus, dest, path, iface, property, value, callback) {
        sendRequest("dbus.setProperty", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface,
            "property": property,
            "value": value
        }, callback);
    }

    function dbusGetAllProperties(bus, dest, path, iface, callback) {
        sendRequest("dbus.getAllProperties", {
            "bus": bus,
            "dest": dest,
            "path": path,
            "interface": iface
        }, callback);
    }

    function dbusIntrospect(bus, dest, path, callback) {
        sendRequest("dbus.introspect", {
            "bus": bus,
            "dest": dest,
            "path": path || "/"
        }, callback);
    }

    function dbusListNames(bus, callback) {
        sendRequest("dbus.listNames", {
            "bus": bus
        }, callback);
    }

    function dbusSubscribe(bus, sender, path, iface, member, callback) {
        sendRequest("dbus.subscribe", {
            "bus": bus,
            "sender": sender || "",
            "path": path || "",
            "interface": iface || "",
            "member": member || "",
            "clientId": dbusClientId
        }, response => {
            if (!response.error && response.result?.subscriptionId) {
                dbusSubscriptions[response.result.subscriptionId] = true;
            }
            if (callback)
                callback(response);
        });
    }

    function dbusUnsubscribe(subscriptionId, callback) {
        sendRequest("dbus.unsubscribe", {
            "subscriptionId": subscriptionId
        }, response => {
            if (!response.error) {
                delete dbusSubscriptions[subscriptionId];
            }
            if (callback)
                callback(response);
        });
    }

    function sysupdateGetState(callback) {
        sendRequest("sysupdate.getState", null, callback);
    }

    function softwareSearch(query, source, callback) {
        sendRequest("software.search", {
            "query": query || "",
            "source": source === "all" ? "" : (source || "")
        }, callback);
    }

    function softwareInstalled(callback) {
        sendRequest("software.installed", null, callback);
    }

    function softwareState(callback) {
        sendRequest("software.state", null, callback);
    }

    function softwareInstall(item, callback) {
        sendRequest("software.install", item, callback);
    }

    function softwareRemove(item, callback) {
        sendRequest("software.remove", item, callback);
    }

    function softwareInstallLocal(path, callback) {
        sendRequest("software.installLocal", {"path": path}, callback);
    }

    function softwareCancel(callback) {
        sendRequest("software.cancel", null, callback);
    }

    function windowsApps(callback) {
        sendRequest("windows.apps", null, callback);
    }

    function windowsRuntimes(callback) {
        sendRequest("windows.runtimes", null, callback);
    }

    function windowsReleases(callback) {
        sendRequest("windows.releases", null, callback);
    }

    function windowsState(callback) {
        sendRequest("windows.state", null, callback);
    }

    function windowsInstallRuntime(release, callback) {
        sendRequest("windows.installRuntime", release, callback);
    }

    function windowsOpen(path, runtimeTag, callback) {
        sendRequest("windows.open", {"path": path, "runtimeTag": runtimeTag || ""}, callback);
    }

    function windowsLaunch(id, callback) {
        sendRequest("windows.launch", {"id": id}, callback);
    }

    function windowsRemove(id, removePrefix, callback) {
        sendRequest("windows.remove", {"id": id, "removePrefix": removePrefix === true}, callback);
    }

    function windowsSetRuntime(id, runtimeTag, callback) {
        sendRequest("windows.setRuntime", {"id": id, "runtimeTag": runtimeTag}, callback);
    }

    function windowsRemoveRuntime(runtimeTag, callback) {
        sendRequest("windows.removeRuntime", {"runtimeTag": runtimeTag}, callback);
    }

    function windowsCancel(callback) {
        sendRequest("windows.cancel", null, callback);
    }

    function filesList(path, showHidden, callback) {
        sendRequest("files.list", {"path": path, "showHidden": showHidden === true}, callback);
    }

    function filesShow(path, callback) {
        sendRequest("files.show", {"path": path || ""}, callback);
    }

    function filesMkdir(parent, name, callback) {
        sendRequest("files.mkdir", {"parent": parent, "name": name}, callback);
    }

    function filesRename(path, name, callback) {
        sendRequest("files.rename", {"path": path, "name": name}, callback);
    }

    function filesTrash(path, callback) {
        sendRequest("files.trash", {"path": path}, callback);
    }

    function filesOpen(path, callback) {
        sendRequest("files.open", {"path": path}, callback);
    }

    function filesExtract(path, callback) {
        sendRequest("files.extract", {"path": path}, callback);
    }

    function filesArchive(path, format, callback) {
        sendRequest("files.archive", {"path": path, "format": format}, callback);
    }

    function sysupdateRefresh(force, callback) {
        sendRequest("sysupdate.refresh", {
            "force": force === true
        }, callback);
    }

    function sysupdateUpgrade(opts, callback) {
        const params = opts || {};
        sendRequest("sysupdate.upgrade", params, callback);
    }

    function sysupdateCancel(callback) {
        sendRequest("sysupdate.cancel", null, callback);
    }

    function sysupdateSetInterval(seconds, callback) {
        sendRequest("sysupdate.setInterval", {
            "seconds": seconds
        }, callback);
    }

    function sysupdateAcquire(callback) {
        sendRequest("sysupdate.acquire", null, callback);
    }

    function sysupdateRelease(callback) {
        sendRequest("sysupdate.release", null, callback);
    }
}
