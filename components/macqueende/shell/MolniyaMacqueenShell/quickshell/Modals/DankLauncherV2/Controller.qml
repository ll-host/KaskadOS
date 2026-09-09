pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import "Scorer.js" as Scorer
import "ControllerUtils.js" as Utils
import "NavigationHelpers.js" as Nav
import "ItemTransformers.js" as Transform

Item {
    id: root

    property string searchQuery: ""
    property string searchMode: "all"
    property string previousSearchMode: "all"
    property bool autoSwitchedToFiles: false
    property bool isFileSearching: false
    property var sections: []
    property var flatModel: []
    property int selectedFlatIndex: 0
    property var selectedItem: null
    property bool isSearching: false
    property string activePluginId: ""
    property var collapsedSections: ({})
    property bool keyboardNavigationActive: false
    property bool active: false
    property var _modeSectionsCache: ({})
    property bool _queryDrivenSearch: false
    property bool _diskCacheConsumed: false
    property var sectionViewModes: ({})
    property var pluginViewPreferences: ({})
    property int gridColumns: SettingsData.appLauncherGridColumns
    property int viewModeVersion: 0
    property string viewModeContext: "spotlight"
    property bool forceLinearNavigation: false
    property bool explicitQuerySession: false

    signal itemExecuted
    signal searchCompleted
    signal modeChanged(string mode, bool userInitiated)
    signal queryChanged(string query)
    signal viewModeChanged(string sectionId, string mode)
    signal searchQueryRequested(string query)
    signal sectionExpanded(string sectionId)

    Ref {
        service: AppSearchService
    }

    onActiveChanged: {
        ClipboardService.invalidateLauncherSearchCache();
        if (active)
            return;

        SessionData.addLauncherHistory(searchQuery, explicitQuerySession);
        sections = [];
        flatModel = [];
        selectedItem = null;
        _clearModeCache();
    }

    onSearchModeChanged: {
        if (searchMode === "apps") {
            _loadAppFolders();
        } else {
            appFolderId = allAppsFolderId;
            appFolders = [];
        }
    }

    Connections {
        target: SettingsData
        function onSortAppsAlphabeticallyChanged() {
            AppSearchService.invalidateLauncherCache();
            _clearModeCache();
        }
        function onBuiltInPluginSettingsChanged() {
            AppSearchService.invalidateLauncherCache();
            _clearModeCache();
            if (active)
                performSearch();
        }
        function onLauncherAppFoldersChanged() {
            _loadAppFolders();
            _clearModeCache();
            if (active && searchMode === "apps")
                performSearch();
        }
    }

    Connections {
        target: ClipboardService
        function onLauncherSearchReady(query) {
            if (!active)
                return;

            const clipboardBuiltInActive = activePluginId === "dms_clipboard_search";
            if (!clipboardBuiltInActive && !clipboardSearchEnabledInAll())
                return;
            if (!clipboardBuiltInActive && searchMode !== "all")
                return;

            const trimmed = (searchQuery || "").trim();
            if (trimmed.length < 2 && query.length > 0)
                return;
            const triggerMatch = detectTrigger(trimmed);
            const effectiveQuery = clipboardBuiltInActive && triggerMatch.pluginId === "dms_clipboard_search" ? triggerMatch.query : trimmed;
            if (query !== effectiveQuery)
                return;

            root.requestSearch();
        }
    }

    Connections {
        target: AppSearchService
        function onCacheVersionChanged() {
            if (!active)
                return;
            _clearModeCache();
            if (searchMode === "apps") {
                _loadAppFolders();
                performSearch();
            } else if (!searchQuery && searchMode === "all") {
                performSearch();
            }
        }
    }

    Process {
        id: copyProcess
        running: false
        onExited: pasteTimer.start()
    }

    Timer {
        id: pasteTimer
        interval: 200
        repeat: false
        onTriggered: ClipboardService.sendPasteKeystroke()
    }

    function pasteSelected() {
        if (!selectedItem)
            return;
        if (selectedItem.type === "clipboard") {
            if (SettingsData.clipboardEnterToPaste) {
                ClipboardService.copyEntry(selectedItem.data, function () {
                    root.itemExecuted();
                });
            } else {
                ClipboardService.pasteEntry(selectedItem.data, function () {
                    root.itemExecuted();
                });
            }
            return;
        }

    }

    readonly property var sectionDefinitions: [
        {
            id: "favorites",
            title: I18n.tr("Pinned"),
            icon: "push_pin",
            priority: 1,
            defaultViewMode: "list"
        },
        {
            id: "apps",
            title: I18n.tr("Applications"),
            icon: "apps",
            priority: 2,
            defaultViewMode: "list"
        },
        {
            id: "settings",
            title: I18n.tr("Settings", "settings window title"),
            icon: "settings",
            priority: 2.35,
            defaultViewMode: "list"
        },
        {
            id: "clipboard",
            title: I18n.tr("Clipboard"),
            icon: "content_paste",
            priority: 2.45,
            defaultViewMode: "list"
        },
        {
            id: "fallback",
            title: I18n.tr("Commands"),
            icon: "terminal",
            priority: 5,
            defaultViewMode: "list"
        }
    ]

    property int historyIndex: -1
    property string typingBackup: ""

    function navigateHistory(direction) {
        let history = SessionData.launcherQueryHistory;
        if (history.length === 0)
            return;

        if (historyIndex === -1)
            typingBackup = searchQuery;

        let nextIndex = historyIndex + (direction === "up" ? 1 : -1);
        if (nextIndex >= history.length)
            nextIndex = history.length - 1;
        if (nextIndex < -1)
            nextIndex = -1;

        if (nextIndex === historyIndex)
            return;
        historyIndex = nextIndex;

        let targetText = (historyIndex === -1) ? typingBackup : history[historyIndex];

        setSearchQuery(targetText);
        searchQueryRequested(targetText);
    }

    property string fileSearchType: "all"
    property string fileSearchExt: ""
    property string fileSearchFolder: ""
    property string fileSearchSort: "score"

    property string activePluginName: ""
    readonly property string allAppsFolderId: "__all__"
    property string appFolderId: allAppsFolderId
    property var appFolders: []

    function builtInSectionViewPref(sectionId) {
        switch (sectionId) {
        case "clipboard":
            return getPluginViewPref("dms_clipboard_search");
        case "settings":
            return getPluginViewPref("dms_settings_search");
        default:
            return null;
        }
    }

    function getSectionViewMode(sectionId) {
        var builtInPref = builtInSectionViewPref(sectionId);
        if (builtInPref?.enforced)
            return builtInPref.mode;
        if (pluginViewPreferences[sectionId]?.enforced)
            return pluginViewPreferences[sectionId].mode;
        if (sectionViewModes[sectionId])
            return sectionViewModes[sectionId];

        var savedModes = viewModeContext === "appDrawer" ? (SettingsData.appDrawerSectionViewModes || {}) : (SettingsData.spotlightSectionViewModes || {});
        if (savedModes[sectionId])
            return savedModes[sectionId];

        for (var i = 0; i < sectionDefinitions.length; i++) {
            if (sectionDefinitions[i].id === sectionId)
                return sectionDefinitions[i].defaultViewMode || "list";
        }

        if (pluginViewPreferences[sectionId]?.mode)
            return pluginViewPreferences[sectionId].mode;

        return "list";
    }

    function setSectionViewMode(sectionId, mode) {
        if (builtInSectionViewPref(sectionId)?.enforced)
            return;
        if (pluginViewPreferences[sectionId]?.enforced)
            return;
        sectionViewModes = Object.assign({}, sectionViewModes, {
            [sectionId]: mode
        });
        viewModeVersion++;
        if (viewModeContext === "appDrawer") {
            var savedModes = Object.assign({}, SettingsData.appDrawerSectionViewModes || {}, {
                [sectionId]: mode
            });
            SettingsData.appDrawerSectionViewModes = savedModes;
        } else {
            var savedModes = Object.assign({}, SettingsData.spotlightSectionViewModes || {}, {
                [sectionId]: mode
            });
            SettingsData.spotlightSectionViewModes = savedModes;
        }
        viewModeChanged(sectionId, mode);
    }

    function canChangeSectionViewMode(sectionId) {
        if (builtInSectionViewPref(sectionId)?.enforced)
            return false;
        return !pluginViewPreferences[sectionId]?.enforced;
    }

    function canCollapseSection(sectionId) {
        return searchMode === "all" && sectionId !== "apps";
    }

    function setPluginViewPreference(pluginId, mode, enforced) {
        var prefs = Object.assign({}, pluginViewPreferences);
        prefs[pluginId] = {
            mode: mode,
            enforced: enforced || false
        };
        pluginViewPreferences = prefs;
    }

    function applyActivePluginViewPreference(pluginId, isBuiltIn) {
        var sectionId = "plugin_" + pluginId;
        var pref = null;
        if (isBuiltIn) {
            var builtIn = AppSearchService.builtInPlugins[pluginId];
            if (builtIn && builtIn.viewMode) {
                pref = {
                    mode: builtIn.viewMode,
                    enforced: builtIn.viewModeEnforced === true
                };
            }
        }

        if (pref && pref.mode) {
            setPluginViewPreference(sectionId, pref.mode, pref.enforced);
        } else {
            var prefs = Object.assign({}, pluginViewPreferences);
            delete prefs[sectionId];
            pluginViewPreferences = prefs;
        }
    }

    function clearActivePluginViewPreference() {
        var prefs = {};
        for (var key in pluginViewPreferences) {
            if (!key.startsWith("plugin_")) {
                prefs[key] = pluginViewPreferences[key];
            }
        }
        pluginViewPreferences = prefs;
    }

    property int _searchVersion: 0
    property bool _searchPending: false

    // Leading-edge debounce: search immediately when idle, coalesce bursts
    function requestSearch() {
        if (searchDebounce.running) {
            _searchPending = true;
            searchDebounce.restart();
            return;
        }
        _searchPending = false;
        performSearch();
        searchDebounce.restart();
    }

    Timer {
        id: searchDebounce
        interval: 60
        onTriggered: {
            if (!root._searchPending)
                return;
            root._searchPending = false;
            root.performSearch();
        }
    }

    function getOrTransformApp(app) {
        return AppSearchService.getOrTransformApp(app, transformApp);
    }

    function setSearchQuery(query) {
        _searchVersion++;
        _queryDrivenSearch = true;
        searchQuery = query;
        requestSearch();
    }

    function setMode(mode, isAutoSwitch, fileTypeOverride, notPersist) {
        if (mode === "files")
            mode = "all";
        if (searchMode === mode)
            return;
        autoSwitchedToFiles = false;
        searchMode = mode;
        modeChanged(mode, !isAutoSwitch && notPersist !== true);
        performSearch();
    }

    function restorePreviousMode() {
        if (!autoSwitchedToFiles)
            return;
        autoSwitchedToFiles = false;
        searchMode = previousSearchMode;
        modeChanged(previousSearchMode, false);
        performSearch();
    }

    function cycleMode(reverse = false) {
        var modes = ["all", "apps", "store", "installed", "windows"];
        var currentIndex = modes.indexOf(searchMode);
        if (!reverse)
            var nextIndex = (currentIndex + 1) % modes.length;
        else
            var nextIndex = (currentIndex - 1 + modes.length) % modes.length;
        setMode(modes[nextIndex]);
    }

    function reset() {
        searchQuery = "";
        searchMode = "all";
        previousSearchMode = "all";
        autoSwitchedToFiles = false;
        isFileSearching = false;
        fileSearchType = "all";
        fileSearchExt = "";
        fileSearchFolder = "";
        fileSearchSort = "score";
        sections = [];
        flatModel = [];
        selectedFlatIndex = 0;
        selectedItem = null;
        isSearching = false;
        activePluginId = "";
        activePluginName = "";
        appFolderId = allAppsFolderId;
        appFolders = [];
        collapsedSections = {};
        _clearModeCache();
        _queryDrivenSearch = false;
    }

    function setAppFolder(folderId) {
        if (appFolderId === folderId)
            return;
        appFolderId = folderId;
        _queryDrivenSearch = true;
        _clearModeCache();
        performSearch();
    }

    function _normalizedUserAppFolders() {
        const source = SettingsData.launcherAppFolders || [];
        const normalized = [];
        const ids = {};
        for (let i = 0; i < source.length; i++) {
            const folder = source[i];
            const id = String(folder?.id || "").trim();
            const name = String(folder?.name || "").trim();
            if (!id || !name || id === allAppsFolderId || ids[id])
                continue;
            ids[id] = true;
            normalized.push({
                id: id,
                name: name,
                appIds: Array.isArray(folder.appIds) ? Array.from(new Set(folder.appIds.map(value => String(value)).filter(Boolean))) : []
            });
        }
        return normalized;
    }

    function _loadAppFolders() {
        const userFolders = _normalizedUserAppFolders();
        appFolders = [{
            id: allAppsFolderId,
            name: I18n.tr("All"),
            appIds: [],
            system: true
        }].concat(userFolders);
        if (!appFolders.some(folder => folder.id === appFolderId))
            appFolderId = allAppsFolderId;
    }

    function appFolder(folderId) {
        for (let i = 0; i < appFolders.length; i++) {
            if (appFolders[i].id === folderId)
                return appFolders[i];
        }
        return null;
    }

    function createAppFolder(name) {
        const cleanName = String(name || "").trim();
        if (!cleanName)
            return false;
        const folders = _normalizedUserAppFolders();
        if (folders.some(folder => folder.name.toLocaleLowerCase() === cleanName.toLocaleLowerCase()))
            return false;
        const folderId = "folder-" + Date.now().toString(36) + "-" + Math.floor(Math.random() * 1679616).toString(36);
        folders.push({
            id: folderId,
            name: cleanName,
            appIds: []
        });
        SettingsData.launcherAppFolders = folders;
        setAppFolder(folderId);
        return true;
    }

    function renameAppFolder(folderId, name) {
        const cleanName = String(name || "").trim();
        if (!cleanName || folderId === allAppsFolderId)
            return false;
        const folders = _normalizedUserAppFolders();
        if (folders.some(folder => folder.id !== folderId && folder.name.toLocaleLowerCase() === cleanName.toLocaleLowerCase()))
            return false;
        let changed = false;
        for (let i = 0; i < folders.length; i++) {
            if (folders[i].id !== folderId)
                continue;
            folders[i] = Object.assign({}, folders[i], { name: cleanName });
            changed = true;
            break;
        }
        if (changed)
            SettingsData.launcherAppFolders = folders;
        return changed;
    }

    function deleteAppFolder(folderId) {
        if (folderId === allAppsFolderId)
            return;
        const folders = _normalizedUserAppFolders().filter(folder => folder.id !== folderId);
        if (appFolderId === folderId)
            appFolderId = allAppsFolderId;
        SettingsData.launcherAppFolders = folders;
    }

    function moveAppFolder(folderId, offset) {
        const folders = _normalizedUserAppFolders();
        const from = folders.findIndex(folder => folder.id === folderId);
        const to = from + offset;
        if (from < 0 || to < 0 || to >= folders.length)
            return;
        const moved = folders.splice(from, 1)[0];
        folders.splice(to, 0, moved);
        SettingsData.launcherAppFolders = folders;
    }

    function appIsInFolder(folderId, appId) {
        if (!appId || folderId === allAppsFolderId)
            return false;
        const folder = appFolder(folderId);
        return !!folder && folder.appIds.indexOf(String(appId)) !== -1;
    }

    function toggleAppInFolder(folderId, appId) {
        if (!appId || folderId === allAppsFolderId)
            return;
        const folders = _normalizedUserAppFolders();
        for (let i = 0; i < folders.length; i++) {
            if (folders[i].id !== folderId)
                continue;
            const ids = folders[i].appIds.slice();
            const index = ids.indexOf(String(appId));
            if (index === -1)
                ids.push(String(appId));
            else
                ids.splice(index, 1);
            folders[i] = Object.assign({}, folders[i], { appIds: ids });
            SettingsData.launcherAppFolders = folders;
            return;
        }
    }

    function setFileSearchType(type) {
        if (fileSearchType === type)
            return;
        fileSearchType = type;
        SessionData.setLauncherLastFileSearchType(type);
        performFileSearch();
    }

    function setFileSearchExt(ext) {
        if (fileSearchExt === ext)
            return;
        fileSearchExt = ext;
        performFileSearch();
    }

    function setFileSearchFolder(folder) {
        if (fileSearchFolder === folder)
            return;
        fileSearchFolder = folder;
        performFileSearch();
    }

    function setFileSearchSort(sort) {
        if (fileSearchSort === sort)
            return;
        fileSearchSort = sort;
        performFileSearch();
    }

    function preserveSelectionAfterUpdate(forceFirst) {
        if (forceFirst)
            return function () {
                return getFirstItemIndex();
            };
        var previousSelectedId = selectedItem?.id || "";
        return function (newFlatModel) {
            if (!previousSelectedId)
                return getFirstItemIndex();
            for (var i = 0; i < newFlatModel.length; i++) {
                if (!newFlatModel[i].isHeader && newFlatModel[i].item?.id === previousSelectedId)
                    return i;
            }
            return getFirstItemIndex();
        };
    }

    function performSearch() {
        queryChanged(searchQuery);

        var currentVersion = _searchVersion;
        isSearching = true;
        var shouldResetSelection = _queryDrivenSearch;
        _queryDrivenSearch = false;
        var restoreSelection = preserveSelectionAfterUpdate(shouldResetSelection);

        var cachedSections = AppSearchService.getCachedDefaultSections();
        if (!cachedSections && !_diskCacheConsumed && !searchQuery && searchMode === "all") {
            _diskCacheConsumed = true;
            var diskSections = _loadDiskCache();
            if (diskSections) {
                activePluginId = "";
                activePluginName = "";
                clearActivePluginViewPreference();
                for (var i = 0; i < diskSections.length; i++) {
                    if (collapsedSections[diskSections[i].id] !== undefined)
                        diskSections[i].collapsed = collapsedSections[diskSections[i].id];
                }
                _applyHighlights(diskSections, "");
                flatModel = Scorer.flattenSections(diskSections);
                sections = diskSections;
                selectedFlatIndex = restoreSelection(flatModel);
                updateSelectedItem();
                isSearching = false;
                searchCompleted();
                return;
            }
        }

        if (cachedSections && !searchQuery && searchMode === "all") {
            activePluginId = "";
            activePluginName = "";
            clearActivePluginViewPreference();
            var modeCache = _getCachedModeData("all");
            if (modeCache) {
                _applyHighlights(modeCache.sections, "");
                sections = modeCache.sections;
                flatModel = modeCache.flatModel;
            } else {
                var newSections = cachedSections.map(function (s) {
                    var copy = Object.assign({}, s, {
                        items: s.items ? s.items.slice() : []
                    });
                    if (collapsedSections[s.id] !== undefined)
                        copy.collapsed = collapsedSections[s.id];
                    return copy;
                });
                _applyHighlights(newSections, "");
                flatModel = Scorer.flattenSections(newSections);
                sections = newSections;
                _setCachedModeData("all", sections, flatModel);
            }
            selectedFlatIndex = restoreSelection(flatModel);
            updateSelectedItem();
            isSearching = false;
            searchCompleted();
            return;
        }

        var allItems = [];

        var triggerMatch = detectTrigger(searchQuery);
        if (triggerMatch.pluginId) {
            activePluginId = triggerMatch.pluginId;
            activePluginName = getPluginName(triggerMatch.pluginId);
            applyActivePluginViewPreference(triggerMatch.pluginId, true);

            var builtInItems = AppSearchService.getBuiltInLauncherItems(triggerMatch.pluginId, triggerMatch.query);
            for (var j = 0; j < builtInItems.length; j++) {
                builtInItems[j]._preScored = 1000 - j;
                allItems.push(transformBuiltInSearchItem(builtInItems[j], triggerMatch.pluginId));
            }

            var dynamicDefs = buildDynamicSectionDefs(allItems);
            var scoredItems = Scorer.scoreItems(allItems, triggerMatch.query, getFrecencyForItem);
            var sortAlpha = !triggerMatch.query && SettingsData.sortAppsAlphabetically;
            var newSections = Scorer.groupBySection(scoredItems, dynamicDefs, sortAlpha, 500);

            for (var sid in collapsedSections) {
                for (var i = 0; i < newSections.length; i++) {
                    if (newSections[i].id === sid) {
                        newSections[i].collapsed = collapsedSections[sid];
                    }
                }
            }

            _applyHighlights(newSections, triggerMatch.query);
            flatModel = Scorer.flattenSections(newSections);
            sections = newSections;
            selectedFlatIndex = restoreSelection(flatModel);
            updateSelectedItem();

            isSearching = false;
            searchCompleted();
            return;
        }

        activePluginId = "";
        activePluginName = "";
        clearActivePluginViewPreference();

        if (searchMode === "files") {
            var prefixInfo = Utils.parseFileSearchPrefix(searchQuery);
            var fileQuery = prefixInfo ? prefixInfo.query : searchQuery.trim();
            isFileSearching = fileQuery.length >= 2 && DSearchService.dsearchAvailable;
            sections = [];
            flatModel = [];
            selectedFlatIndex = 0;
            selectedItem = null;
            isSearching = false;
            searchCompleted();
            return;
        }

        if (searchMode === "apps") {
            var isFolderFiltered = appFolderId !== allAppsFolderId;
            var cachedSections = AppSearchService.getCachedDefaultSections();
            if (cachedSections && !searchQuery && !isFolderFiltered) {
                var modeCache = _getCachedModeData("apps");
                if (modeCache) {
                    _applyHighlights(modeCache.sections, "");
                    sections = modeCache.sections;
                    flatModel = modeCache.flatModel;
                } else {
                    var appSectionIds = ["favorites", "apps"];
                    var newSections = cachedSections.filter(function (s) {
                        return appSectionIds.indexOf(s.id) !== -1;
                    }).map(function (s) {
                        var copy = Object.assign({}, s, {
                            items: s.items ? s.items.slice() : []
                        });
                        if (collapsedSections[s.id] !== undefined)
                            copy.collapsed = collapsedSections[s.id];
                        return copy;
                    });
                    _applyHighlights(newSections, "");
                    flatModel = Scorer.flattenSections(newSections);
                    sections = newSections;
                    _setCachedModeData("apps", sections, flatModel);
                }
                selectedFlatIndex = restoreSelection(flatModel);
                updateSelectedItem();
                isSearching = false;
                searchCompleted();
                return;
            }

            if (isFolderFiltered) {
                var selectedFolder = appFolder(appFolderId);
                var allowedAppIds = selectedFolder?.appIds || [];
                var folderCandidates = searchApps(searchQuery);
                for (var i = 0; i < folderCandidates.length; i++) {
                    if (allowedAppIds.indexOf(String(folderCandidates[i].id)) !== -1)
                        allItems.push(folderCandidates[i]);
                }
            } else {
                var apps = searchApps(searchQuery);
                for (var i = 0; i < apps.length; i++) {
                    allItems.push(apps[i]);
                }
            }

            var scoredItems = Scorer.scoreItems(allItems, searchQuery, getFrecencyForItem);
            var sortAlpha = !searchQuery && SettingsData.sortAppsAlphabetically;
            var newSections = Scorer.groupBySection(scoredItems, sectionDefinitions, sortAlpha, searchQuery ? 50 : 500);

            for (var sid in collapsedSections) {
                for (var i = 0; i < newSections.length; i++) {
                    if (newSections[i].id === sid) {
                        newSections[i].collapsed = collapsedSections[sid];
                    }
                }
            }

            _applyHighlights(newSections, searchQuery);
            flatModel = Scorer.flattenSections(newSections);
            sections = newSections;
            selectedFlatIndex = restoreSelection(flatModel);
            updateSelectedItem();

            isSearching = false;
            searchCompleted();
            return;
        }


        var apps = searchApps(searchQuery);
        for (var i = 0; i < apps.length; i++) {
            allItems.push(apps[i]);
        }

        if (searchMode === "all") {
            appendSharedAllResults(allItems, searchQuery);
        }

        var dynamicDefs = buildDynamicSectionDefs(allItems);

        if (currentVersion !== _searchVersion) {
            isSearching = false;
            return;
        }

        var scoredItems = Scorer.scoreItems(allItems, searchQuery, getFrecencyForItem);
        var sortAlpha = !searchQuery && SettingsData.sortAppsAlphabetically;
        var newSections = Scorer.groupBySection(scoredItems, dynamicDefs, sortAlpha, searchQuery ? 50 : 500);

        if (currentVersion !== _searchVersion) {
            isSearching = false;
            return;
        }

        for (var i = 0; i < newSections.length; i++) {
            var sid = newSections[i].id;
            if (collapsedSections[sid] !== undefined) {
                newSections[i].collapsed = collapsedSections[sid];
            }
        }

        _applyHighlights(newSections, searchQuery);
        flatModel = Scorer.flattenSections(newSections);
        sections = newSections;

        selectedFlatIndex = restoreSelection(flatModel);
        updateSelectedItem();

        if (!AppSearchService.isCacheValid() && !searchQuery && searchMode === "all") {
            AppSearchService.setCachedDefaultSections(sections, flatModel);
            _saveDiskCache(sections);
        }
        isSearching = false;
        searchCompleted();
    }


    function performFileSearch() {
        if (!DSearchService.dsearchAvailable)
            return;
        var fileQuery = "";
        var effectiveType = fileSearchType || "all";
        var includeFiles = SettingsData.dankLauncherV2IncludeFilesInAll;
        var includeFolders = SettingsData.dankLauncherV2IncludeFoldersInAll;

        if (searchQuery.startsWith("/")) {
            var prefixInfo = Utils.parseFileSearchPrefix(searchQuery);
            fileQuery = prefixInfo ? prefixInfo.query : searchQuery.substring(1).trim();
        } else if (searchMode === "files") {
            fileQuery = searchQuery.trim();
        } else if (searchMode === "all" && (includeFiles || includeFolders)) {
            fileQuery = searchQuery.trim();
            if (includeFiles && !includeFolders)
                effectiveType = "file";
            else if (!includeFiles && includeFolders)
                effectiveType = "dir";
            else
                effectiveType = "all";
        } else {
            return;
        }

        if (fileQuery.length < 2) {
            isFileSearching = false;
            return;
        }

        isFileSearching = true;

        var splitBothTypes = searchMode === "all" && includeFiles && includeFolders && DSearchService.supportsTypeFilter;
        var queryTypes = splitBothTypes ? ["file", "dir"] : [effectiveType];
        var pending = queryTypes.length;
        var aggregatedItems = [];

        for (var t = 0; t < queryTypes.length; t++) {
            var queryType = queryTypes[t];
            var params = {
                limit: 20,
                fuzzy: true,
                sort: fileSearchSort || "score",
                desc: true
            };

            if (DSearchService.supportsTypeFilter) {
                params.type = (queryType && queryType !== "all") ? queryType : "all";
            }
            if (fileSearchExt) {
                params.ext = fileSearchExt;
            }
            if (fileSearchFolder) {
                params.folder = fileSearchFolder;
            }

            DSearchService.search(fileQuery, params, function (response) {
                pending--;
                if (!response.error) {
                    var hits = response.result?.hits || [];
                    for (var i = 0; i < hits.length; i++) {
                        var hit = hits[i];
                        var docTypes = hit.locations?.doc_type;
                        var isDir = docTypes ? !!docTypes["dir"] : false;
                        aggregatedItems.push(transformFileResult({
                            path: hit.id || "",
                            score: hit.score || 0,
                            is_dir: isDir
                        }));
                    }
                }
                if (pending > 0)
                    return;

                isFileSearching = false;
                _applyFileSearchResults(aggregatedItems, effectiveType);
            });
        }
    }

    function _applyFileSearchResults(fileItems, effectiveType) {
        var fileSections = [];
        var showType = effectiveType;
        var filesPriority = 4;
        var foldersPriority = 4.1;

        if (showType === "all" && DSearchService.supportsTypeFilter) {
            var onlyFiles = [];
            var onlyDirs = [];
            for (var j = 0; j < fileItems.length; j++) {
                if (fileItems[j].data?.is_dir)
                    onlyDirs.push(fileItems[j]);
                else
                    onlyFiles.push(fileItems[j]);
            }
            if (onlyFiles.length > 0) {
                fileSections.push({
                    id: "files",
                    title: I18n.tr("Files"),
                    icon: "insert_drive_file",
                    priority: filesPriority,
                    items: onlyFiles,
                    collapsed: collapsedSections["files"] || false,
                    flatStartIndex: 0
                });
            }
            if (onlyDirs.length > 0) {
                fileSections.push({
                    id: "folders",
                    title: I18n.tr("Folders"),
                    icon: "folder",
                    priority: foldersPriority,
                    items: onlyDirs,
                    collapsed: collapsedSections["folders"] || false,
                    flatStartIndex: 0
                });
            }
        } else {
            var filesIcon = showType === "dir" ? "folder" : showType === "file" ? "insert_drive_file" : "folder";
            var filesTitle = showType === "dir" ? I18n.tr("Folders") : I18n.tr("Files");
            var singlePriority = showType === "dir" ? foldersPriority : filesPriority;
            if (fileItems.length > 0) {
                fileSections.push({
                    id: "files",
                    title: filesTitle,
                    icon: filesIcon,
                    priority: singlePriority,
                    items: fileItems,
                    collapsed: collapsedSections["files"] || false,
                    flatStartIndex: 0
                });
            }
        }

        var newSections;
        if (searchMode === "files") {
            newSections = fileSections;
        } else {
            var existingNonFile = sections.filter(function (s) {
                return s.id !== "files" && s.id !== "folders";
            });
            newSections = existingNonFile.concat(fileSections);
        }
        newSections.sort(function (a, b) {
            return a.priority - b.priority;
        });
        _applyHighlights(newSections, searchQuery);
        flatModel = Scorer.flattenSections(newSections);
        sections = newSections;
        selectedFlatIndex = getFirstItemIndex();
        updateSelectedItem();
    }

    function searchApps(query) {
        var apps = AppSearchService.searchApplications(query);
        var items = [];

        for (var i = 0; i < apps.length; i++) {
            items.push(getOrTransformApp(apps[i]));
        }

        var coreApps = AppSearchService.getCoreApps(query);
        for (var i = 0; i < coreApps.length; i++) {
            items.push(transformCoreApp(coreApps[i]));
        }

        return items;
    }

    function transformApp(app) {
        var appId = app.id || app.execString || app.exec || "";
        var override = SessionData.getAppOverride(appId);
        return Transform.transformApp(app, override, [], I18n.tr("Launch"));
    }

    function transformCoreApp(app) {
        return Transform.transformCoreApp(app, I18n.tr("Open"));
    }

    function transformBuiltInLauncherItem(item, pluginId) {
        return Transform.transformBuiltInLauncherItem(item, pluginId, I18n.tr("Open"));
    }

    function transformBuiltInSearchItem(item, pluginId) {
        if (pluginId === "dms_clipboard_search" || item.type === "clipboard") {
            var transformed = transformClipboardEntry(item.data || item);
            if (item._preScored !== undefined)
                transformed._preScored = item._preScored;
            return transformed;
        }
        return transformBuiltInLauncherItem(item, pluginId);
    }

    function transformFileResult(file) {
        return Transform.transformFileResult(file, I18n.tr("Open"), I18n.tr("Open folder"), I18n.tr("Copy path"), I18n.tr("Open in terminal"));
    }

    function transformClipboardEntry(entry) {
        var copyLabel = I18n.tr("Copy");
        var pasteLabel = I18n.tr("Paste");
        var primaryLabel = SettingsData.clipboardEnterToPaste ? pasteLabel : copyLabel;
        var pasteHintLabel = SettingsData.clipboardEnterToPaste ? I18n.tr("Shift+Enter to copy") : I18n.tr("Shift+Enter to paste");
        return Transform.transformClipboardItem(entry, copyLabel, pasteLabel, primaryLabel, I18n.tr("Image"), I18n.tr("Text"), I18n.tr("Pinned"), pasteHintLabel, "", I18n.tr("Clipboard"));
    }

    function builtInLauncherVisibleInAll(pluginId) {
        return SettingsData.getBuiltInPluginSetting(pluginId, "enabled", true) && SettingsData.getBuiltInPluginSetting(pluginId, "allowWithoutTrigger", true);
    }

    function clipboardSearchEnabledInAll() {
        return builtInLauncherVisibleInAll("dms_clipboard_search") && ClipboardService.clipboardAvailable;
    }

    function appendSharedAllResults(allItems, query) {
        if (!query || query.length < 2)
            return;

        if (builtInLauncherVisibleInAll("dms_settings_search")) {
            var settingsItems = AppSearchService.getBuiltInLauncherItems("dms_settings_search", query);
            var settingsLimit = Math.min(settingsItems.length, 8);
            for (var i = 0; i < settingsLimit; i++) {
                settingsItems[i]._preScored = 890 - i;
                allItems.push(transformBuiltInSearchItem(settingsItems[i], "dms_settings_search"));
            }
        }

        if (clipboardSearchEnabledInAll()) {
            var clipboardItems = AppSearchService.getBuiltInLauncherItems("dms_clipboard_search", query);
            var clipboardLimit = Math.min(clipboardItems.length, 8);
            for (var j = 0; j < clipboardLimit; j++) {
                clipboardItems[j]._preScored = 840 - j;
                allItems.push(transformBuiltInSearchItem(clipboardItems[j], "dms_clipboard_search"));
            }
        }
    }

    function detectTrigger(query) {
        if (!query || query.length === 0)
            return {
                pluginId: null,
                query: query
            };

        var builtInTriggers = AppSearchService.getBuiltInLauncherTriggers();
        for (var trigger in builtInTriggers) {
            if (trigger && query.startsWith(trigger)) {
                return {
                    pluginId: builtInTriggers[trigger],
                    query: query.substring(trigger.length).trim(),
                    isBuiltIn: true
                };
            }
        }

        return {
            pluginId: null,
            query: query
        };
    }

    function getPluginName(pluginId) {
        var plugin = AppSearchService.builtInPlugins[pluginId];
        return plugin ? plugin.name : pluginId;
    }

    function getPluginMetadata(pluginId) {
        var builtIn = AppSearchService.builtInPlugins[pluginId];
        if (builtIn) {
            return {
                name: builtIn.name || pluginId,
                icon: builtIn.cornerIcon || "extension"
            };
        }
        return {
            name: pluginId,
            icon: "extension"
        };
    }

    function buildDynamicSectionDefs(items) {
        var baseDefs = sectionDefinitions.map(function (def) {
            return Object.assign({}, def);
        });
        var pluginSections = {};
        var nextPriority = 2.6;

        for (var i = 0; i < items.length; i++) {
            var section = items[i].section;
            if (!section || !section.startsWith("plugin_"))
                continue;
            if (pluginSections[section])
                continue;
            var pluginId = section.substring(7);
            var meta = getPluginMetadata(pluginId);
            var viewPref = getPluginViewPref(pluginId);
            pluginSections[section] = {
                id: section,
                title: meta.name,
                icon: meta.icon,
                priority: nextPriority,
                defaultViewMode: viewPref.mode || "list"
            };
            nextPriority += 0.01;

            if (viewPref.mode)
                setPluginViewPreference(section, viewPref.mode, viewPref.enforced);
        }

        for (var sectionId in pluginSections) {
            baseDefs.push(pluginSections[sectionId]);
        }

        baseDefs.sort(function (a, b) {
            return a.priority - b.priority;
        });
        return baseDefs;
    }

    function getPluginViewPref(pluginId) {
        var builtIn = AppSearchService.builtInPlugins[pluginId];
        if (builtIn && builtIn.viewMode) {
            return {
                mode: builtIn.viewMode,
                enforced: builtIn.viewModeEnforced === true
            };
        }

        return {
            mode: "list",
            enforced: false
        };
    }

    function getFrecencyForItem(item) {
        if (item.type !== "app")
            return null;

        var appId = item.id;
        var usageRanking = AppUsageHistoryData.appUsageRanking || {};

        var idVariants = [appId, appId.replace(".desktop", "")];
        var usageData = null;

        for (var i = 0; i < idVariants.length; i++) {
            if (usageRanking[idVariants[i]]) {
                usageData = usageRanking[idVariants[i]];
                break;
            }
        }

        return {
            usageCount: usageData?.usageCount || 0
        };
    }

    function getFirstItemIndex() {
        return Nav.getFirstItemIndex(flatModel);
    }

    function _getCachedModeData(mode) {
        return _modeSectionsCache[mode] || null;
    }

    function _setCachedModeData(mode, sectionsData, flatModelData) {
        var cache = Object.assign({}, _modeSectionsCache);
        cache[mode] = {
            sections: sectionsData,
            flatModel: flatModelData
        };
        _modeSectionsCache = cache;
    }

    function _clearModeCache() {
        _modeSectionsCache = {};
    }

    function _saveDiskCache(sectionsData) {
        var serializable = [];
        for (var i = 0; i < sectionsData.length; i++) {
            var s = sectionsData[i];
            var items = [];
            var srcItems = s.items || [];
            for (var j = 0; j < srcItems.length; j++) {
                var it = srcItems[j];
                items.push({
                    id: it.id,
                    type: it.type,
                    name: it.name || "",
                    subtitle: it.subtitle || "",
                    icon: it.icon || "",
                    iconType: it.iconType || "image",
                    iconFull: it.iconFull || "",
                    section: it.section || "",
                    isCore: it.isCore || false,
                    isBuiltInLauncher: it.isBuiltInLauncher || false,
                    pluginId: it.pluginId || "",
                    source: it.source || ""
                });
            }
            serializable.push({
                id: s.id,
                title: s.title || "",
                icon: s.icon || "",
                priority: s.priority || 0,
                items: items
            });
        }
        CacheData.saveLauncherCache(serializable);
    }

    function _actionsFromDesktopEntry(appId) {
        if (!appId)
            return [];
        var entry = DesktopEntries.heuristicLookup(appId);
        if (!entry || !entry.actions || entry.actions.length === 0)
            return [];
        var result = [];
        for (var i = 0; i < entry.actions.length; i++) {
            result.push({
                name: entry.actions[i].name,
                icon: "play_arrow",
                actionData: entry.actions[i]
            });
        }
        return result;
    }

    function _loadDiskCache() {
        var cached = CacheData.loadLauncherCache();
        if (!cached || !Array.isArray(cached) || cached.length === 0)
            return null;

        var sectionsData = [];
        for (var i = 0; i < cached.length; i++) {
            var s = cached[i];
            var items = [];
            var srcItems = s.items || [];
            for (var j = 0; j < srcItems.length; j++) {
                var it = srcItems[j];
                items.push({
                    id: it.id || "",
                    type: it.type || "app",
                    name: it.name || "",
                    subtitle: it.subtitle || "",
                    icon: it.icon || "",
                    iconType: it.iconType || "image",
                    iconFull: it.iconFull || "",
                    section: it.section || "",
                    isCore: it.isCore || false,
                    isBuiltInLauncher: it.isBuiltInLauncher || false,
                    pluginId: it.pluginId || "",
                    source: it.source || "",
                    data: {
                        id: it.id
                    },
                    actions: _actionsFromDesktopEntry(it.id),
                    primaryAction: it.type === "app" && !it.isCore ? {
                        name: I18n.tr("Launch"),
                        icon: "open_in_new",
                        action: "launch"
                    } : null,
                    _diskCached: true,
                    _hName: "",
                    _hSub: "",
                    _hRich: false,
                    _preScored: undefined
                });
            }
            sectionsData.push({
                id: s.id || "",
                title: s.title || "",
                icon: s.icon || "",
                priority: s.priority || 0,
                items: items,
                collapsed: false,
                flatStartIndex: 0
            });
        }
        return sectionsData;
    }

    function updateSelectedItem() {
        if (selectedFlatIndex >= 0 && selectedFlatIndex < flatModel.length) {
            var entry = flatModel[selectedFlatIndex];
            selectedItem = entry.isHeader ? null : entry.item;
        } else {
            selectedItem = null;
        }
    }

    function _applyHighlights(sectionsData, query) {
        if (!query || query.length === 0) {
            for (var i = 0; i < sectionsData.length; i++) {
                var items = sectionsData[i].items;
                for (var j = 0; j < items.length; j++) {
                    var item = items[j];
                    item._hName = item.name || "";
                    item._hSub = item.subtitle || "";
                    item._hRich = false;
                }
            }
            return;
        }

        var highlightColor = Theme.primary;
        var nameColor = Theme.surfaceText;
        var subColor = Theme.surfaceVariantText;
        var lowerQuery = query.toLowerCase();

        for (var i = 0; i < sectionsData.length; i++) {
            var items = sectionsData[i].items;
            for (var j = 0; j < items.length; j++) {
                var item = items[j];
                item._hName = _highlightField(item.name || "", lowerQuery, query.length, nameColor, highlightColor);
                item._hSub = _highlightField(item.subtitle || "", lowerQuery, query.length, subColor, highlightColor);
                item._hRich = true;
            }
        }
    }

    function _highlightField(text, lowerQuery, queryLen, baseColor, highlightColor) {
        if (!text)
            return "";
        var idx = text.toLowerCase().indexOf(lowerQuery);
        if (idx === -1)
            return _escapeRichText(text);
        var before = text.substring(0, idx);
        var match = text.substring(idx, idx + queryLen);
        var after = text.substring(idx + queryLen);
        return '<span style="color:' + baseColor + '">' + _escapeRichText(before) + '</span><span style="color:' + highlightColor + '; font-weight:600">' + _escapeRichText(match) + '</span><span style="color:' + baseColor + '">' + _escapeRichText(after) + '</span>';
    }

    function _escapeRichText(text) {
        return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
    }

    function getCurrentSectionViewMode() {
        if (selectedFlatIndex < 0 || selectedFlatIndex >= flatModel.length)
            return "list";
        var entry = flatModel[selectedFlatIndex];
        if (!entry || entry.isHeader)
            return "list";
        return getSectionViewMode(entry.sectionId);
    }

    function getGridColumns(sectionId) {
        return Nav.getGridColumns(getSectionViewMode(sectionId), gridColumns);
    }

    function _cancelPendingSelectionReset() {
        _queryDrivenSearch = false;
    }

    function selectNext() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = forceLinearNavigation ? Nav.findNextNonHeaderIndex(flatModel, selectedFlatIndex + 1) : Nav.calculateNextIndex(flatModel, selectedFlatIndex, null, null, gridColumns, getSectionViewMode);
        if (newIndex === -1)
            newIndex = selectedFlatIndex;
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectPrevious() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = forceLinearNavigation ? Nav.findPrevNonHeaderIndex(flatModel, selectedFlatIndex - 1) : Nav.calculatePrevIndex(flatModel, selectedFlatIndex, null, null, gridColumns, getSectionViewMode);
        if (newIndex === -1)
            newIndex = selectedFlatIndex;
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectRight() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculateRightIndex(flatModel, selectedFlatIndex, getSectionViewMode);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectLeft() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculateLeftIndex(flatModel, selectedFlatIndex, getSectionViewMode);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectNextSection() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculateNextSectionIndex(flatModel, selectedFlatIndex);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectPreviousSection() {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculatePrevSectionIndex(flatModel, selectedFlatIndex);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectPageDown(visibleItems) {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculatePageDownIndex(flatModel, selectedFlatIndex, visibleItems);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectPageUp(visibleItems) {
        keyboardNavigationActive = true;
        _cancelPendingSelectionReset();
        var newIndex = Nav.calculatePageUpIndex(flatModel, selectedFlatIndex, visibleItems);
        if (newIndex !== selectedFlatIndex) {
            selectedFlatIndex = newIndex;
            updateSelectedItem();
        }
    }

    function selectIndex(index) {
        keyboardNavigationActive = false;
        if (index >= 0 && index < flatModel.length && !flatModel[index].isHeader) {
            selectedFlatIndex = index;
            updateSelectedItem();
        }
    }

    function toggleSection(sectionId) {
        if (!canCollapseSection(sectionId))
            return;
        _clearModeCache();
        var newCollapsed = Object.assign({}, collapsedSections);
        var currentState = newCollapsed[sectionId];

        if (currentState === undefined) {
            for (var i = 0; i < sections.length; i++) {
                if (sections[i].id === sectionId) {
                    currentState = sections[i].collapsed || false;
                    break;
                }
            }
        }

        newCollapsed[sectionId] = !currentState;
        collapsedSections = newCollapsed;

        var newSections = sections.slice();
        for (var i = 0; i < newSections.length; i++) {
            if (newSections[i].id === sectionId) {
                newSections[i] = Object.assign({}, newSections[i], {
                    collapsed: newCollapsed[sectionId]
                });
            }
        }
        flatModel = Scorer.flattenSections(newSections);
        sections = newSections;

        if (selectedFlatIndex >= flatModel.length) {
            selectedFlatIndex = getFirstItemIndex();
        }
        updateSelectedItem();

        if (!newCollapsed[sectionId])
            sectionExpanded(sectionId);
    }

    function executeSelected() {
        if (_searchPending) {
            _searchPending = false;
            searchDebounce.stop();
            performSearch();
        }
        if (!selectedItem)
            return;
        executeItem(selectedItem, true);
    }

    function executeItem(item, isKeyboard = false) {
        if (!item)
            return;

        SessionData.addLauncherHistory(searchQuery, explicitQuerySession);

        switch (item.type) {
        case "app":
            if (item.isCore) {
                AppSearchService.executeCoreApp(item.data);
            } else if (item.data?.isAction) {
                launchAppAction(item.data);
            } else {
                launchApp(item.data);
            }
            break;
        case "system_action":
            AppSearchService.executeBuiltInLauncherItem(item.data);
            break;
        case "setting":
            AppSearchService.executeBuiltInLauncherItem(item.data);
            break;
        case "clipboard":
            var shouldPaste = isKeyboard ? SettingsData.clipboardEnterToPaste : SettingsData.clipboardClickToPaste;
            if (shouldPaste) {
                ClipboardService.pasteEntry(item.data, function () {
                    root.itemExecuted();
                });
            } else {
                ClipboardService.copyEntry(item.data, function () {
                    root.itemExecuted();
                });
            }
            return;
        case "file":
            if (item.data?.is_dir)
                FileManagerService.openWindow(item.data?.path);
            else
                openFile(item.data?.path);
            break;
        default:
            return;
        }

        itemExecuted();
    }

    function executeAction(item, action) {
        if (!item || !action)
            return;
        switch (action.action) {
        case "launch":
            executeItem(item);
            break;
        case "open":
            openFile(item.data.path);
            break;
        case "open_folder":
            openFolder(item.data.path);
            break;
        case "copy_path":
            copyToClipboard(item.data.path);
            break;
        case "open_terminal":
            openTerminal(item.data.path);
            break;
        case "copy":
            copyToClipboard(item.name);
            break;
        case "execute":
            executeItem(item);
            break;
        case "clipboard_copy":
            ClipboardService.copyEntry(item.data, function () {
                root.itemExecuted();
            });
            return;
        case "clipboard_paste":
            ClipboardService.pasteEntry(item.data, function () {
                root.itemExecuted();
            });
            return;
        case "launch_dgpu":
            if (item.type === "app" && item.data) {
                launchAppWithNvidia(item.data);
            }
            break;
        default:
            if (item.type === "app" && action.actionData) {
                launchAppAction({
                    parentApp: item.data,
                    actionData: action.actionData
                });
            }
        }

        itemExecuted();
    }

    function _resolveDesktopEntry(app) {
        if (!app)
            return null;
        if (app.command)
            return app;
        var id = app.id || app.execString || app.exec || "";
        if (!id)
            return null;
        return DesktopEntries.heuristicLookup(id);
    }

    function launchApp(app) {
        var entry = _resolveDesktopEntry(app);
        if (!entry)
            return;
        SessionService.launchDesktopEntry(entry);
        AppUsageHistoryData.addAppUsage(entry);
    }

    function launchAppWithNvidia(app) {
        var entry = _resolveDesktopEntry(app);
        if (!entry)
            return;
        SessionService.launchDesktopEntry(entry, true);
        AppUsageHistoryData.addAppUsage(entry);
    }

    function launchAppAction(actionItem) {
        if (!actionItem || !actionItem.actionData)
            return;
        var entry = _resolveDesktopEntry(actionItem.parentApp);
        if (!entry)
            return;
        SessionService.launchDesktopAction(entry, actionItem.actionData);
        AppUsageHistoryData.addAppUsage(entry);
    }

    function openFile(path) {
        if (!path)
            return;
        const lower = path.toLowerCase();
        if (lower.includes(".pkg.tar.")) {
            SoftwareService.installLocal(path);
        } else if (lower.endsWith(".exe")) {
            WindowsAppsService.openExecutable(path);
        } else if (FileManagerService.isArchive(lower)) {
            FileManagerService.extract({
                path: path,
                name: path.substring(path.lastIndexOf("/") + 1)
            });
        } else {
            FileManagerService.openFile(path);
        }
    }

    function openFolder(path) {
        if (!path)
            return;
        var folder = path.substring(0, path.lastIndexOf("/"));
        FileManagerService.openWindow(folder);
    }

    function openTerminal(path) {
        if (!path)
            return;
        var terminal = SessionData.resolveTerminal() || "xterm";
        Quickshell.execDetached({
            command: [terminal],
            workingDirectory: path
        });
    }

    function copyToClipboard(text) {
        if (!text)
            return;
        Quickshell.execDetached(["dms", "cl", "copy", text]);
    }
}
