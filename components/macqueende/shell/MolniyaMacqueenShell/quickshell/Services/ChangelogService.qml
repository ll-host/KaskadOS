pragma Singleton
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

Singleton {
    id: root

    readonly property var log: Log.scoped("ChangelogService")
    readonly property string configDir: Paths.strip(StandardPaths.writableLocation(StandardPaths.ConfigLocation)) + "/MolniyaMacqueenShell"
    readonly property string systemReleasePath: "/usr/share/kaskados/release.json"
    readonly property string bundledReleasePath: Theme.shellDir + "/../../../release/release.json"

    property var releaseData: ({})
    property var releaseNotes: ({})
    property string releaseBaseDir: ""
    property string currentVersion: ""
    property string channel: ""
    property string releaseDate: ""
    property string releaseUrl: ""
    property bool sessionRestartRequired: false
    property bool systemReleaseLoaded: false
    property bool checkStarted: false
    property bool checkComplete: false
    property bool changelogDismissed: false

    readonly property bool changelogEnabled: currentVersion.length > 0
    readonly property string changelogMarkerPath: configDir + "/.changelog-" + currentVersion
    readonly property bool shouldShowChangelog: checkComplete
        && changelogEnabled
        && !changelogDismissed
        && !(typeof FirstLaunchService !== "undefined" && FirstLaunchService.isFirstLaunch)

    signal changelogRequested
    signal changelogCompleted

    function loadRelease(raw, baseDir, fromSystem) {
        try {
            const parsed = JSON.parse(raw);
            if (!parsed || parsed.product !== "MacqueenDE" || !parsed.version)
                throw new Error("invalid MacqueenDE release manifest");
            if (systemReleaseLoaded && !fromSystem)
                return;

            const previousVersion = currentVersion;
            const versionChanged = previousVersion.length > 0 && previousVersion !== String(parsed.version);
            if (versionChanged) {
                checkStarted = false;
                checkComplete = false;
                changelogDismissed = false;
                releaseNotes = ({});
            }

            releaseData = parsed;
            releaseBaseDir = baseDir;
            currentVersion = String(parsed.version || "");
            channel = String(parsed.channel || "");
            releaseDate = String(parsed.releaseDate || "");
            releaseUrl = String(parsed.releaseUrl || "");
            sessionRestartRequired = parsed.sessionRestartRequired === true;
            systemReleaseLoaded = fromSystem;

            const notesPath = String(parsed.releaseNotes || "");
            if (notesPath.length > 0) {
                releaseNotesFile.path = baseDir + "/" + notesPath;
                releaseNotesFile.reload();
            }
            beginCheck();
        } catch (error) {
            log.warn("Failed to parse release manifest: " + error);
        }
    }

    function beginCheck() {
        if (checkStarted || !changelogEnabled || !FirstLaunchService.checkComplete)
            return;
        checkStarted = true;
        handleFirstLaunchResult();
    }

    function handleFirstLaunchResult() {
        if (FirstLaunchService.isFirstLaunch) {
            checkComplete = true;
            changelogDismissed = true;
            touchMarkerProcess.running = true;
        } else {
            changelogCheckProcess.running = true;
        }
    }

    function dismissChangelog() {
        changelogDismissed = true;
        touchMarkerProcess.running = true;
        changelogCompleted();
    }

    Connections {
        target: FirstLaunchService

        function onCheckCompleteChanged() {
            root.beginCheck();
        }
    }

    FileView {
        id: systemReleaseFile

        path: root.systemReleasePath
        blockLoading: true
        watchChanges: false
        onLoaded: root.loadRelease(text(), "/usr/share/kaskados", true)
        onLoadFailed: error => bundledReleaseFile.reload()
    }

    FileView {
        id: bundledReleaseFile

        path: root.bundledReleasePath
        blockLoading: true
        watchChanges: false
        onLoaded: root.loadRelease(text(), root.bundledReleasePath.replace(/\/release\.json$/, ""), false)
        onLoadFailed: error => root.log.warn("MacqueenDE release manifest was not found")
    }

    FileView {
        id: releaseNotesFile

        blockLoading: true
        watchChanges: false
        onLoaded: {
            try {
                const parsed = JSON.parse(text());
                if (String(parsed.version || "") === root.currentVersion)
                    root.releaseNotes = parsed;
            } catch (error) {
                root.log.warn("Failed to parse release notes: " + error);
            }
        }
        onLoadFailed: error => root.log.warn("Release notes were not found for " + root.currentVersion)
    }

    Process {
        id: changelogCheckProcess

        command: ["sh", "-c", "[ -f '" + root.changelogMarkerPath + "' ] && echo 'seen' || echo 'show'"]
        running: false

        stdout: SplitParser {
            onRead: data => {
                root.checkComplete = true;
                if (data.trim() === "seen") {
                    root.changelogDismissed = true;
                } else {
                    root.changelogRequested();
                }
            }
        }
    }

    Process {
        id: touchMarkerProcess

        command: ["sh", "-c", "mkdir -p '" + root.configDir + "' && touch '" + root.changelogMarkerPath + "'"]
        running: false
        onExited: exitCode => {
            if (exitCode !== 0)
                root.log.warn("Failed to create changelog marker");
        }
    }
}
