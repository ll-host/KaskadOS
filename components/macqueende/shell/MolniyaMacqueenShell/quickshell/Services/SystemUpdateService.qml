pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Services

Singleton {
    id: root

    property int refCount: 0

    property bool sysupdateAvailable: false

    property var availableUpdates: []
    property var _rawUpdates: []
    property bool isChecking: false
    property bool isUpgrading: false
    property bool hasError: false
    property string errorMessage: ""
    property string errorHint: ""
    property string errorCode: ""
    property var backends: []
    property string distribution: ""
    property string distributionPretty: ""
    property string pkgManager: ""
    property bool distributionSupported: false
    property var recentLog: []
    property int intervalSeconds: 1800
    property int lastCheckUnix: 0
    property int nextCheckUnix: 0
    property string operationStage: ""
    property int upgradeAttempt: 0
    property int upgradeMaxAttempts: 0
    property int upgradeCompletedUnix: 0
    property string desktopVersion: ""
    property string previousDesktopVersion: ""
    property bool desktopUpdated: false
    property bool restartSessionRequired: false
    property string journalPath: ""
    property bool _stateInitialized: false
    property bool _automaticCheckPending: false
    property bool _automaticUpgradeRunning: false
    property bool _schedulePromptIssued: false
    property bool _idleForMaintenance: false

    signal scheduleConfirmationRequested

    readonly property int updateCount: availableUpdates.length
    readonly property int automaticUpdateCount: availableUpdates.filter(pkg => {
        if (pkg.repo === "flatpak")
            return SettingsData.updaterIncludeFlatpak;
        return pkg.repo === "system" || pkg.repo === "ostree";
    }).length
    readonly property bool helperAvailable: sysupdateAvailable && backends.length > 0
    readonly property bool useCustomCommand: SettingsData.updaterUseCustomCommand && (SettingsData.updaterCustomCommand || "").trim().length > 0
    readonly property string operationLabel: {
        switch (operationStage) {
        case "preparing":
            return "Подготовка обновления";
        case "installing":
            return upgradeAttempt > 1
                ? "Повторная установка обновлений"
                : "Установка обновлений";
        case "verifying":
            return "Проверка результата";
        case "waiting-retry":
            return "Повтор после временной ошибки";
        case "complete":
            return "Обновление завершено";
        case "failed":
            return "Обновление не завершено";
        default:
            return "";
        }
    }

    // Dont allow partial updates on arch, if they wanna break their system they can do it outside of DMS:
    // https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported
    // AUR/Flatpak packages stay ignorable — holding those cannot break the repo dependency graph.
    readonly property bool systemHoldsAllowed: !["pacman", "paru", "yay"].includes(pkgManager)

    function canIgnorePackage(pkg) {
        if (!pkg)
            return false;
        return systemHoldsAllowed || pkg.repo !== "system";
    }

    Connections {
        target: DMSService
        function onCapabilitiesReceived() {
            root.checkCapabilities();
        }
        function onConnectionStateChanged() {
            if (DMSService.isConnected) {
                root.checkCapabilities();
            } else {
                root.sysupdateAvailable = false;
                root._startupCheckDone = false;
            }
            Qt.callLater(() => root._maybeStartupCheck());
        }
        function onSysupdateStateUpdate(data) {
            root._applyState(data);
        }
    }

    Connections {
        target: SettingsData
        function onUpdaterCheckOnStartChanged() {
            Qt.callLater(() => root._maybeStartupCheck());
        }
        function onUpdaterAllowAURChanged() {
            root._refilter();
        }
        function onUpdaterIgnoredPackagesChanged() {
            root._refilter();
        }
        function onUpdaterAutomaticEnabledChanged() {
            root._syncAcquire();
            root._evaluateAutomaticSchedule();
        }
        function onUpdaterScheduleConfirmedChanged() {
            root._maybeRequestScheduleConfirmation();
            root._evaluateAutomaticSchedule();
        }
        function onUpdaterIdleMinutesChanged() {
            maintenanceIdleMonitor.enabled = false;
            Qt.callLater(() => maintenanceIdleMonitor.enabled = SettingsData.updaterAutomaticEnabled && SettingsData.updaterIdleFallbackEnabled);
        }
        function onUpdaterIdleFallbackEnabledChanged() {
            maintenanceIdleMonitor.enabled = SettingsData.updaterAutomaticEnabled && SettingsData.updaterIdleFallbackEnabled;
            root._evaluateAutomaticSchedule();
        }
        function on_HasLoadedChanged() {
            Qt.callLater(() => root._maybeStartupCheck());
            Qt.callLater(() => root._maybeRequestScheduleConfirmation());
            Qt.callLater(() => root._evaluateAutomaticSchedule());
        }
    }

    Component.onCompleted: {
        if (DMSService.dmsAvailable) {
            checkCapabilities();
        }
        Qt.callLater(() => root._maybeStartupCheck());
        Qt.callLater(() => root._maybeRequestScheduleConfirmation());
        Qt.callLater(() => root._evaluateAutomaticSchedule());
    }

    Timer {
        interval: 60000
        repeat: true
        running: SettingsData.updaterAutomaticEnabled
        triggeredOnStart: true
        onTriggered: root._evaluateAutomaticSchedule()
    }

    IdleMonitor {
        id: maintenanceIdleMonitor
        timeout: Math.max(60, SettingsData.updaterIdleMinutes * 60)
        respectInhibitors: true
        enabled: SettingsData.updaterAutomaticEnabled && SettingsData.updaterIdleFallbackEnabled
        onIsIdleChanged: {
            root._idleForMaintenance = isIdle;
            if (isIdle)
                root._evaluateAutomaticSchedule();
        }
    }

    function checkCapabilities() {
        if (!DMSService.capabilities || !Array.isArray(DMSService.capabilities)) {
            sysupdateAvailable = false;
            Qt.callLater(() => root._maybeStartupCheck());
            return;
        }
        const has = DMSService.capabilities.includes("sysupdate");
        if (has && !sysupdateAvailable) {
            sysupdateAvailable = true;
            requestState();
        } else if (!has) {
            sysupdateAvailable = false;
        }
        Qt.callLater(() => root._maybeStartupCheck());
    }

    function requestState() {
        if (!DMSService.isConnected || !sysupdateAvailable) {
            return;
        }
        DMSService.sysupdateGetState(resp => {
            if (resp && resp.result) {
                _applyState(resp.result);
            }
        });
    }

    function _applyState(data) {
        if (!data) {
            return;
        }
        const previousCompletion = upgradeCompletedUnix;
        const wasInitialized = _stateInitialized;
        backends = data.backends || [];
        const systemBackend = backends.find(b => b.repo === "system" || b.repo === "ostree");
        pkgManager = systemBackend ? systemBackend.id : (backends.length > 0 ? backends[0].id : "");
        _rawUpdates = data.packages || [];
        availableUpdates = _filterUpdates(_rawUpdates);
        distribution = data.distro || "";
        distributionPretty = data.distroPretty || "";
        distributionSupported = (backends.length > 0);
        recentLog = data.recentLog || [];
        intervalSeconds = data.intervalSeconds || 1800;
        lastCheckUnix = data.lastCheckUnix || 0;
        nextCheckUnix = data.nextCheckUnix || 0;
        operationStage = data.operationStage || "";
        upgradeAttempt = data.upgradeAttempt || 0;
        upgradeMaxAttempts = data.upgradeMaxAttempts || 0;
        upgradeCompletedUnix = data.upgradeCompletedUnix || 0;
        desktopVersion = data.desktopVersion || "";
        previousDesktopVersion = data.previousDesktopVersion || "";
        desktopUpdated = data.desktopUpdated === true;
        restartSessionRequired = data.restartSessionRequired === true;
        journalPath = data.journalPath || "";

        const phase = data.phase || "idle";
        switch (phase) {
        case "refreshing":
            isChecking = true;
            isUpgrading = false;
            break;
        case "upgrading":
        case "verifying":
        case "retrying":
            isChecking = false;
            isUpgrading = true;
            break;
        default:
            isChecking = false;
            isUpgrading = false;
        }

        if (data.error) {
            hasError = true;
            errorMessage = data.error.message || "";
            errorCode = data.error.code || "";
            errorHint = data.error.hint || "";
        } else {
            hasError = false;
            errorMessage = "";
            errorCode = "";
            errorHint = "";
        }

        _stateInitialized = true;
        if (wasInitialized && upgradeCompletedUnix > 0 && upgradeCompletedUnix !== previousCompletion) {
            if (_automaticUpgradeRunning) {
                SettingsData.set("updaterLastAutomaticUnix", upgradeCompletedUnix);
                SettingsData.set("updaterPostponedUntilUnix", 0);
                _automaticUpgradeRunning = false;
            }
            if (desktopUpdated) {
                const suffix = restartSessionRequired
                    ? " Новая версия включится после выхода из сеанса и повторного входа."
                    : "";
                ToastService.showInfo("MacqueenDE обновлён до версии " + desktopVersion + "." + suffix,
                                      "", "", "desktop-update");
            } else {
                ToastService.showInfo("Система успешно обновлена.", "", "", "system-update");
            }
        }

        if (_automaticCheckPending && !isChecking) {
            _automaticCheckPending = false;
            if (hasError) {
                _postponeAutomatic(15);
            } else if (automaticUpdateCount === 0) {
                SettingsData.set("updaterLastAutomaticUnix", Math.floor(Date.now() / 1000));
                SettingsData.set("updaterPostponedUntilUnix", 0);
            } else {
                Qt.callLater(() => root._startAutomaticUpgradeIfReady());
            }
        }

        if (_automaticUpgradeRunning && !isUpgrading && hasError) {
            _automaticUpgradeRunning = false;
            _postponeAutomatic(15);
            ToastService.showWarning("Автоматическое обновление будет повторено через 15 минут.", "", "", "automatic-update");
        }
    }

    function _filterUpdates(pkgs) {
        const ignored = SettingsData.updaterIgnoredPackages || [];
        return (pkgs || []).filter(p => {
            if (!SettingsData.updaterAllowAUR && p.repo === "aur")
                return false;
            if (!canIgnorePackage(p))
                return true;
            return ignored.indexOf(p.name) === -1;
        });
    }

    function _refilter() {
        availableUpdates = _filterUpdates(_rawUpdates);
    }

    function ignorePackage(name) {
        if (!name)
            return;
        const list = (SettingsData.updaterIgnoredPackages || []).slice();
        if (list.indexOf(name) !== -1)
            return;
        list.push(name);
        SettingsData.set("updaterIgnoredPackages", list);
    }

    function unignorePackage(name) {
        if (!name)
            return;
        const list = (SettingsData.updaterIgnoredPackages || []).filter(p => p !== name);
        SettingsData.set("updaterIgnoredPackages", list);
    }

    function checkForUpdates() {
        DMSService.sysupdateRefresh(false, null);
    }

    function runUpdates(opts, callback) {
        const params = opts || {};
        params.ignored = SettingsData.updaterIgnoredPackages || [];
        if (useCustomCommand) {
            params.customCommand = SettingsData.updaterCustomCommand.trim();
            const termArgs = (SettingsData.updaterTerminalAdditionalParams || "").trim();
            if (termArgs.length > 0) {
                params.terminalArgs = termArgs.split(/\s+/);
            }
        }
        DMSService.sysupdateUpgrade(params, callback || null);
    }

    function _maybeRequestScheduleConfirmation() {
        if (!SettingsData._hasLoaded || SettingsData.updaterScheduleConfirmed || _schedulePromptIssued)
            return;
        _schedulePromptIssued = true;
        scheduleConfirmationRequested();
    }

    function confirmDefaultSchedule() {
        SettingsData.set("updaterScheduleConfirmed", true);
        SettingsData.set("updaterAutomaticEnabled", true);
        SettingsData.set("updaterPostponedUntilUnix", 0);
        _evaluateAutomaticSchedule();
    }

    function postponeAutomatic(minutes) {
        _postponeAutomatic(Math.max(1, minutes));
    }

    function _postponeAutomatic(minutes) {
        const until = Math.floor(Date.now() / 1000) + minutes * 60;
        SettingsData.set("updaterPostponedUntilUnix", until);
    }

    function _scheduledMomentAfter(lastUnix) {
        const now = new Date();
        const days = Math.max(1, SettingsData.updaterScheduleDays);
        if (!lastUnix || lastUnix <= 0) {
            const first = new Date(now.getFullYear(), now.getMonth(), now.getDate(),
                                   SettingsData.updaterScheduleHour,
                                   SettingsData.updaterScheduleMinute, 0, 0);
            return Math.max(Math.floor(first.getTime() / 1000), _scheduleStartUnix());
        }
        const last = new Date(lastUnix * 1000);
        return Math.floor(new Date(last.getFullYear(), last.getMonth(), last.getDate() + days,
                                   SettingsData.updaterScheduleHour,
                                   SettingsData.updaterScheduleMinute, 0, 0).getTime() / 1000);
    }

    function _scheduleStartUnix() {
        const value = String(SettingsData.updaterScheduleStartDate || "").trim();
        const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
        if (!match)
            return 0;
        const year = Number(match[1]);
        const month = Number(match[2]) - 1;
        const day = Number(match[3]);
        const date = new Date(year, month, day,
                              SettingsData.updaterScheduleHour,
                              SettingsData.updaterScheduleMinute, 0, 0);
        if (date.getFullYear() !== year || date.getMonth() !== month || date.getDate() !== day)
            return 0;
        return Math.floor(date.getTime() / 1000);
    }

    function _automaticDue(nowUnix) {
        if (_scheduleStartUnix() > nowUnix)
            return false;
        if (SettingsData.updaterPostponedUntilUnix > nowUnix)
            return false;
        if (nowUnix >= _scheduledMomentAfter(SettingsData.updaterLastAutomaticUnix))
            return true;
        if (!SettingsData.updaterIdleFallbackEnabled || !_idleForMaintenance)
            return false;
        const lastUnix = SettingsData.updaterLastAutomaticUnix;
        if (!lastUnix || lastUnix <= 0)
            return true;
        const last = new Date(lastUnix * 1000);
        const now = new Date(nowUnix * 1000);
        const lastDay = new Date(last.getFullYear(), last.getMonth(), last.getDate());
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
        const elapsedDays = Math.floor((today.getTime() - lastDay.getTime()) / 86400000);
        return elapsedDays >= Math.max(1, SettingsData.updaterScheduleDays);
    }

    function _maintenancePowerReady() {
        if (!SettingsData.updaterOnlyOnAC || !BatteryService.batteryAvailable)
            return true;
        return BatteryService.isPluggedIn;
    }

    function _maintenanceIdleReady() {
        if (!SettingsData.updaterIdleFallbackEnabled)
            return true;
        return _idleForMaintenance && !IdleService.mediaPlaying;
    }

    function _evaluateAutomaticSchedule() {
        if (!SettingsData._hasLoaded || !SettingsData.updaterAutomaticEnabled || !SettingsData.updaterScheduleConfirmed)
            return;
        if (!DMSService.isConnected || !sysupdateAvailable || isChecking || isUpgrading)
            return;
        const nowUnix = Math.floor(Date.now() / 1000);
        if (!_automaticDue(nowUnix) || !_maintenancePowerReady() || !_maintenanceIdleReady())
            return;
        if (lastCheckUnix > 0 && nowUnix - lastCheckUnix < 15 * 60) {
            _startAutomaticUpgradeIfReady();
            return;
        }
        _automaticCheckPending = true;
        DMSService.sysupdateRefresh(true, response => {
            if (response?.error) {
                _automaticCheckPending = false;
                _postponeAutomatic(15);
            }
        });
    }

    function _startAutomaticUpgradeIfReady() {
        if (isChecking || isUpgrading || !_maintenancePowerReady() || !_maintenanceIdleReady())
            return;
        if (automaticUpdateCount === 0) {
            SettingsData.set("updaterLastAutomaticUnix", Math.floor(Date.now() / 1000));
            return;
        }
        _automaticUpgradeRunning = true;
        ToastService.showInfo("Начинаю автоматическое обновление KaskadOS.", "Системой можно продолжать пользоваться.", "", "automatic-update");
        runUpdates({
            "automatic": true,
            "includeFlatpak": SettingsData.updaterIncludeFlatpak,
            "includeAUR": false
        }, response => {
            if (response?.error) {
                _automaticUpgradeRunning = false;
                _postponeAutomatic(15);
                ToastService.showWarning("Не удалось начать обновление. Повторю через 15 минут.", "", "", "automatic-update");
            }
        });
    }

    function cancelUpdates() {
        DMSService.sysupdateCancel(null);
    }

    function setInterval(seconds) {
        DMSService.sysupdateSetInterval(seconds, null);
    }

    property bool _startupCheckDone: false

    function _maybeStartupCheck() {
        if (refCount <= 0) {
            _startupCheckDone = false;
            return;
        }
        if (!SettingsData.updaterCheckOnStart)
            return;
        if (_startupCheckDone)
            return;
        if (!DMSService.isConnected || !sysupdateAvailable)
            return;
        _startupCheckDone = true;
        Qt.callLater(() => root.checkForUpdates());
    }

    onRefCountChanged: {
        if (refCount <= 0)
            _startupCheckDone = false;
        _syncAcquire();
        Qt.callLater(() => root._maybeStartupCheck());
    }
    onSysupdateAvailableChanged: _syncAcquire()

    property bool _acquired: false

    function _syncAcquire() {
        const want = (refCount > 0 || SettingsData.updaterAutomaticEnabled) && sysupdateAvailable;
        if (want === _acquired) {
            return;
        }
        _acquired = want;
        if (want) {
            DMSService.sysupdateAcquire(null);
            return;
        }
        DMSService.sysupdateRelease(null);
    }
}
