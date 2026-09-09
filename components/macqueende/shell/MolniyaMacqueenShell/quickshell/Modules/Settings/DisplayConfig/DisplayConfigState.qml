pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Macqueen.Ipc 1.0
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("DisplayConfigState")

    readonly property bool hasOutputBackend: CompositorService.isMacqueen && Macqueen.available && Macqueen.protocolVersion >= 11
    readonly property var nativeOutputs: Macqueen.outputs
    property var outputs: ({})
    property var savedOutputs: ({})
    property var allOutputs: buildAllOutputsMap()

    property var pendingChanges: ({})
    property var originalOutputs: null
    property string originalDisplayNameMode: ""
    property bool formatChanged: originalDisplayNameMode !== "" && originalDisplayNameMode !== SettingsData.displayNameMode
    property bool hasPendingChanges: Object.keys(pendingChanges).length > 0 || formatChanged

    property var currentOutputSet: []
    property string matchedProfile: ""
    property bool profilesLoading: false
    property var validatedProfiles: ({})
    property bool manualActivation: false
    property bool profilesReady: false
    property var monitorsCache: ({
            "version": 1,
            "configurations": []
        })
    property bool _monitorsSelfWrite: false
    // Last config entry that was applied (set by applyConfigEntry / confirmChanges).
    // Used to recover position, scale, and transform for disabled outputs.
    property var lastAppliedEntry: null

    signal changesApplied(var changeDescriptions)
    signal changesConfirmed
    signal changesReverted
    signal profileActivated(string profileId, string profileName)
    signal profileSaved(string profileId, string profileName)
    signal profileDeleted(string profileId)
    signal profileError(string message)

    function buildCurrentOutputSet() {
        const connected = [];
        for (const name in outputs) {
            const output = outputs[name];
            connected.push(getOutputIdentifier(output, name));
        }
        return connected.sort();
    }

    function getOutputIdentifier(output, outputName) {
        return output?.id || outputName;
    }

    FileView {
        id: monitorsFile

        path: Paths.strip(Paths.config) + "/monitors.json"
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onLoaded: root._reparseMonitorsJson(monitorsFile.text())
        onLoadFailed: root._reparseMonitorsJson("")
        onFileChanged: {
            if (root._monitorsSelfWrite) {
                root._monitorsSelfWrite = false;
                return;
            }
            monitorsFile.reload();
        }
        onSaveFailed: error => {
            root._monitorsSelfWrite = false;
            log.warn("Failed to save monitors.json:", error);
        }
    }

    function _reparseMonitorsJson(text) {
        if (!text || !text.trim()) {
            monitorsCache = {
                "version": 1,
                "configurations": []
            };
        } else {
            try {
                const parsed = JSON.parse(text);
                if (!Array.isArray(parsed.configurations))
                    parsed.configurations = [];
                monitorsCache = parsed;
            } catch (e) {
                log.warn("Failed to parse monitors.json, using empty config");
                monitorsCache = {
                    "version": 1,
                    "configurations": []
                };
            }
        }
        _initializeProfiles();
    }

    function _initializeProfiles() {
        validateProfiles();
    }

    function readMonitorsJson(callback) {
        callback(monitorsCache);
    }

    function writeMonitorsJson(data, callback) {
        monitorsCache = data;
        _monitorsSelfWrite = true;
        monitorsFile.setText(JSON.stringify(data, null, 2));
        if (callback)
            callback(true);
    }

    function publishActiveProfileModes() {
        const compositor = CompositorService.compositor;
        const profileId = SettingsData.getActiveDisplayProfile(compositor);
        const profile = profileId ? validatedProfiles[profileId] : null;
        const outputs = profile?.outputs || {};
        const modes = {};

        for (const outputId in outputs) {
            const mode = outputs[outputId]?.mode;
            if (mode)
                modes[outputId] = {
                    "mode": mode
                };
        }

        SettingsData.setActiveDisplayProfileModes(compositor, modes);
    }

    function generateProfileId() {
        return "profile_" + Date.now() + "_" + Math.random().toString(36).slice(2, 9);
    }

    function generateAutoProfileId(outputIdentifiers) {
        const fp = outputSetFingerprint(outputIdentifiers);
        let hash = 0;
        for (let i = 0; i < fp.length; i++) {
            hash = ((hash << 5) - hash) + fp.charCodeAt(i);
        }
        const hashStr = (hash >>> 0).toString(16);
        return "auto_" + hashStr;
    }

    function configFingerprint(configEntry) {
        return Object.keys(configEntry.outputs || {}).sort().join("+");
    }

    function outputSetFingerprint(outputIdentifiers) {
        return [...outputIdentifiers].sort().join("+");
    }

    function findConfigEntryById(data, id) {
        const configs = data.configurations || [];
        for (let i = 0; i < configs.length; i++) {
            if (configs[i].id === id)
                return {
                    entry: configs[i],
                    index: i
                };
        }
        return null;
    }

    function findConfigEntryByFingerprint(data, outputIdentifiers, autoOnly) {
        const targetKey = outputSetFingerprint(outputIdentifiers);
        const configs = data.configurations || [];
        for (let i = 0; i < configs.length; i++) {
            if (configFingerprint(configs[i]) === targetKey) {
                if (autoOnly && configs[i].name)
                    continue;
                return {
                    entry: configs[i],
                    index: i
                };
            }
        }
        return null;
    }

    function getProfileMonitorInclusion(profileId) {
        const profile = validatedProfiles[profileId];
        const profileOutputIds = new Set(Object.keys(profile?.outputs || {}));
        const result = {};
        for (const rawName in allOutputs) {
            const od = allOutputs[rawName];
            const id = od ? getOutputIdentifier(od, rawName) : rawName;
            result[rawName] = profileOutputIds.has(id);
        }
        return result;
    }

    function updateProfileMonitors(profileId, enabledRawNames) {
        readMonitorsJson(data => {
            const match = findConfigEntryById(data, profileId);
            if (!match) {
                profileError(I18n.tr("Profile not found"));
                return;
            }
            const profileName = match.entry.name;
            const existingOutputs = match.entry.outputs || {};
            const mergedAll = buildOutputsWithPendingChanges();
            const newOutputConfigs = {};
            for (const rawName of enabledRawNames) {
                const od = mergedAll[rawName] || allOutputs[rawName];
                if (!od)
                    continue;
                const outputId = getOutputIdentifier(od, rawName);
                newOutputConfigs[outputId] = existingOutputs[outputId] || extractOutputNeutralConfig(rawName, od);
            }
            data.configurations[match.index] = {
                "id": profileId,
                "name": profileName,
                "outputs": newOutputConfigs
            };
            writeMonitorsJson(data, success => {
                if (!success)
                    return;
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                updated[profileId] = {
                    id: profileId,
                    name: profileName,
                    outputs: newOutputConfigs
                };
                validatedProfiles = updated;
                matchedProfile = findMatchingProfile();
                publishActiveProfileModes();
                profileSaved(profileId, profileName);
            });
        });
    }

    // Extract neutral per-output config from current live state
    function extractOutputNeutralConfig(outputName, outputData) {
        const modeData = (outputData.modes && outputData.current_mode !== undefined) ? outputData.modes[outputData.current_mode] : null;
        const modeStr = modeData ? modeData.width + "x" + modeData.height + "@" + (modeData.refresh_rate / 1000).toFixed(3) : null;
        const cfg = {
            "mode": modeStr,
            "position": {
                "x": outputData.logical?.x ?? 0,
                "y": outputData.logical?.y ?? 0
            },
            "scale": outputData.logical?.scale || 1.0,
            "transform": outputData.logical?.transform ?? "Normal",
            "vrr": outputData.vrr_enabled ?? false,
            "disabled": outputData.enabled === false
        };
        return cfg;
    }

    // Convert monitors.json config entry → internal outputsData map
    function profileKeyMatchesOutput(outputId, output, name) {
        if (name === outputId || output?.name === outputId || getOutputIdentifier(output, name) === outputId)
            return true;
        if (!outputId.startsWith("desc:") || !output?.make)
            return false;
        const want = outputId.slice(5).trim();
        const full = [output.make, output.model, output.serial].filter(p => p).join(" ").replace(/,/g, "");
        const noSerial = [output.make, output.model].filter(p => p).join(" ").replace(/,/g, "");
        return want === full || want === noSerial || full.startsWith(want + " ");
    }

    function generateOutputsDataFromConfig(configEntry) {
        const result = {};
        const cfgOutputs = configEntry.outputs || {};
        for (const outputId in cfgOutputs) {
            const cfg = cfgOutputs[outputId];
            // Find matching live output to get modes list
            let liveOutput = null;
            for (const name in outputs) {
                if (profileKeyMatchesOutput(outputId, outputs[name], name)) {
                    liveOutput = outputs[name];
                    break;
                }
            }
            const liveModes = liveOutput?.modes || [];
            const currentMode = liveModes.findIndex(m => {
                const s = m.width + "x" + m.height + "@" + (m.refresh_rate / 1000).toFixed(3);
                return s === cfg.mode;
            });
            const entry = {
                "name": liveOutput?.name || outputId,
                "enabled": !cfg.disabled,
                "explicitIdentifier": true,
                "configured_mode": cfg.mode || "",
                "make": liveOutput?.make || "",
                "model": liveOutput?.model || "",
                "serial": liveOutput?.serial || "",
                "modes": liveModes,
                "current_mode": currentMode,
                "vrr_supported": liveOutput?.vrr_supported ?? false,
                "vrr_enabled": cfg.vrr ?? false,
                "logical": {
                    "x": cfg.position?.x ?? 0,
                    "y": cfg.position?.y ?? 0,
                    "scale": cfg.scale ?? 1.0,
                    "transform": cfg.transform ?? "Normal"
                }
            };
            result[outputId] = entry;
        }
        return result;
    }

    function ensureEnabledOutput(configEntry) {
        const outputKeys = Object.keys(configEntry.outputs || {});
        if (outputKeys.length === 0)
            return false;
        const hasEnabled = outputKeys.some(k => !configEntry.outputs[k].disabled);
        if (hasEnabled)
            return false;
        delete configEntry.outputs[outputKeys[0]].disabled;
        return true;
    }

    // Write compositor config from a neutral config entry and optionally reload
    function applyConfigEntry(configEntry, configId, profileName, isManual) {
        ensureEnabledOutput(configEntry);
        // Capture the entry being applied so disabled-output settings fields can
        // still read scale, position and transform.
        root.lastAppliedEntry = JSON.parse(JSON.stringify(configEntry));
        const outputsData = generateOutputsDataFromConfig(configEntry);

        const onWriteFailed = () => {
            if (isManual) {
                profilesLoading = false;
                manualActivation = false;
                profileError(I18n.tr("Failed to apply profile"));
            }
        };
        const onWriteSuccess = () => {
            SettingsData.setActiveDisplayProfile(CompositorService.compositor, configId);
            publishActiveProfileModes();
            if (isManual) {
                profilesLoading = false;
                profileActivated(configId, profileName);
                manualActivationTimer.restart();
            }
            Macqueen.refresh();
        };

        backendWriteOutputsConfig(outputsData, success => {
            if (success)
                onWriteSuccess();
            else
                onWriteFailed();
        });
    }

    // ── Profile management ─────────────────────────────────────────────────

    function validateProfiles() {
        log.info("Validating profiles against current outputs...");
        readMonitorsJson(data => {
            const validated = {};
            let dirty = false;
            for (const entry of (data.configurations || [])) {
                const fp = configFingerprint(entry);
                if (!fp)
                    continue;
                if (!entry.id) {
                    entry.id = generateProfileId();
                    dirty = true;
                }
                if (ensureEnabledOutput(entry))
                    dirty = true;
                validated[entry.id] = {
                    id: entry.id,
                    name: entry?.name || "",
                    outputs: entry.outputs
                };
            }
            if (dirty)
                writeMonitorsJson(data, null);
            validatedProfiles = validated;
            matchedProfile = findMatchingProfile();
            publishActiveProfileModes();
            if (!profilesReady) {
                profilesReady = true;
                applyAutoConfig();
            }
        });
    }

    function findMatchingProfile() {
        const currentKey = currentOutputSet.join("+");
        for (const id in validatedProfiles) {
            const p = validatedProfiles[id];
            if (p.name === "")
                continue;
            if (Object.keys(p.outputs || {}).sort().join("+") === currentKey)
                return id;
        }
        return "";
    }

    function createProfile(profileName) {
        const outputConfigs = buildCurrentOutputConfigs();
        const id = generateProfileId();

        profilesLoading = true;
        readMonitorsJson(data => {
            data.configurations.push({
                "id": id,
                "name": profileName,
                "outputs": outputConfigs
            });

            writeMonitorsJson(data, success => {
                profilesLoading = false;
                if (!success) {
                    profileError(I18n.tr("Failed to save profile"));
                    return;
                }
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                updated[id] = {
                    id: id,
                    name: profileName,
                    outputs: outputConfigs
                };
                validatedProfiles = updated;
                currentOutputSet = buildCurrentOutputSet();
                matchedProfile = findMatchingProfile();
                SettingsData.setActiveDisplayProfile(CompositorService.compositor, id);
                publishActiveProfileModes();
                profileSaved(id, profileName);
            });
        });
    }

    function renameProfile(profileId, newName) {
        readMonitorsJson(data => {
            const match = findConfigEntryById(data, profileId);
            if (!match) {
                profileError(I18n.tr("Profile not found"));
                return;
            }
            match.entry.name = newName;
            data.configurations[match.index] = match.entry;
            writeMonitorsJson(data, success => {
                if (!success)
                    return;
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                if (updated[profileId])
                    updated[profileId].name = newName;
                validatedProfiles = updated;
            });
        });
    }

    function deleteProfile(profileId) {
        const compositor = CompositorService.compositor;
        const isActive = SettingsData.getActiveDisplayProfile(compositor) === profileId;

        profilesLoading = true;
        readMonitorsJson(data => {
            const match = findConfigEntryById(data, profileId);
            if (match)
                data.configurations.splice(match.index, 1);
            writeMonitorsJson(data, success => {
                profilesLoading = false;
                SettingsData.removeDisplayProfile(compositor, profileId);
                if (isActive) {
                    SettingsData.setActiveDisplayProfile(compositor, "");
                    backendWriteOutputsConfig(allOutputs);
                }
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                delete updated[profileId];
                validatedProfiles = updated;
                matchedProfile = findMatchingProfile();
                publishActiveProfileModes();
                profileDeleted(profileId);
            });
        });
    }

    function activateProfile(profileId) {
        manualActivation = true;
        profilesLoading = true;
        readMonitorsJson(data => {
            const match = findConfigEntryById(data, profileId);
            if (!match) {
                profilesLoading = false;
                manualActivation = false;
                profileError(I18n.tr("Profile not found in monitors.json"));
                return;
            }
            applyConfigEntry(match.entry, profileId, match.entry.name || profileId, true);
        });
    }

    Timer {
        id: manualActivationTimer
        interval: 2000
        onTriggered: root.manualActivation = false
    }

    Timer {
        id: autoSelectDebounceTimer
        interval: 400
        onTriggered: {
            if (root.hasPendingChanges)
                return;
            root.applyAutoConfig();
        }
    }

    function configEntryMatchesLiveLayout(configEntry) {
        const cfgOutputs = configEntry.outputs || {};
        for (const outputId in cfgOutputs) {
            const cfg = cfgOutputs[outputId];
            let live = null;
            for (const name in outputs) {
                if (profileKeyMatchesOutput(outputId, outputs[name], name)) {
                    live = outputs[name];
                    break;
                }
            }
            if (!live)
                return false;
            if ((cfg.disabled ?? false) !== !(live.enabled ?? true))
                return false;
            if (cfg.disabled)
                continue;
            const mode = (live.modes && live.current_mode >= 0) ? live.modes[live.current_mode] : null;
            const modeStr = mode ? mode.width + "x" + mode.height + "@" + (mode.refresh_rate / 1000).toFixed(3) : null;
            if (cfg.mode && modeStr !== cfg.mode)
                return false;
            if ((cfg.position?.x ?? 0) !== (live.logical?.x ?? 0) || (cfg.position?.y ?? 0) !== (live.logical?.y ?? 0))
                return false;
            if (Math.abs((cfg.scale ?? 1.0) - (live.logical?.scale ?? 1.0)) > 0.001)
                return false;
            if ((cfg.transform ?? "Normal") !== (live.logical?.transform ?? "Normal"))
                return false;
        }
        return true;
    }

    function applyAutoConfig() {
        if (!profilesReady || !SettingsData.displayProfileAutoSelect || manualActivation || !currentOutputSet.length)
            return;

        readMonitorsJson(data => {
            const match = findConfigEntryByFingerprint(data, currentOutputSet, true);
            if (match) {
                if (configEntryMatchesLiveLayout(match.entry)) {
                    SettingsData.setActiveDisplayProfile(CompositorService.compositor, match.entry.id);
                    return;
                }
                applyConfigEntry(match.entry, match.entry.id, "", false);
                return;
            }

            const outputConfigs = buildCurrentOutputConfigs();
            const id = generateAutoProfileId(currentOutputSet);
            const existingIdx = data.configurations.findIndex(c => c.id === id);
            if (existingIdx >= 0)
                data.configurations[existingIdx] = {
                    "id": id,
                    "name": "",
                    "outputs": outputConfigs
                };
            else
                data.configurations.push({
                    "id": id,
                    "name": "",
                    "outputs": outputConfigs
                });
            writeMonitorsJson(data, success => {
                if (!success)
                    return;
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                updated[id] = {
                    id: id,
                    name: "",
                    outputs: outputConfigs
                };
                validatedProfiles = updated;
                matchedProfile = "";
                const match = findConfigEntryById(data, id);
                if (match)
                    applyConfigEntry(match.entry, id, "", false);
            });
        });
    }

    function buildCurrentOutputConfigs() {
        const mergedAll = buildOutputsWithPendingChanges();
        const outputConfigs = {};
        for (const name in outputs) {
            const od = mergedAll[name];
            if (od)
                outputConfigs[getOutputIdentifier(od, name)] = extractOutputNeutralConfig(name, od);
        }
        return outputConfigs;
    }

    function deleteDisconnectedOutput(outputName) {
        if (outputs[outputName]?.connected)
            return;

        const updated = JSON.parse(JSON.stringify(savedOutputs));
        delete updated[outputName];
        savedOutputs = updated;

        const mergedOutputs = {};
        for (const name in outputs)
            mergedOutputs[name] = outputs[name];
        for (const name in updated)
            mergedOutputs[name] = updated[name];

        backendWriteOutputsConfig(mergedOutputs);
    }

    function buildAllOutputsMap() {
        const result = {};
        for (const name in savedOutputs) {
            result[name] = Object.assign({}, savedOutputs[name], {
                "connected": false
            });
        }
        for (const name in outputs) {
            const entry = JSON.parse(JSON.stringify(outputs[name]));
            entry.connected = true;
            // Restore the last saved geometry for a disabled monitor so
            // the settings UI can display meaningful values.
            if (!(entry.logical?.scale > 0)) {
                const profileCfg = getProfileOutputConfig(name);
                if (profileCfg) {
                    if (!entry.logical)
                        entry.logical = {};
                    entry.logical.scale = profileCfg.scale ?? 1.0;
                    entry.logical.x = profileCfg.position?.x ?? entry.logical.x ?? 0;
                    entry.logical.y = profileCfg.position?.y ?? entry.logical.y ?? 0;
                    if (profileCfg.transform)
                        entry.logical.transform = profileCfg.transform;
                } else if (entry.logical) {
                    entry.logical.scale = entry.logical.scale || 1.0;
                }
            }
            result[name] = entry;
        }
        return result;
    }

    function getProfileOutputConfig(outputName) {
        const sourceEntry = lastAppliedEntry || (matchedProfile ? validatedProfiles[matchedProfile] : null);
        if (!sourceEntry)
            return null;
        const cfgOutputs = sourceEntry.outputs || {};
        const outputId = getOutputIdentifier(outputs[outputName] || {}, outputName);
        return Object.entries(cfgOutputs).find(([key]) => key === outputId)?.[1] ?? null;
    }

    onOutputsChanged: {
        allOutputs = buildAllOutputsMap();
        const newOutputSet = buildCurrentOutputSet();
        if (JSON.stringify(newOutputSet) === JSON.stringify(currentOutputSet))
            return;
        // Physical output set changed — pending tweaks belong to the previous setup
        if (hasPendingChanges)
            clearPendingChanges();
        currentOutputSet = newOutputSet;
        autoSelectDebounceTimer.restart();
    }
    onSavedOutputsChanged: allOutputs = buildAllOutputsMap()
    onLastAppliedEntryChanged: allOutputs = buildAllOutputsMap()

    Connections {
        target: Macqueen
        function onOutputsChanged() {
            root.outputs = root.buildOutputsMap();
            root.reloadSavedOutputs();
        }
        function onAvailableChanged() {
            root.outputs = root.buildOutputsMap();
            root.reloadSavedOutputs();
        }
    }

    Connections {
        target: CompositorService
        function onCompositorChanged() {
            root.outputs = root.buildOutputsMap();
            root.reloadSavedOutputs();
            root.publishActiveProfileModes();
        }
    }

    Connections {
        target: SettingsData
        function onActiveDisplayProfileChanged() {
            root.publishActiveProfileModes();
        }
    }

    Component.onCompleted: {
        outputs = buildOutputsMap();
        reloadSavedOutputs();
    }

    function reloadSavedOutputs() {
        savedOutputs = {};
    }

    function buildOutputsMap() {
        const map = {};
        for (const output of nativeOutputs) {
            const normalizedModes = (output.modes || []).map(m => ({
                        "id": m.id,
                        "width": m.width,
                        "height": m.height,
                        "refresh_rate": m.refresh,
                        "preferred": m.preferred ?? false
                    }));
            map[output.name] = {
                "id": output.id || output.name,
                "name": output.name,
                "enabled": output.enabled ?? true,
                "make": output.make || "",
                "model": output.model || "",
                "serial": output.serialNumber || "",
                "modes": normalizedModes,
                "current_mode": normalizedModes.findIndex(m => m.id === output.currentMode?.id),
                "vrr_supported": output.adaptiveSyncSupported ?? false,
                "vrr_enabled": output.adaptiveSync === 1,
                "logical": {
                    "x": output.x ?? 0,
                    "y": output.y ?? 0,
                    "width": output.currentMode?.width ?? 1920,
                    "height": output.currentMode?.height ?? 1080,
                    "scale": output.scale || 1.0,
                    "transform": mapMacqueenTransform(output.transform)
                }
            };
        }
        return map;
    }

    function mapMacqueenTransform(transform) {
        switch (transform) {
        case 0:
            return "Normal";
        case 1:
            return "90";
        case 2:
            return "180";
        case 3:
            return "270";
        case 4:
            return "Flipped";
        case 5:
            return "Flipped90";
        case 6:
            return "Flipped180";
        case 7:
            return "Flipped270";
        default:
            return "Normal";
        }
    }

    function mapTransformToMacqueen(transform) {
        switch (transform) {
        case "Normal":
            return 0;
        case "90":
            return 1;
        case "180":
            return 2;
        case "270":
            return 3;
        case "Flipped":
            return 4;
        case "Flipped90":
            return 5;
        case "Flipped180":
            return 6;
        case "Flipped270":
            return 7;
        default:
            return 0;
        }
    }

    function backendFetchOutputs() {
        Macqueen.refresh();
    }

    function backendWriteOutputsConfig(outputsData, settingsOrCallback, maybeCallback) {
        const callback = typeof settingsOrCallback === "function" ? settingsOrCallback : maybeCallback;

        function finish(success) {
            if (callback)
                callback(success);
        }

        const heads = [];
        for (const name in outputsData) {
            const output = outputsData[name];
            const mode = output.modes?.[output.current_mode];
            const head = {
                "name": output.name || name,
                "enabled": output.enabled !== false,
                "position": {
                    "x": output.logical?.x ?? 0,
                    "y": output.logical?.y ?? 0
                },
                "scale": output.logical?.scale ?? 1.0,
                "transform": mapTransformToMacqueen(output.logical?.transform ?? "Normal")
            };
            if (mode?.id !== undefined)
                head.modeId = mode.id;
            if (output.vrr_supported)
                head.adaptiveSync = output.vrr_enabled ? 1 : 0;
            heads.push(head);
        }
        const success = Macqueen.applyOutputConfiguration(heads);
        if (success)
            Macqueen.refresh();
        else
            ToastService.showError(I18n.tr("Display configuration failed"), I18n.tr("Macqueen rejected the requested monitor configuration."), "", "display-config");
        finish(success);
        return success;
    }

    function normalizeOutputPositions(outputsData) {
        const names = Object.keys(outputsData);
        if (names.length === 0)
            return outputsData;

        let minX = Infinity;
        let minY = Infinity;

        for (const name of names) {
            const output = outputsData[name];
            if (!output.logical)
                continue;
            minX = Math.min(minX, output.logical.x);
            minY = Math.min(minY, output.logical.y);
        }

        if (minX === Infinity || (minX === 0 && minY === 0))
            return outputsData;

        const normalized = JSON.parse(JSON.stringify(outputsData));
        for (const name of names) {
            if (!normalized[name].logical)
                continue;
            normalized[name].logical.x -= minX;
            normalized[name].logical.y -= minY;
        }

        return normalized;
    }

    function buildOutputsWithPendingChanges() {
        const result = {};

        for (const outputName in savedOutputs) {
            if (!outputs[outputName])
                result[outputName] = JSON.parse(JSON.stringify(savedOutputs[outputName]));
        }

        for (const outputName in outputs) {
            result[outputName] = JSON.parse(JSON.stringify(outputs[outputName]));
        }

        for (const outputName in pendingChanges) {
            if (!result[outputName])
                continue;
            const changes = pendingChanges[outputName];
            if (changes.position && result[outputName].logical) {
                result[outputName].logical.x = changes.position.x;
                result[outputName].logical.y = changes.position.y;
            }
            if (changes.mode !== undefined && result[outputName].modes) {
                for (var i = 0; i < result[outputName].modes.length; i++) {
                    if (formatMode(result[outputName].modes[i]) === changes.mode) {
                        result[outputName].current_mode = i;
                        break;
                    }
                }
            }
            if (changes.scale !== undefined && result[outputName].logical)
                result[outputName].logical.scale = changes.scale;
            if (changes.transform !== undefined && result[outputName].logical)
                result[outputName].logical.transform = changes.transform;
            if (changes.vrr !== undefined)
                result[outputName].vrr_enabled = changes.vrr;
            if (changes.enabled !== undefined)
                result[outputName].enabled = changes.enabled;
            if (changes.mirror !== undefined)
                result[outputName].mirror = changes.mirror;
        }
        return normalizeOutputPositions(result);
    }

    function backendUpdateOutputPosition(outputName, x, y) {
        if (!outputs || !outputs[outputName])
            return;
        const updatedOutputs = {};
        for (const name in outputs) {
            const output = outputs[name];
            if (name === outputName && output.logical) {
                updatedOutputs[name] = JSON.parse(JSON.stringify(output));
                updatedOutputs[name].logical.x = x;
                updatedOutputs[name].logical.y = y;
            } else {
                updatedOutputs[name] = output;
            }
        }
        outputs = updatedOutputs;
    }

    function backendUpdateOutputScale(outputName, scale) {
        if (!outputs || !outputs[outputName])
            return;
        const updatedOutputs = {};
        for (const name in outputs) {
            const output = outputs[name];
            if (name === outputName && output.logical) {
                updatedOutputs[name] = JSON.parse(JSON.stringify(output));
                updatedOutputs[name].logical.scale = scale;
            } else {
                updatedOutputs[name] = output;
            }
        }
        outputs = updatedOutputs;
    }

    function getOutputDisplayName(output, outputName) {
        if (SettingsData.displayNameMode === "model" && output?.make && output?.model)
            return output.make + " " + output.model;
        return outputName;
    }

    function initOriginalOutputs() {
        if (!originalOutputs)
            originalOutputs = JSON.parse(JSON.stringify(outputs));
    }

    function setPendingChange(outputName, key, value) {
        initOriginalOutputs();
        const newPending = JSON.parse(JSON.stringify(pendingChanges));
        if (!newPending[outputName])
            newPending[outputName] = {};
        newPending[outputName][key] = value;
        pendingChanges = newPending;

        if (key === "scale") {
            recalculateAdjacentPositions(outputName, value);
            backendUpdateOutputScale(outputName, value);
        }
    }

    function recalculateAdjacentPositions(changedOutput, newScale) {
        const output = outputs[changedOutput];
        if (!output?.logical)
            return;
        const oldPhys = getPhysicalSize(output);
        const oldLogicalW = Math.round(oldPhys.w / (output.logical.scale || 1.0));
        const newLogicalW = Math.round(oldPhys.w / newScale);

        const changedX = getPendingValue(changedOutput, "position")?.x ?? output.logical.x;
        const changedY = getPendingValue(changedOutput, "position")?.y ?? output.logical.y;

        for (const name in outputs) {
            if (name === changedOutput)
                continue;
            const other = outputs[name];
            if (!other?.logical)
                continue;
            const otherX = getPendingValue(name, "position")?.x ?? other.logical.x;
            const otherY = getPendingValue(name, "position")?.y ?? other.logical.y;
            const otherSize = getLogicalSize(other);
            const otherRight = otherX + otherSize.w;

            if (Math.abs(changedX - otherRight) < 5) {
                const newX = otherRight;
                const newPending = JSON.parse(JSON.stringify(pendingChanges));
                if (!newPending[changedOutput])
                    newPending[changedOutput] = {};
                newPending[changedOutput].position = {
                    "x": newX,
                    "y": changedY
                };
                pendingChanges = newPending;
                backendUpdateOutputPosition(changedOutput, newX, changedY);
                return;
            }

            const changedRight = changedX + oldLogicalW;
            if (Math.abs(otherX - changedRight) < 5) {
                const newOtherX = changedX + newLogicalW;
                const newPending = JSON.parse(JSON.stringify(pendingChanges));
                if (!newPending[name])
                    newPending[name] = {};
                newPending[name].position = {
                    "x": newOtherX,
                    "y": otherY
                };
                pendingChanges = newPending;
                backendUpdateOutputPosition(name, newOtherX, otherY);
            }
        }
    }

    function getPendingValue(outputName, key) {
        if (!pendingChanges[outputName])
            return undefined;
        return pendingChanges[outputName][key];
    }

    function getEffectiveValue(outputName, key, originalValue) {
        const pending = getPendingValue(outputName, key);
        return pending !== undefined ? pending : originalValue;
    }

    // Returns true if the given output can currently be disabled.
    // Prevents disabling all outputs and prevents disabling the only output
    // in a single-display configuration.
    function canDisableOutput() {
        const totalOutputs = Object.keys(outputs).length;
        if (totalOutputs <= 1)
            return false;
        let enabledCount = 0;
        for (const name in outputs) {
            const pendingEnabled = getPendingValue(name, "enabled");
            const enabled = pendingEnabled !== undefined ? pendingEnabled : outputs[name].enabled !== false;
            if (enabled)
                enabledCount++;
        }
        return enabledCount >= 2;
    }

    function clearPendingChanges() {
        pendingChanges = {};
        originalOutputs = null;
        originalDisplayNameMode = "";
    }

    function discardChanges() {
        if (originalDisplayNameMode !== "") {
            SettingsData.displayNameMode = originalDisplayNameMode;
            SettingsData.saveSettings();
        }
        backendFetchOutputs();
        clearPendingChanges();
    }

    function applyChanges() {
        if (!hasPendingChanges)
            return;
        const changeDescriptions = [];

        if (formatChanged) {
            const formatLabel = SettingsData.displayNameMode === "model" ? I18n.tr("Model") : I18n.tr("Name");
            changeDescriptions.push(I18n.tr("Display Name Format") + " → " + formatLabel);
        }

        for (const outputName in pendingChanges) {
            const changes = pendingChanges[outputName];
            if (changes.position)
                changeDescriptions.push(outputName + ": " + I18n.tr("Position") + " → " + changes.position.x + ", " + changes.position.y);
            if (changes.mode)
                changeDescriptions.push(outputName + ": " + I18n.tr("Mode") + " → " + changes.mode);
            if (changes.scale !== undefined)
                changeDescriptions.push(outputName + ": " + I18n.tr("Scale") + " → " + changes.scale);
            if (changes.transform)
                changeDescriptions.push(outputName + ": " + I18n.tr("Transform") + " → " + getTransformLabel(changes.transform));
            if (changes.vrr !== undefined)
                changeDescriptions.push(outputName + ": " + I18n.tr("VRR") + " → " + (changes.vrr ? I18n.tr("Enabled") : I18n.tr("Disabled")));
            if (changes.enabled !== undefined)
                changeDescriptions.push(outputName + ": " + I18n.tr("Enabled") + " → " + (changes.enabled ? I18n.tr("Yes") : I18n.tr("No")));
        }

        if (formatChanged)
            SettingsData.saveSettings();

        const mergedOutputs = buildOutputsWithPendingChanges();
        backendWriteOutputsConfig(mergedOutputs, success => {
            if (success)
                changesApplied(changeDescriptions);
        });
    }

    function confirmChanges(profileId) {
        const outputConfigs = buildCurrentOutputConfigs();
        lastAppliedEntry = {
            outputs: outputConfigs
        };

        readMonitorsJson(data => {
            const match = profileId ? findConfigEntryById(data, profileId) : findConfigEntryByFingerprint(data, currentOutputSet, true);
            if (!match)
                return;
            data.configurations[match.index] = {
                "id": match.entry.id,
                "name": match.entry.name || "",
                "outputs": outputConfigs
            };
            writeMonitorsJson(data, success => {
                if (!success || !profileId)
                    return;
                const updated = JSON.parse(JSON.stringify(validatedProfiles));
                if (updated[profileId]) {
                    updated[profileId].outputs = outputConfigs;
                    validatedProfiles = updated;
                    publishActiveProfileModes();
                }
            });
        });

        clearPendingChanges();
        changesConfirmed();
    }

    function revertChanges() {
        const hadFormatChange = originalDisplayNameMode !== "";

        if (hadFormatChange) {
            SettingsData.displayNameMode = originalDisplayNameMode;
            SettingsData.saveSettings();
        }

        if (!originalOutputs) {
            if (hadFormatChange)
                backendWriteOutputsConfig(buildOutputsWithPendingChanges());
            clearPendingChanges();
            changesReverted();
            return;
        }

        const original = originalOutputs ? JSON.parse(JSON.stringify(originalOutputs)) : buildOutputsWithPendingChanges();
        for (const name in savedOutputs) {
            if (!original[name])
                original[name] = JSON.parse(JSON.stringify(savedOutputs[name]));
        }
        backendWriteOutputsConfig(original);
        clearPendingChanges();
        if (originalOutputs)
            outputs = original;
        changesReverted();
    }

    function getOutputBounds() {
        if (!allOutputs || Object.keys(allOutputs).length === 0)
            return {
                "minX": 0,
                "minY": 0,
                "maxX": 1920,
                "maxY": 1080,
                "width": 1920,
                "height": 1080
            };

        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;

        for (const name in allOutputs) {
            const output = allOutputs[name];
            if (!output.logical)
                continue;
            const x = output.logical.x;
            const y = output.logical.y;
            const size = getLogicalSize(output);
            minX = Math.min(minX, x);
            minY = Math.min(minY, y);
            maxX = Math.max(maxX, x + size.w);
            maxY = Math.max(maxY, y + size.h);
        }

        if (minX === Infinity)
            return {
                "minX": 0,
                "minY": 0,
                "maxX": 1920,
                "maxY": 1080,
                "width": 1920,
                "height": 1080
            };
        return {
            "minX": minX,
            "minY": minY,
            "maxX": maxX,
            "maxY": maxY,
            "width": maxX - minX,
            "height": maxY - minY
        };
    }

    function isRotated(transform) {
        switch (transform) {
        case "90":
        case "270":
        case "Flipped90":
        case "Flipped270":
            return true;
        default:
            return false;
        }
    }

    function getPhysicalSize(output) {
        if (!output)
            return {
                "w": 1920,
                "h": 1080
            };

        let w = 1920, h = 1080;
        if (output.modes && output.current_mode !== undefined) {
            const mode = output.modes[output.current_mode];
            if (mode) {
                w = mode.width || 1920;
                h = mode.height || 1080;
            }
        } else if (output.logical) {
            const scale = output.logical.scale || 1.0;
            w = Math.round((output.logical.width || 1920) * scale);
            h = Math.round((output.logical.height || 1080) * scale);
        }

        if (output.logical && isRotated(output.logical.transform))
            return {
                "w": h,
                "h": w
            };
        return {
            "w": w,
            "h": h
        };
    }

    function getLogicalSize(output) {
        if (!output)
            return {
                "w": 1920,
                "h": 1080
            };

        const phys = getPhysicalSize(output);
        const scale = output.logical?.scale || 1.0;

        return {
            "w": Math.round(phys.w / scale),
            "h": Math.round(phys.h / scale)
        };
    }

    function isOutputDisabled(outputName) {
        if (!outputs[outputName])
            return false;
        const pendingEnabled = getPendingValue(outputName, "enabled");
        return pendingEnabled !== undefined ? !pendingEnabled : outputs[outputName].enabled === false;
    }

    function checkOverlap(testName, testX, testY, testW, testH) {
        for (const name in outputs) {
            if (name === testName)
                continue;
            if (isOutputDisabled(name))
                continue;
            const output = outputs[name];
            if (!output.logical)
                continue;
            const x = output.logical.x;
            const y = output.logical.y;
            const size = getLogicalSize(output);
            if (!(testX + testW <= x || testX >= x + size.w || testY + testH <= y || testY >= y + size.h))
                return true;
        }
        return false;
    }

    function snapToEdges(testName, posX, posY, testW, testH) {
        const snapThreshold = 200;
        let snappedX = posX;
        let snappedY = posY;
        let bestXDist = snapThreshold;
        let bestYDist = snapThreshold;

        for (const name in outputs) {
            if (name === testName)
                continue;
            if (isOutputDisabled(name))
                continue;
            const output = outputs[name];
            if (!output.logical)
                continue;
            const x = output.logical.x;
            const y = output.logical.y;
            const size = getLogicalSize(output);

            const rightEdge = x + size.w;
            const bottomEdge = y + size.h;
            const testRight = posX + testW;
            const testBottom = posY + testH;

            const xSnaps = [
                {
                    "val": rightEdge,
                    "dist": Math.abs(posX - rightEdge)
                },
                {
                    "val": x - testW,
                    "dist": Math.abs(testRight - x)
                },
                {
                    "val": x,
                    "dist": Math.abs(posX - x)
                },
                {
                    "val": rightEdge - testW,
                    "dist": Math.abs(testRight - rightEdge)
                }
            ];

            const ySnaps = [
                {
                    "val": bottomEdge,
                    "dist": Math.abs(posY - bottomEdge)
                },
                {
                    "val": y - testH,
                    "dist": Math.abs(testBottom - y)
                },
                {
                    "val": y,
                    "dist": Math.abs(posY - y)
                },
                {
                    "val": bottomEdge - testH,
                    "dist": Math.abs(testBottom - bottomEdge)
                }
            ];

            for (const snap of xSnaps) {
                if (snap.dist < bestXDist) {
                    bestXDist = snap.dist;
                    snappedX = snap.val;
                }
            }

            for (const snap of ySnaps) {
                if (snap.dist < bestYDist) {
                    bestYDist = snap.dist;
                    snappedY = snap.val;
                }
            }
        }

        if (checkOverlap(testName, snappedX, snappedY, testW, testH)) {
            if (!checkOverlap(testName, snappedX, posY, testW, testH))
                return Qt.point(snappedX, posY);
            if (!checkOverlap(testName, posX, snappedY, testW, testH))
                return Qt.point(posX, snappedY);
            return Qt.point(posX, posY);
        }
        return Qt.point(snappedX, snappedY);
    }

    function findBestSnapPosition(testName, posX, posY, testW, testH) {
        const outputNames = Object.keys(outputs).filter(n => n !== testName && !isOutputDisabled(n));

        if (outputNames.length === 0)
            return Qt.point(posX, posY);

        let bestPos = null;
        let bestDist = Infinity;

        for (const name of outputNames) {
            const output = outputs[name];
            if (!output.logical)
                continue;
            const x = output.logical.x;
            const y = output.logical.y;
            const size = getLogicalSize(output);

            const candidates = [
                {
                    "px": x + size.w,
                    "py": y
                },
                {
                    "px": x - testW,
                    "py": y
                },
                {
                    "px": x,
                    "py": y + size.h
                },
                {
                    "px": x,
                    "py": y - testH
                },
                {
                    "px": x + size.w,
                    "py": y + size.h - testH
                },
                {
                    "px": x - testW,
                    "py": y + size.h - testH
                },
                {
                    "px": x + size.w - testW,
                    "py": y + size.h
                },
                {
                    "px": x + size.w - testW,
                    "py": y - testH
                }
            ];

            for (const c of candidates) {
                if (checkOverlap(testName, c.px, c.py, testW, testH))
                    continue;
                const dist = Math.hypot(c.px - posX, c.py - posY);
                if (dist < bestDist) {
                    bestDist = dist;
                    bestPos = Qt.point(c.px, c.py);
                }
            }
        }

        return bestPos || Qt.point(posX, posY);
    }

    function formatMode(mode) {
        if (!mode)
            return "";
        return mode.width + "x" + mode.height + "@" + (mode.refresh_rate / 1000).toFixed(3);
    }

    function formatScaleLabel(scale) {
        const value = Number(scale);
        if (!isFinite(value))
            return "1";
        return parseFloat(value.toFixed(2)).toString();
    }

    function getScalePresetValues(outputName, outputData) {
        return [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4];
    }

    function getTransformLabel(transform) {
        switch (transform) {
        case "Normal":
            return I18n.tr("Normal", "display rotation option", true);
        case "90":
            return I18n.tr("90°");
        case "180":
            return I18n.tr("180°");
        case "270":
            return I18n.tr("270°");
        case "Flipped":
            return I18n.tr("Flipped");
        case "Flipped90":
            return I18n.tr("Flipped 90°");
        case "Flipped180":
            return I18n.tr("Flipped 180°");
        case "Flipped270":
            return I18n.tr("Flipped 270°");
        default:
            return I18n.tr("Normal", "display rotation option", true);
        }
    }

    function getTransformValue(label) {
        if (label === I18n.tr("Normal", "display rotation option", true))
            return "Normal";
        if (label === I18n.tr("90°"))
            return "90";
        if (label === I18n.tr("180°"))
            return "180";
        if (label === I18n.tr("270°"))
            return "270";
        if (label === I18n.tr("Flipped"))
            return "Flipped";
        if (label === I18n.tr("Flipped 90°"))
            return "Flipped90";
        if (label === I18n.tr("Flipped 180°"))
            return "Flipped180";
        if (label === I18n.tr("Flipped 270°"))
            return "Flipped270";
        return "Normal";
    }

    function setOriginalDisplayNameMode(mode) {
        if (originalDisplayNameMode === "")
            originalDisplayNameMode = mode;
    }
}
