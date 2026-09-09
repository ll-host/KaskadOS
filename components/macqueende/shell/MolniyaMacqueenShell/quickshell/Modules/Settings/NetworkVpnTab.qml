pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.Common
import qs.Modals.Common
import qs.Modules.Settings.Widgets
import qs.Services
import qs.Widgets

Item {
    id: networkVpnTab

    property string section: "overview"

    property string pendingRouteOutbound: "proxy"
    property string serverSearchQuery: ""
    property string pendingAppOutbound: "direct"
    property string appSearchQuery: ""
    property bool appPickerExpanded: false
    property var detectionApplication: null
    property string processSearchQuery: ""
    property bool showAllProcesses: false

    readonly property var selectedRoute: {
        const routes = RegaliaService.routes || [];
        for (const route of routes) {
            if (route.id === RegaliaService.activeRouteId)
                return route;
        }
        return null;
    }

    readonly property var matchingApplications: {
        if (!appPickerExpanded)
            return [];
        const query = appSearchQuery.trim().toLowerCase();
        const configured = selectedRoute?.apps || [];
        const matches = [];
        for (const app of (RegaliaService.applications || [])) {
            if (configured.some(rule => rule.desktopId === app.desktopId))
                continue;
            const haystack = ((app.name || "") + " " + (app.desktopId || "") + " " + (app.launcherPath || "")).toLowerCase();
            if (query.length > 0 && !haystack.includes(query))
                continue;
            matches.push(app);
            if (matches.length >= 8)
                break;
        }
        return matches;
    }

    readonly property var matchingProcesses: {
        if (!detectionApplication)
            return [];
        const query = processSearchQuery.trim().toLowerCase();
        const launcherBase = baseName(detectionApplication.launcherPath || "").toLowerCase();
        const desktopBase = String(detectionApplication.desktopId || "").replace(/\.desktop$/i, "").toLowerCase();
        const appName = String(detectionApplication.name || "").toLowerCase();
        const matches = [];
        for (const process of (RegaliaService.processes || [])) {
            const processBase = baseName(process.processPath || "").toLowerCase();
            const haystack = ((process.name || "") + " " + (process.processPath || "")).toLowerCase();
            const likely = (launcherBase.length > 1 && processBase === launcherBase)
                || (desktopBase.length > 2 && haystack.includes(desktopBase))
                || (appName.length > 2 && haystack.includes(appName));
            if (query.length > 0) {
                if (!haystack.includes(query))
                    continue;
            } else if (!showAllProcesses && !likely) {
                continue;
            }
            matches.push(process);
            if (matches.length >= 20)
                break;
        }
        return matches;
    }

    function baseName(path) {
        const value = String(path || "");
        const separator = value.lastIndexOf("/");
        return separator >= 0 ? value.substring(separator + 1) : value;
    }

    function selectApplicationForDetection(application) {
        detectionApplication = application;
        processSearchQuery = "";
        showAllProcesses = false;
        RegaliaService.refreshProcesses();
    }

    function saveDetectedProcess(process) {
        if (!detectionApplication || process?.appImage || !process?.processPath)
            return;
        RegaliaService.setRouteApplication(selectedRoute.id, {
            "desktopId": detectionApplication.desktopId || "",
            "name": detectionApplication.name || "",
            "icon": detectionApplication.icon || "",
            "processPath": process.processPath
        }, pendingAppOutbound);
        detectionApplication = null;
        processSearchQuery = "";
        showAllProcesses = false;
        appPickerExpanded = false;
    }

    readonly property var availableServers: {
        const result = [];
        const groups = RegaliaService.serverGroups || [];
        for (const group of groups) {
            for (const server of (group.items || [])) {
                result.push({
                    "id": server.id,
                    "name": server.name,
                    "protocol": server.protocol,
                    "address": server.address,
                    "port": server.port,
                    "ready": server.ready,
                    "profileName": group.profileName
                });
            }
        }
        return result;
    }

    readonly property var filteredServers: {
        const tokens = serverSearchQuery.trim().toLowerCase().split(/\s+/).filter(token => token.length > 0);
        if (tokens.length === 0)
            return availableServers;

        return availableServers.filter(server => {
            const haystack = [
                server.name || "",
                server.profileName || "",
                server.protocol || "",
                server.address || "",
                server.port !== undefined ? String(server.port) : ""
            ].join(" ").toLowerCase();
            return tokens.every(token => haystack.includes(token));
        });
    }

    function configurationMessage() {
        if (RegaliaService.configurationReady)
            return I18n.tr("VPN is ready to connect.");
        if (RegaliaService.configurationError === "no server is selected")
            return I18n.tr("Select a server to enable VPN.");
        return RegaliaService.configurationError || I18n.tr("Complete the Regalia configuration before enabling VPN.");
    }

    function subscriptionErrorMessage(message) {
        const raw = String(message || "");
        if (raw.includes("HTTP 502"))
            return I18n.tr("Subscription service is temporarily unavailable (HTTP 502). Try again later.");
        return raw;
    }

    function engineFailureMessage() {
        const raw = String(RegaliaService.engineError || "");
        if (raw.includes("add route") && raw.includes("file exists"))
            return I18n.tr("Another TUN VPN is active. Disconnect Throne or another VPN and try again.");
        return raw || I18n.tr("VPN engine failed to start.");
    }

    function engineStateLabel() {
        switch (RegaliaService.engineState) {
        case "connected": return I18n.tr("Connected");
        case "starting": return I18n.tr("Starting");
        case "stopping": return I18n.tr("Stopping");
        case "failed": return I18n.tr("Failed");
        case "unavailable": return I18n.tr("Unavailable");
        default: return I18n.tr("Stopped");
        }
    }

    LayoutMirroring.enabled: I18n.isRtl
    LayoutMirroring.childrenInherit: true

    Component.onCompleted: RegaliaService.detect()

    onSectionChanged: Qt.callLater(() => vpnFlickable.contentY = 0)

    onSelectedRouteChanged: {
        pendingAppOutbound = selectedRoute?.defaultOutbound === "direct" ? "proxy" : "direct";
        appSearchQuery = "";
        appPickerExpanded = false;
        detectionApplication = null;
        processSearchQuery = "";
        showAllProcesses = false;
    }

    ConfirmModal {
        id: deleteConfirm
    }

    DankFlickable {
        id: vpnFlickable
        anchors.fill: parent
        clip: true
        contentHeight: mainColumn.height + Theme.spacingXL
        contentWidth: width

        Column {
            id: mainColumn

            topPadding: 4
            width: Math.min(600, parent.width - Theme.spacingL * 2)
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Theme.spacingL

            SettingsCard {
                title: I18n.tr("VPN")
                iconName: "vpn_key"
                settingKey: "networkVpn"
                tags: ["vpn", "regalia", "proxy", "tun", "routing"]
                width: parent.width
                visible: networkVpnTab.section === "overview" || RegaliaService.availabilityState !== "ready"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    Rectangle {
                        width: parent.width
                        height: unavailableContent.height + Theme.spacingL * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainer
                        border.width: 1
                        border.color: Theme.outline
                        visible: RegaliaService.availabilityState !== "ready"

                        Column {
                            id: unavailableContent
                            width: parent.width - Theme.spacingL * 2
                            anchors.centerIn: parent
                            spacing: Theme.spacingM

                            Rectangle {
                                width: 56
                                height: 56
                                radius: 28
                                anchors.horizontalCenter: parent.horizontalCenter
                                color: Theme.withAlpha(Theme.primary, 0.14)

                                DankIcon {
                                    anchors.centerIn: parent
                                    name: RegaliaService.availabilityState === "checking" ? "sync" : "vpn_key_off"
                                    size: 28
                                    color: Theme.primary
                                }
                            }

                            StyledText {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: Theme.fontSizeLarge
                                font.weight: Font.DemiBold
                                color: Theme.surfaceText
                                text: {
                                    switch (RegaliaService.availabilityState) {
                                    case "checking":
                                        return I18n.tr("Checking Regalia");
                                    case "not-installed":
                                        return I18n.tr("Regalia is not installed");
                                    case "service-offline":
                                        return I18n.tr("Regalia service is not running");
                                    case "incompatible":
                                        return I18n.tr("Regalia needs to be updated");
                                    default:
                                        return I18n.tr("Regalia is unavailable");
                                    }
                                }
                            }

                            StyledText {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                                text: {
                                    switch (RegaliaService.availabilityState) {
                                    case "checking":
                                        return I18n.tr("Checking Regalia");
                                    case "not-installed":
                                        return I18n.tr("The integrated VPN component is missing. Reinstall or update KaskadOS.");
                                    case "service-offline":
                                        return I18n.tr("The component is installed, but its user service is offline. Your desktop works normally without it.");
                                    case "incompatible":
                                        return I18n.tr("This shell requires Regalia API version %1 or newer.").arg(RegaliaService.minimumApiVersion);
                                    default:
                                        return RegaliaService.lastError || I18n.tr("The VPN component could not be reached");
                                    }
                                }
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: Theme.spacingS
                                visible: !RegaliaService.checkingInstallation

                                DankButton {
                                    text: I18n.tr("Start service")
                                    iconName: "play_arrow"
                                    buttonHeight: 36
                                    visible: RegaliaService.availabilityState === "service-offline"
                                    enabled: !RegaliaService.busy
                                    onClicked: RegaliaService.startDaemon()
                                }

                                DankButton {
                                    text: I18n.tr("Check again")
                                    iconName: "refresh"
                                    buttonHeight: 36
                                    backgroundColor: Theme.surfaceContainerHigh
                                    textColor: Theme.surfaceText
                                    enabled: !RegaliaService.busy
                                    onClicked: RegaliaService.detect()
                                }
                            }

                            StyledText {
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.Wrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                                text: RegaliaService.lastError
                                visible: text.length > 0
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingM
                        visible: RegaliaService.availabilityState === "ready"

                        SettingsToggleRow {
                            settingKey: "regaliaVpnEnabled"
                            text: I18n.tr("Enable VPN")
                            description: {
                                if (RegaliaService.busy)
                                    return I18n.tr("Applying VPN state");
                                if (RegaliaService.connected)
                                    return I18n.tr("Connected through Regalia TUN");
                                if (RegaliaService.engineState === "failed")
                                    return networkVpnTab.engineFailureMessage();
                                if (RegaliaService.enabled)
                                    return I18n.tr("Enabled, waiting for the engine");
                                return I18n.tr("Keep this setting after logout and reboot");
                            }
                            checked: RegaliaService.enabled
                            enabled: !RegaliaService.busy && RegaliaService.engineAvailable && (RegaliaService.configurationReady || RegaliaService.enabled)
                            onToggled: checked => RegaliaService.setEnabled(checked)
                        }

                        Rectangle {
                            width: parent.width
                            height: 1
                            color: Theme.outline
                            opacity: 0.2
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingM

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: RegaliaService.connected ? Theme.success : (RegaliaService.enabled ? Theme.warning : Theme.surfaceVariantText)
                            }

                            Column {
                                width: parent.width - statusBadge.width - Theme.spacingM * 2 - 10
                                spacing: Theme.spacingXXS

                                StyledText {
                                    width: parent.width
                                    text: {
                                        if (RegaliaService.connected)
                                            return I18n.tr("Connected");
                                        if (RegaliaService.engineState === "starting")
                                            return I18n.tr("Connecting");
                                        if (RegaliaService.engineState === "failed")
                                            return I18n.tr("Connection failed");
                                        return I18n.tr("Disconnected");
                                    }
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Medium
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    width: parent.width
                                    text: RegaliaService.engineState === "failed" ? networkVpnTab.engineFailureMessage() : (RegaliaService.activeServer ? (RegaliaService.activeServer.name || I18n.tr("Selected server")) : I18n.tr("No server selected"))
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            Rectangle {
                                id: statusBadge
                                anchors.verticalCenter: parent.verticalCenter
                                width: engineText.implicitWidth + Theme.spacingM * 2
                                height: 28
                                radius: 14
                                color: Theme.surfaceContainer

                                StyledText {
                                    id: engineText
                                    anchors.centerIn: parent
                                    text: networkVpnTab.engineStateLabel()
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                }
                            }
                        }

                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Subscriptions")
                iconName: "link"
                settingKey: "regaliaSubscriptions"
                tags: ["regalia", "subscription", "profile", "url"]
                width: parent.width
                visible: networkVpnTab.section === "subscriptions" && RegaliaService.availabilityState === "ready"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Add a VPN subscription link. Regalia stores it privately and downloads the server list.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Disconnect VPN before changing subscriptions or servers.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                        visible: RegaliaService.enabled
                    }

                    Repeater {
                        model: RegaliaService.profiles

                        delegate: Rectangle {
                            required property var modelData

                            width: parent.width
                            height: 68
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer
                            border.width: 1
                            border.color: Theme.outline

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                Column {
                                    width: parent.width - profileActions.width - Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        width: parent.width
                                        text: modelData.name
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: modelData.lastError ? networkVpnTab.subscriptionErrorMessage(modelData.lastError) : I18n.tr("%1 servers").arg(modelData.serverCount || 0)
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: modelData.lastError ? Theme.error : Theme.surfaceVariantText
                                    }
                                }

                                Row {
                                    id: profileActions
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS

                                    DankButton {
                                        text: I18n.tr("Update")
                                        iconName: "refresh"
                                        buttonHeight: 32
                                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                                        onClicked: RegaliaService.refreshProfile(modelData.id)
                                    }

                                    DankButton {
                                        text: I18n.tr("Delete")
                                        iconName: "delete"
                                        buttonHeight: 32
                                        backgroundColor: Theme.surfaceContainerHigh
                                        textColor: Theme.error
                                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                                        onClicked: deleteConfirm.showWithOptions({
                                            "title": I18n.tr("Delete subscription"),
                                            "message": I18n.tr("Delete \"%1\" and all of its servers?").arg(modelData.name),
                                            "confirmText": I18n.tr("Delete"),
                                            "confirmColor": Theme.error,
                                            "onConfirm": () => RegaliaService.deleteProfile(modelData.id)
                                        })
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.outline
                        opacity: 0.2
                        visible: RegaliaService.profiles.length > 0
                    }

                    DankTextField {
                        id: subscriptionName
                        width: parent.width
                        placeholderText: I18n.tr("Subscription name")
                        backgroundColor: Theme.surfaceContainerHighest
                        normalBorderColor: Theme.outlineMedium
                        focusedBorderColor: Theme.primary
                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                    }

                    DankTextField {
                        id: subscriptionUrl
                        width: parent.width
                        placeholderText: I18n.tr("Paste subscription URL")
                        echoMode: TextInput.Password
                        showPasswordToggle: true
                        backgroundColor: Theme.surfaceContainerHighest
                        normalBorderColor: Theme.outlineMedium
                        focusedBorderColor: Theme.primary
                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                        onAccepted: addSubscriptionButton.clicked()
                    }

                    DankButton {
                        id: addSubscriptionButton
                        text: RegaliaService.busy ? I18n.tr("Please wait") : I18n.tr("Add and download")
                        iconName: "add_link"
                        buttonHeight: 38
                        enabled: !RegaliaService.busy && !RegaliaService.enabled && subscriptionName.text.trim().length > 0 && subscriptionUrl.text.trim().length > 0
                        onClicked: {
                            const name = subscriptionName.text;
                            const url = subscriptionUrl.text;
                            subscriptionName.text = "";
                            subscriptionUrl.text = "";
                            RegaliaService.createProfile(name, url);
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Servers")
                iconName: "dns"
                settingKey: "regaliaServers"
                tags: ["regalia", "servers", "protocol"]
                width: parent.width
                visible: networkVpnTab.section === "servers" && RegaliaService.availabilityState === "ready"

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    DankTextField {
                        id: serverSearchField
                        width: parent.width
                        visible: networkVpnTab.availableServers.length > 0
                        placeholderText: I18n.tr("Search servers by name, country, protocol, address or subscription")
                        leftIconName: "search"
                        showClearButton: true
                        backgroundColor: Theme.surfaceContainerHighest
                        normalBorderColor: Theme.outlineMedium
                        focusedBorderColor: Theme.primary
                        onTextChanged: networkVpnTab.serverSearchQuery = text
                    }

                    Row {
                        width: parent.width
                        visible: networkVpnTab.availableServers.length > 0

                        StyledText {
                            width: parent.width
                            text: networkVpnTab.serverSearchQuery.trim().length > 0
                                ? I18n.tr("%1 of %2 servers").arg(networkVpnTab.filteredServers.length).arg(networkVpnTab.availableServers.length)
                                : I18n.tr("%1 servers").arg(networkVpnTab.availableServers.length)
                            font.pixelSize: Theme.fontSizeSmall
                            color: networkVpnTab.filteredServers.length > 0 ? Theme.surfaceVariantText : Theme.warning
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("No servers yet. Update the subscription to download them.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        visible: networkVpnTab.availableServers.length === 0
                    }

                    Rectangle {
                        width: parent.width
                        height: 108
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainer
                        border.width: 1
                        border.color: Theme.outline
                        visible: networkVpnTab.availableServers.length > 0 && networkVpnTab.filteredServers.length === 0

                        Column {
                            anchors.centerIn: parent
                            spacing: Theme.spacingS

                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: I18n.tr("No servers match your search.")
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }

                            DankButton {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: I18n.tr("Clear search")
                                iconName: "close"
                                buttonHeight: 32
                                onClicked: serverSearchField.text = ""
                            }
                        }
                    }

                    Repeater {
                        model: networkVpnTab.filteredServers

                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool selected: modelData.id === RegaliaService.activeServerId

                            width: parent.width
                            height: 66
                            radius: Theme.cornerRadius
                            color: selected ? Theme.withAlpha(Theme.primary, 0.12) : Theme.surfaceContainer
                            border.width: 1
                            border.color: selected ? Theme.primary : Theme.outline

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingM

                                Column {
                                    width: parent.width - selectServerButton.width - Theme.spacingM
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        width: parent.width
                                        text: modelData.name
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: modelData.profileName + " • " + String(modelData.protocol || "").toUpperCase() + (modelData.address ? " • " + modelData.address + (modelData.port ? ":" + modelData.port : "") : "")
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: modelData.ready ? Theme.surfaceVariantText : Theme.warning
                                    }
                                }

                                DankButton {
                                    id: selectServerButton
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: selected ? I18n.tr("Selected") : (modelData.ready ? I18n.tr("Select") : I18n.tr("Unavailable"))
                                    iconName: selected ? "check" : "arrow_forward"
                                    buttonHeight: 34
                                    enabled: !selected && modelData.ready && !RegaliaService.busy && !RegaliaService.enabled
                                    onClicked: RegaliaService.selectServer(modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Routing profiles")
                iconName: "route"
                settingKey: "regaliaRoutes"
                tags: ["regalia", "routing", "proxy", "direct"]
                width: parent.width
                visible: networkVpnTab.section === "routing" && RegaliaService.availabilityState === "ready"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Without a routing profile, all traffic goes through VPN. Create one to prepare per-application rules.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        visible: RegaliaService.routes.length === 0
                    }

                    Repeater {
                        model: RegaliaService.routes

                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool selected: modelData.id === RegaliaService.activeRouteId

                            width: parent.width
                            height: 60
                            radius: Theme.cornerRadius
                            color: selected ? Theme.withAlpha(Theme.primary, 0.12) : Theme.surfaceContainer
                            border.width: 1
                            border.color: selected ? Theme.primary : Theme.outline

                            Row {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                Column {
                                    width: parent.width - routeActions.width - Theme.spacingS
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXXS

                                    StyledText {
                                        width: parent.width
                                        text: modelData.name
                                        elide: Text.ElideRight
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: modelData.defaultOutbound === "direct" ? I18n.tr("Direct by default") : I18n.tr("VPN by default")
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }
                                }

                                Row {
                                    id: routeActions
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: Theme.spacingXS

                                    DankButton {
                                        text: selected ? I18n.tr("Selected") : I18n.tr("Use")
                                        iconName: selected ? "check" : "play_arrow"
                                        buttonHeight: 32
                                        enabled: !selected && !RegaliaService.busy && !RegaliaService.enabled
                                        onClicked: RegaliaService.activateRoute(modelData.id)
                                    }

                                    DankButton {
                                        text: I18n.tr("Delete")
                                        iconName: "delete"
                                        buttonHeight: 32
                                        backgroundColor: Theme.surfaceContainerHigh
                                        textColor: Theme.error
                                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                                        onClicked: deleteConfirm.showWithOptions({
                                            "title": I18n.tr("Delete routing profile"),
                                            "message": I18n.tr("Delete \"%1\"?").arg(modelData.name),
                                            "confirmText": I18n.tr("Delete"),
                                            "confirmColor": Theme.error,
                                            "onConfirm": () => RegaliaService.deleteRoute(modelData.id)
                                        })
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.outline
                        opacity: 0.2
                        visible: RegaliaService.routes.length > 0
                    }

                    DankTextField {
                        id: routeName
                        width: parent.width
                        placeholderText: I18n.tr("Routing profile name")
                        backgroundColor: Theme.surfaceContainerHighest
                        normalBorderColor: Theme.outlineMedium
                        focusedBorderColor: Theme.primary
                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                    }

                    DankDropdown {
                        width: parent.width
                        compactMode: true
                        options: [I18n.tr("All traffic through VPN"), I18n.tr("Bypass VPN by default")]
                        currentValue: networkVpnTab.pendingRouteOutbound === "direct" ? I18n.tr("Bypass VPN by default") : I18n.tr("All traffic through VPN")
                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                        onValueChanged: value => networkVpnTab.pendingRouteOutbound = value === I18n.tr("Bypass VPN by default") ? "direct" : "proxy"
                    }

                    DankButton {
                        text: I18n.tr("Create routing profile")
                        iconName: "add"
                        buttonHeight: 38
                        enabled: !RegaliaService.busy && !RegaliaService.enabled && routeName.text.trim().length > 0
                        onClicked: {
                            const name = routeName.text;
                            routeName.text = "";
                            RegaliaService.createRoute(name, networkVpnTab.pendingRouteOutbound);
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Application routing")
                iconName: "apps"
                settingKey: "regaliaApplicationRoutes"
                tags: ["regalia", "routing", "applications", "processPath"]
                width: parent.width
                visible: networkVpnTab.section === "routing" && RegaliaService.availabilityState === "ready" && networkVpnTab.selectedRoute !== null

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    StyledText {
                        width: parent.width
                        text: I18n.tr("Choose an application, then confirm its exact running process. Regalia reads processPath directly from /proc, just like a process path viewer.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Rectangle {
                        width: parent.width
                        height: appImageWarning.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.warning, 0.1)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.warning, 0.35)

                        StyledText {
                            id: appImageWarning
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Theme.spacingM
                            text: I18n.tr("AppImage is not supported because its executable path changes on every launch.")
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.warning
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: editWarningText.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(Theme.warning, 0.12)
                        border.width: 1
                        border.color: Theme.withAlpha(Theme.warning, 0.45)
                        visible: RegaliaService.enabled

                        StyledText {
                            id: editWarningText
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Theme.spacingM
                            text: I18n.tr("Turn off VPN before changing routing rules. Your connection can be enabled again immediately after saving.")
                            wrapMode: Text.WordWrap
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.warning
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: (networkVpnTab.selectedRoute?.apps || []).length > 0

                        StyledText {
                            width: parent.width
                            text: I18n.tr("Configured applications")
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.DemiBold
                            color: Theme.surfaceText
                        }

                        Repeater {
                            model: networkVpnTab.selectedRoute?.apps || []

                            delegate: Rectangle {
                                required property var modelData

                                width: parent.width
                                height: 64
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                border.width: 1
                                border.color: Theme.outline

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingM

                                    Item {
                                        width: 36
                                        height: 36
                                        anchors.verticalCenter: parent.verticalCenter

                                        IconImage {
                                            id: configuredAppIcon
                                            anchors.fill: parent
                                            source: Paths.resolveIconUrl(modelData.icon || "application-x-executable")
                                            asynchronous: true
                                            smooth: true
                                            mipmap: true
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "apps"
                                            size: 24
                                            color: Theme.surfaceVariantText
                                            visible: configuredAppIcon.status !== Image.Ready
                                        }
                                    }

                                    Column {
                                        width: parent.width - configuredRuleActions.width - 36 - Theme.spacingM * 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXXS

                                        StyledText {
                                            width: parent.width
                                            text: modelData.name || modelData.desktopId || I18n.tr("Application")
                                            elide: Text.ElideRight
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: modelData.processPath || ""
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    Row {
                                        id: configuredRuleActions
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXS

                                        DankButton {
                                            text: modelData.outbound === "direct" ? I18n.tr("Without VPN") : I18n.tr("Through VPN")
                                            iconName: modelData.outbound === "direct" ? "vpn_key_off" : "vpn_key"
                                            buttonHeight: 34
                                            enabled: !RegaliaService.busy && !RegaliaService.enabled
                                            onClicked: RegaliaService.setRouteApplication(networkVpnTab.selectedRoute.id, modelData, modelData.outbound === "direct" ? "proxy" : "direct")
                                        }

                                        DankActionButton {
                                            buttonSize: 34
                                            iconName: "delete"
                                            iconColor: Theme.error
                                            enabled: !RegaliaService.busy && !RegaliaService.enabled
                                            onClicked: RegaliaService.removeRouteApplication(networkVpnTab.selectedRoute.id, modelData.processPath)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: I18n.tr("No application rules. The profile default is used for every application.")
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        visible: (networkVpnTab.selectedRoute?.apps || []).length === 0
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.outline
                        opacity: 0.2
                    }

                    DankButton {
                        text: networkVpnTab.appPickerExpanded ? I18n.tr("Hide application picker") : I18n.tr("Add application")
                        iconName: networkVpnTab.appPickerExpanded ? "expand_less" : "add"
                        buttonHeight: 38
                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                        onClicked: {
                            networkVpnTab.appPickerExpanded = !networkVpnTab.appPickerExpanded;
                            if (!networkVpnTab.appPickerExpanded) {
                                networkVpnTab.appSearchQuery = "";
                                networkVpnTab.detectionApplication = null;
                                networkVpnTab.processSearchQuery = "";
                                networkVpnTab.showAllProcesses = false;
                            }
                        }
                    }

                    Column {
                        width: parent.width
                        spacing: Theme.spacingS
                        visible: networkVpnTab.appPickerExpanded

                        DankTextField {
                            id: routeAppSearch
                            width: parent.width
                            placeholderText: I18n.tr("Search installed applications")
                            leftIconName: "search"
                            showClearButton: true
                            backgroundColor: Theme.surfaceContainerHighest
                            normalBorderColor: Theme.outlineMedium
                            focusedBorderColor: Theme.primary
                            enabled: !RegaliaService.busy && !RegaliaService.enabled
                            onTextChanged: networkVpnTab.appSearchQuery = text
                        }

                        DankDropdown {
                            width: parent.width
                            compactMode: true
                            options: [I18n.tr("Send selected application without VPN"), I18n.tr("Send selected application through VPN")]
                            currentValue: networkVpnTab.pendingAppOutbound === "direct" ? I18n.tr("Send selected application without VPN") : I18n.tr("Send selected application through VPN")
                            enabled: !RegaliaService.busy && !RegaliaService.enabled
                            onValueChanged: value => networkVpnTab.pendingAppOutbound = value === I18n.tr("Send selected application without VPN") ? "direct" : "proxy"
                        }

                        Repeater {
                            model: networkVpnTab.matchingApplications

                            delegate: Rectangle {
                                required property var modelData

                                width: parent.width
                                height: 58
                                radius: Theme.cornerRadius
                                color: addAppHover.hovered ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                                border.width: 1
                                border.color: addAppHover.hovered ? Theme.primary : Theme.outline

                                Row {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    spacing: Theme.spacingM

                                    Item {
                                        width: 34
                                        height: 34
                                        anchors.verticalCenter: parent.verticalCenter

                                        IconImage {
                                            id: availableAppIcon
                                            anchors.fill: parent
                                            source: Paths.resolveIconUrl(modelData.icon || "application-x-executable")
                                            asynchronous: true
                                            smooth: true
                                            mipmap: true
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "apps"
                                            size: 22
                                            color: Theme.surfaceVariantText
                                            visible: availableAppIcon.status !== Image.Ready
                                        }
                                    }

                                    Column {
                                        width: parent.width - addRuleButton.width - 34 - Theme.spacingM * 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingXXS

                                        StyledText {
                                            width: parent.width
                                            text: modelData.name || I18n.tr("Application")
                                            elide: Text.ElideRight
                                            font.pixelSize: Theme.fontSizeMedium
                                            color: Theme.surfaceText
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: modelData.launcherPath || ""
                                            elide: Text.ElideMiddle
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }
                                    }

                                    DankButton {
                                        id: addRuleButton
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: I18n.tr("Find process")
                                        iconName: "manage_search"
                                        buttonHeight: 32
                                        enabled: !RegaliaService.busy && !RegaliaService.enabled
                                        onClicked: networkVpnTab.selectApplicationForDetection(modelData)
                                    }
                                }

                                HoverHandler {
                                    id: addAppHover
                                }
                            }
                        }

                        StyledText {
                            width: parent.width
                            text: I18n.tr("No matching applications")
                            horizontalAlignment: Text.AlignHCenter
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            visible: networkVpnTab.matchingApplications.length === 0
                        }

                        Rectangle {
                            width: parent.width
                            height: processDetectionContent.implicitHeight + Theme.spacingM * 2
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer
                            border.width: 1
                            border.color: Theme.primary
                            visible: networkVpnTab.detectionApplication !== null

                            Column {
                                id: processDetectionContent
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Theme.spacingM
                                spacing: Theme.spacingS

                                Row {
                                    width: parent.width
                                    spacing: Theme.spacingM

                                    Item {
                                        width: 36
                                        height: 36

                                        IconImage {
                                            id: detectedApplicationIcon
                                            anchors.fill: parent
                                            source: Paths.resolveIconUrl(networkVpnTab.detectionApplication?.icon || "application-x-executable")
                                            asynchronous: true
                                            smooth: true
                                            mipmap: true
                                        }

                                        DankIcon {
                                            anchors.centerIn: parent
                                            name: "apps"
                                            size: 24
                                            color: Theme.surfaceVariantText
                                            visible: detectedApplicationIcon.status !== Image.Ready
                                        }
                                    }

                                    Column {
                                        width: parent.width - scanProcessesButton.width - 36 - Theme.spacingM * 2
                                        spacing: Theme.spacingXXS

                                        StyledText {
                                            width: parent.width
                                            text: networkVpnTab.detectionApplication?.name || I18n.tr("Application")
                                            font.pixelSize: Theme.fontSizeMedium
                                            font.weight: Font.DemiBold
                                            color: Theme.surfaceText
                                            elide: Text.ElideRight
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: I18n.tr("Select the executable path shown by the running process.")
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            wrapMode: Text.WordWrap
                                        }
                                    }

                                    DankButton {
                                        id: scanProcessesButton
                                        text: RegaliaService.processesLoading ? I18n.tr("Scanning") : I18n.tr("Scan again")
                                        iconName: "refresh"
                                        buttonHeight: 34
                                        enabled: !RegaliaService.processesLoading
                                        onClicked: RegaliaService.refreshProcesses()
                                    }
                                }

                                DankTextField {
                                    width: parent.width
                                    placeholderText: I18n.tr("Search running processes by name or path")
                                    leftIconName: "search"
                                    showClearButton: true
                                    backgroundColor: Theme.surfaceContainerHighest
                                    normalBorderColor: Theme.outlineMedium
                                    focusedBorderColor: Theme.primary
                                    onTextChanged: networkVpnTab.processSearchQuery = text
                                }

                                Repeater {
                                    model: networkVpnTab.matchingProcesses

                                    delegate: Rectangle {
                                        required property var modelData

                                        width: parent.width
                                        height: 66
                                        radius: Theme.cornerRadius
                                        color: Theme.surfaceContainerHigh
                                        border.width: 1
                                        border.color: modelData.appImage ? Theme.warning : Theme.outline

                                        Row {
                                            anchors.fill: parent
                                            anchors.margins: Theme.spacingM
                                            spacing: Theme.spacingM

                                            DankIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: modelData.appImage ? "warning" : "memory"
                                                size: 24
                                                color: modelData.appImage ? Theme.warning : Theme.primary
                                            }

                                            Column {
                                                width: parent.width - confirmProcessButton.width - 24 - Theme.spacingM * 2
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: Theme.spacingXXS

                                                StyledText {
                                                    width: parent.width
                                                    text: (modelData.name || networkVpnTab.baseName(modelData.processPath)) + " • " + I18n.tr("%1 processes").arg(modelData.processCount || 1)
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    font.weight: Font.Medium
                                                    color: Theme.surfaceText
                                                    elide: Text.ElideRight
                                                }

                                                StyledText {
                                                    width: parent.width
                                                    text: modelData.processPath || ""
                                                    font.pixelSize: Theme.fontSizeSmall
                                                    color: modelData.appImage ? Theme.warning : Theme.surfaceVariantText
                                                    elide: Text.ElideMiddle
                                                }
                                            }

                                            DankButton {
                                                id: confirmProcessButton
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: modelData.appImage ? I18n.tr("Unsupported") : I18n.tr("Use this path")
                                                iconName: modelData.appImage ? "block" : "check"
                                                buttonHeight: 32
                                                enabled: !modelData.appImage && !RegaliaService.busy && !RegaliaService.enabled
                                                onClicked: networkVpnTab.saveDetectedProcess(modelData)
                                            }
                                        }
                                    }
                                }

                                StyledText {
                                    width: parent.width
                                    text: I18n.tr("The application is not running or no matching process was found. Start it and scan again, or search all running processes manually.")
                                    wrapMode: Text.WordWrap
                                    horizontalAlignment: Text.AlignHCenter
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    visible: !RegaliaService.processesLoading && networkVpnTab.matchingProcesses.length === 0
                                }

                                DankButton {
                                    text: networkVpnTab.showAllProcesses ? I18n.tr("Show suggested processes") : I18n.tr("Show all running processes")
                                    iconName: networkVpnTab.showAllProcesses ? "filter_alt" : "list"
                                    buttonHeight: 34
                                    enabled: !RegaliaService.processesLoading
                                    onClicked: networkVpnTab.showAllProcesses = !networkVpnTab.showAllProcesses
                                }
                            }
                        }
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Current configuration")
                iconName: "tune"
                settingKey: "regaliaConfiguration"
                tags: ["regalia", "server", "route", "profile"]
                width: parent.width
                visible: networkVpnTab.section === "overview" && RegaliaService.availabilityState === "ready"

                Column {
                    width: parent.width
                    spacing: Theme.spacingM

                    ConfigRow {
                        label: I18n.tr("Server")
                        value: RegaliaService.activeServer ? (RegaliaService.activeServer.name || "-") : I18n.tr("Not selected")
                    }

                    ConfigRow {
                        label: I18n.tr("Protocol")
                        value: RegaliaService.activeServer ? (RegaliaService.activeServer.protocol || "-") : "-"
                    }

                    ConfigRow {
                        label: I18n.tr("Routing profile")
                        value: RegaliaService.activeRoute ? (RegaliaService.activeRoute.name || "-") : I18n.tr("Default")
                    }

                    ConfigRow {
                        label: I18n.tr("Default route")
                        value: RegaliaService.activeRoute ? (RegaliaService.activeRoute.defaultOutbound || "proxy") : "proxy"
                    }

                    Rectangle {
                        width: parent.width
                        height: 1
                        color: Theme.outline
                        opacity: 0.2
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: networkVpnTab.configurationMessage()
                        font.pixelSize: Theme.fontSizeSmall
                        color: RegaliaService.configurationReady ? Theme.surfaceVariantText : Theme.warning
                    }
                }
            }

            SettingsCard {
                title: I18n.tr("Diagnostics")
                iconName: "monitor_heart"
                width: parent.width
                visible: networkVpnTab.section === "overview" && RegaliaService.availabilityState === "ready" && (RegaliaService.engineError.length > 0 || RegaliaService.restoreError.length > 0 || RegaliaService.lastError.length > 0)

                Column {
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: RegaliaService.lastError || RegaliaService.restoreError || RegaliaService.engineError
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.error
                    }

                    DankButton {
                        text: I18n.tr("Refresh status")
                        iconName: "refresh"
                        buttonHeight: 34
                        enabled: !RegaliaService.statusRequestPending
                        onClicked: RegaliaService.refreshStatus()
                    }
                }
            }
        }
    }

    component ConfigRow: Row {
        required property string label
        required property string value

        width: parent.width
        spacing: Theme.spacingM

        StyledText {
            width: parent.width * 0.42
            text: parent.label
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceVariantText
            horizontalAlignment: Text.AlignLeft
        }

        StyledText {
            width: parent.width * 0.58 - Theme.spacingM
            text: parent.value
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
            horizontalAlignment: Text.AlignRight
            elide: Text.ElideRight
        }
    }
}
