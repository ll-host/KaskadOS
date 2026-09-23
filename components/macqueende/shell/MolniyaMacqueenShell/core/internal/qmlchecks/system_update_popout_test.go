package qmlchecks

import (
	"os"
	"strings"
	"testing"
)

func TestSystemUpdateActionStaysVisibleAbovePackageList(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/Modules/DankBar/Popouts/SystemUpdatePopout.qml")
	if err != nil {
		t.Fatalf("read system update popout: %v", err)
	}
	content := string(raw)

	if !strings.Contains(content, `visible: SystemUpdateService.isUpgrading || SystemUpdateService.updateCount > 0`) {
		t.Fatal("system update action must be visible whenever updates are available")
	}
	if !strings.Contains(content, `anchors.top: checkTimeRow.visible ? checkTimeRow.bottom : header.bottom`) {
		t.Fatal("system update action must be pinned below the header instead of below the package list")
	}
	if !strings.Contains(content, `Обновить всё (${SystemUpdateService.updateCount})`) {
		t.Fatal("system update action must have a clear Update All label with the package count")
	}
}

func TestPrimaryContainerHasDefinedForegroundRole(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/Common/Theme.qml")
	if err != nil {
		t.Fatalf("read theme: %v", err)
	}
	content := string(raw)

	if !strings.Contains(content, `property color primaryContainerText: currentThemeData.primaryContainerText || surfaceText`) {
		t.Fatal("primary containers need a readable theme-aware foreground fallback")
	}
	if !strings.Contains(content, `property color onPrimaryContainer: primaryContainerText`) {
		t.Fatal("onPrimaryContainer must resolve to a defined color role")
	}
}
