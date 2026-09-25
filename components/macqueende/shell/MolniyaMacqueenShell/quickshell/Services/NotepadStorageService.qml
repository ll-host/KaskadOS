pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import QtCore
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root
    readonly property var log: Log.scoped("NotepadStorageService")

    property int refCount: 0

    readonly property string baseDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/MolniyaMacqueenShell")
    readonly property string filesDir: baseDir + "/notepad-files"
    readonly property string metadataPath: baseDir + "/notepad-session.json"

    property var tabs: []
    property int currentTabIndex: 0
    property var tabsBeingCreated: ({})
    property bool metadataLoaded: false

    // Shared live edit state across slideout and popout surfaces.
    property var sessionBuffers: ({})
    property int sessionBufferRevision: 0

    function setSessionBuffer(tabId, content, baseline) {
        if (tabId === undefined || tabId === null || tabId < 0)
            return;
        var next = Object.assign({}, sessionBuffers);
        if (content !== baseline) {
            next[tabId] = {
                content: content,
                baseline: baseline
            };
        } else {
            delete next[tabId];
        }
        sessionBuffers = next;
        sessionBufferRevision++;
    }

    function getSessionBuffer(tabId) {
        return sessionBuffers[tabId];
    }

    function clearSessionBuffer(tabId) {
        if (sessionBuffers[tabId] === undefined)
            return;
        var next = Object.assign({}, sessionBuffers);
        delete next[tabId];
        sessionBuffers = next;
        sessionBufferRevision++;
    }

    property var conflictTabId: -1
    property string conflictDiskContent: ""

    function flagConflict(tabId, diskContent) {
        conflictDiskContent = diskContent;
        conflictTabId = tabId;
    }

    function clearConflict() {
        conflictTabId = -1;
        conflictDiskContent = "";
    }

    Component.onCompleted: {
        ensureDirectories();
    }

    FileView {
        id: metadataFile
        path: root.refCount > 0 ? root.metadataPath : ""
        blockWrites: true
        atomicWrites: true

        onLoaded: {
            try {
                var data = JSON.parse(text());
                root.tabs = data.tabs || [];
                root.currentTabIndex = data.currentTabIndex || 0;
                root.metadataLoaded = true;
                root.validateTabs();
            } catch (e) {
                log.warn("Failed to parse notepad metadata:", e);
                root.createDefaultTab();
            }
        }

        onLoadFailed: {
            root.createDefaultTab();
        }
    }

    onRefCountChanged: {
        if (refCount === 1 && !metadataLoaded) {
            metadataFile.path = "";
            metadataFile.path = root.metadataPath;
        }
    }

    function ensureDirectories() {
        Proc.runCommand("", ["mkdir", "-p", root.baseDir, root.filesDir], null);
    }

    function loadMetadata() {
        metadataFile.path = "";
        metadataFile.path = root.metadataPath;
    }

    function createDefaultTab() {
        var id = Date.now();
        var filePath = "notepad-files/untitled-" + id + ".txt";
        var fullPath = baseDir + "/" + filePath;

        var newTabsBeingCreated = Object.assign({}, tabsBeingCreated);
        newTabsBeingCreated[id] = true;
        tabsBeingCreated = newTabsBeingCreated;

        root.createEmptyFile(fullPath, function () {
            root.tabs = [
                {
                    id: id,
                    title: I18n.tr("Untitled"),
                    filePath: filePath,
                    isTemporary: true,
                    lastModified: new Date().toISOString(),
                    cursorPosition: 0,
                    scrollPosition: 0,
                    annotations: emptyAnnotations()
                }
            ];
            root.currentTabIndex = 0;

            var updatedTabsBeingCreated = Object.assign({}, tabsBeingCreated);
            delete updatedTabsBeingCreated[id];
            tabsBeingCreated = updatedTabsBeingCreated;
            root.saveMetadata();
        });
    }

    function saveMetadata() {
        var metadata = {
            version: 1,
            currentTabIndex: currentTabIndex,
            tabs: tabs
        };
        metadataFile.setText(JSON.stringify(metadata, null, 2));
    }

    function getTabById(tabId) {
        for (var i = 0; i < tabs.length; i++) {
            if (tabs[i].id === tabId)
                return tabs[i];
        }
        return null;
    }

    function tabIndexById(tabId) {
        for (var i = 0; i < tabs.length; i++) {
            if (tabs[i].id === tabId)
                return i;
        }
        return -1;
    }

    function loadTabContent(tabIndex, callback) {
        if (tabIndex < 0 || tabIndex >= tabs.length) {
            callback("");
            return;
        }

        var tab = tabs[tabIndex];
        var requestTabId = tab.id;
        var fullPath = tab.isTemporary ? baseDir + "/" + tab.filePath : tab.filePath;

        if (tabsBeingCreated[tab.id]) {
            Qt.callLater(() => {
                loadTabContent(tabIndex, callback);
            });
            return;
        }

        Proc.runCommand("", ["test", "-f", fullPath], (output, exitCode) => {
            var currentTab = root.getTabById(requestTabId);
            var currentPath = currentTab ? (currentTab.isTemporary ? baseDir + "/" + currentTab.filePath : currentTab.filePath) : "";

            if (!currentTab || currentPath !== fullPath) {
                callback("");
                return;
            }

            if (exitCode === 0) {
                tabFileLoaderComponent.createObject(root, {
                    path: fullPath,
                    callback: callback
                });
            } else {
                log.warn("Tab file does not exist:", fullPath);
                callback("");
            }
        });
    }

    function saveTabContent(tabIndex, content) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        var tab = tabs[tabIndex];
        var fullPath = tab.isTemporary ? baseDir + "/" + tab.filePath : tab.filePath;

        var saver = tabFileSaverComponent.createObject(root, {
            path: fullPath,
            content: content,
            tabIndex: tabIndex
        });
    }

    function createNewTab() {
        var id = Date.now();
        var filePath = "notepad-files/untitled-" + id + ".txt";
        var fullPath = baseDir + "/" + filePath;

        var newTab = {
            id: id,
            title: I18n.tr("Untitled"),
            filePath: filePath,
            isTemporary: true,
            lastModified: new Date().toISOString(),
            cursorPosition: 0,
            scrollPosition: 0,
            annotations: emptyAnnotations()
        };

        var newTabsBeingCreated = Object.assign({}, tabsBeingCreated);
        newTabsBeingCreated[id] = true;
        tabsBeingCreated = newTabsBeingCreated;
        createEmptyFile(fullPath, function () {
            var newTabs = tabs.slice();
            newTabs.push(newTab);
            tabs = newTabs;
            currentTabIndex = tabs.length - 1;

            var updatedTabsBeingCreated = Object.assign({}, tabsBeingCreated);
            delete updatedTabsBeingCreated[id];
            tabsBeingCreated = updatedTabsBeingCreated;
            saveMetadata();
        });

        return newTab;
    }

    function createTabForFile(path) {
        var id = Date.now();
        var fileName = path.split('/').pop();

        var newTab = {
            id: id,
            title: fileName,
            filePath: path,
            isTemporary: false,
            lastModified: new Date().toISOString(),
            cursorPosition: 0,
            scrollPosition: 0,
            annotations: emptyAnnotations()
        };

        var newTabs = tabs.slice();
        newTabs.push(newTab);
        tabs = newTabs;
        currentTabIndex = tabs.length - 1;
        saveMetadata();

        return newTab;
    }

    function closeTab(tabIndex) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        var newTabs = tabs.slice();
        var closedTabId = newTabs[tabIndex] ? newTabs[tabIndex].id : -1;
        clearSessionBuffer(closedTabId);
        if (conflictTabId === closedTabId)
            clearConflict();

        if (newTabs.length <= 1) {
            var id = Date.now();
            var filePath = "notepad-files/untitled-" + id + ".txt";

            var newTabsBeingCreated = Object.assign({}, tabsBeingCreated);
            newTabsBeingCreated[id] = true;
            tabsBeingCreated = newTabsBeingCreated;
            createEmptyFile(baseDir + "/" + filePath, function () {
                newTabs[0] = {
                    id: id,
                    title: I18n.tr("Untitled"),
                    filePath: filePath,
                    isTemporary: true,
                    lastModified: new Date().toISOString(),
                    cursorPosition: 0,
                    scrollPosition: 0,
                    annotations: emptyAnnotations()
                };
                currentTabIndex = 0;
                tabs = newTabs;

                var updatedTabsBeingCreated = Object.assign({}, tabsBeingCreated);
                delete updatedTabsBeingCreated[id];
                tabsBeingCreated = updatedTabsBeingCreated;
                saveMetadata();
            });
            return;
        } else {
            var tabToDelete = newTabs[tabIndex];
            if (tabToDelete && tabToDelete.isTemporary) {
                deleteFile(baseDir + "/" + tabToDelete.filePath);
            }

            newTabs.splice(tabIndex, 1);
            if (currentTabIndex >= newTabs.length) {
                currentTabIndex = newTabs.length - 1;
            } else if (currentTabIndex > tabIndex) {
                currentTabIndex -= 1;
            }
        }

        tabs = newTabs;
        saveMetadata();
    }

    function switchToTab(tabIndex) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        currentTabIndex = tabIndex;
        saveMetadata();
    }

    function reorderTab(fromIndex, toIndex) {
        if (fromIndex < 0 || fromIndex >= tabs.length || toIndex < 0 || toIndex >= tabs.length)
            return;
        if (fromIndex === toIndex)
            return;
        var newTabs = tabs.slice();
        var moved = newTabs.splice(fromIndex, 1)[0];
        newTabs.splice(toIndex, 0, moved);
        tabs = newTabs;

        if (currentTabIndex === fromIndex) {
            currentTabIndex = toIndex;
        } else if (fromIndex < currentTabIndex && toIndex >= currentTabIndex) {
            currentTabIndex--;
        } else if (fromIndex > currentTabIndex && toIndex <= currentTabIndex) {
            currentTabIndex++;
        }

        saveMetadata();
    }

    function saveTabAs(tabIndex, userPath) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        var tab = tabs[tabIndex];
        var fileName = userPath.split('/').pop();

        var newTabs = tabs.slice();
        newTabs[tabIndex] = Object.assign({}, tab, {
            title: fileName,
            filePath: userPath,
            isTemporary: false,
            lastModified: new Date().toISOString()
        });
        tabs = newTabs;
        saveMetadata();
        saveDocumentAnnotations(tabIndex, newTabs[tabIndex].annotations || emptyAnnotations());
    }

    function renameTab(tabIndex, newTitle) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        var trimmed = (newTitle || "").trim();
        var tab = tabs[tabIndex];
        if (trimmed.length === 0 || trimmed === tab.title)
            return;
        if (tab.isTemporary) {
            updateTabMetadata(tabIndex, {
                title: trimmed
            });
            return;
        }

        var dir = tab.filePath.substring(0, tab.filePath.lastIndexOf('/') + 1);
        var newPath = dir + trimmed;
        moveFile(tab.filePath, newPath);
        moveFile(tab.filePath + ".kaskad-meta.json", newPath + ".kaskad-meta.json");
        updateTabMetadata(tabIndex, {
            title: trimmed,
            filePath: newPath
        });
    }

    function updateTabMetadata(tabIndex, properties) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        var newTabs = tabs.slice();
        var updatedTab = Object.assign({}, newTabs[tabIndex], properties);
        updatedTab.lastModified = new Date().toISOString();
        newTabs[tabIndex] = updatedTab;
        tabs = newTabs;
        saveMetadata();
    }

    function validateTabs() {
        var validTabs = [];
        for (var i = 0; i < tabs.length; i++) {
            var tab = tabs[i];
            if (!tab.annotations)
                tab = Object.assign({}, tab, { annotations: emptyAnnotations() });
            validTabs.push(tab);
        }
        tabs = validTabs;

        if (tabs.length === 0) {
            root.createDefaultTab();
        }
    }

    function emptyAnnotations() {
        return {
            version: 1,
            colors: [],
            bookmarks: []
        };
    }

    function normalizedAnnotations(value) {
        return {
            version: 1,
            colors: value && Array.isArray(value.colors) ? value.colors : [],
            bookmarks: value && Array.isArray(value.bookmarks) ? value.bookmarks : []
        };
    }

    function documentMetadataPath(tab) {
        if (!tab || tab.isTemporary || !tab.filePath)
            return "";
        return tab.filePath + ".kaskad-meta.json";
    }

    function loadDocumentAnnotations(tabIndex, callback) {
        if (tabIndex < 0 || tabIndex >= tabs.length) {
            callback(emptyAnnotations());
            return;
        }
        const tab = tabs[tabIndex];
        const metadata = documentMetadataPath(tab);
        if (!metadata) {
            callback(tab.annotations || emptyAnnotations());
            return;
        }
        annotationLoaderComponent.createObject(root, {
            path: metadata,
            fallback: tab.annotations || emptyAnnotations(),
            callback: value => callback(normalizedAnnotations(value))
        });
    }

    function saveDocumentAnnotations(tabIndex, annotations) {
        if (tabIndex < 0 || tabIndex >= tabs.length)
            return;
        const normalized = normalizedAnnotations(annotations);
        const tab = tabs[tabIndex];
        const newTabs = tabs.slice();
        newTabs[tabIndex] = Object.assign({}, tab, { annotations: normalized });
        tabs = newTabs;
        saveMetadata();

        const metadata = documentMetadataPath(newTabs[tabIndex]);
        if (!metadata)
            return;
        if ((normalized.colors || []).length === 0 && (normalized.bookmarks || []).length === 0) {
            deleteFile(metadata);
            return;
        }
        annotationSaverComponent.createObject(root, {
            path: metadata,
            content: JSON.stringify(normalized, null, 2)
        });
    }

    function copyImageForDocument(documentPath, sourcePath, callback) {
        if (!documentPath || !sourcePath) {
            callback("", false);
            return;
        }
        const slash = documentPath.lastIndexOf('/');
        const directory = slash >= 0 ? documentPath.substring(0, slash) : ".";
        const fileName = documentPath.substring(slash + 1);
        const dot = fileName.lastIndexOf('.');
        const stem = dot > 0 ? fileName.substring(0, dot) : fileName;
        const assetsName = stem + ".assets";
        const assetsDirectory = directory + "/" + assetsName;
        const sourceName = sourcePath.substring(sourcePath.lastIndexOf('/') + 1).replace(/[\s()]/g, "_");
        const destinationName = Date.now() + "-" + sourceName;
        const destination = assetsDirectory + "/" + destinationName;
        Proc.runCommand("", ["mkdir", "-p", assetsDirectory], (output, exitCode) => {
            if (exitCode !== 0) {
                callback("", false);
                return;
            }
            Proc.runCommand("", ["cp", "--", sourcePath, destination], (copyOutput, copyExitCode) => {
                callback(assetsName + "/" + destinationName, copyExitCode === 0);
            });
        });
    }

    Component {
        id: tabFileLoaderComponent
        FileView {
            property var callback
            blockLoading: true
            preload: true

            onLoaded: {
                callback(text());
                destroy();
            }

            onLoadFailed: {
                callback("");
                destroy();
            }
        }
    }

    Component {
        id: tabFileSaverComponent
        FileView {
            property string content
            property int tabIndex
            property var creationCallback

            blockWrites: false
            atomicWrites: true

            Component.onCompleted: setText(content)

            onSaved: {
                if (tabIndex >= 0) {
                    root.updateTabMetadata(tabIndex, {});
                }
                if (creationCallback) {
                    creationCallback();
                }
                destroy();
            }

            onSaveFailed: {
                log.error("Failed to save tab content");
                if (creationCallback) {
                    creationCallback();
                }
                destroy();
            }
        }
    }

    Component {
        id: annotationLoaderComponent
        FileView {
            property var callback
            property var fallback
            blockLoading: true
            preload: true

            onLoaded: {
                try {
                    callback(JSON.parse(text()));
                } catch (error) {
                    log.warn("Failed to parse notepad annotations:", error);
                    callback(fallback);
                }
                destroy();
            }

            onLoadFailed: {
                callback(fallback);
                destroy();
            }
        }
    }

    Component {
        id: annotationSaverComponent
        FileView {
            property string content
            blockWrites: false
            atomicWrites: true
            Component.onCompleted: setText(content)
            onSaved: destroy()
            onSaveFailed: error => {
                log.error("Failed to save notepad annotations:", error);
                destroy();
            }
        }
    }

    function createEmptyFile(path, callback) {
        var cleanPath = decodeURI(path.toString());

        if (!cleanPath.startsWith("/")) {
            cleanPath = baseDir + "/" + cleanPath;
        }

        Proc.runCommand("", ["touch", cleanPath], (output, exitCode) => {
            if (callback)
                callback();
        });
    }

    function deleteFile(path) {
        Proc.runCommand("", ["rm", "-f", path], null);
    }

    function moveFile(source, destination) {
        Proc.runCommand("", ["mv", source, destination], null);
    }
}
