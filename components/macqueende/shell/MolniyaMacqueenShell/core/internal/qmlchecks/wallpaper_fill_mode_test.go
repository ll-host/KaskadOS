package qmlchecks

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestRussianWallpaperFillModeLabelsAreDistinct(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/translations/poexports/ru.json")
	if err != nil {
		t.Fatalf("read Russian translations: %v", err)
	}

	translations := map[string]map[string]string{}
	if err := json.Unmarshal(raw, &translations); err != nil {
		t.Fatalf("parse Russian translations: %v", err)
	}

	expected := map[string]string{
		"Stretch":           "Растянуть",
		"Fit":               "Вписать целиком",
		"Fill":              "Заполнить с обрезкой",
		"Scroll":            "Прокрутка",
		"Tile":              "Мозаика",
		"Tile Vertically":   "Повторять по вертикали",
		"Tile Horizontally": "Повторять по горизонтали",
		"Pad":               "По центру без увеличения",
	}
	seen := map[string]string{}
	for term, expectedLabel := range expected {
		label := translations[term][term]
		if label != expectedLabel {
			t.Fatalf("Russian wallpaper fill-mode translation for %q = %q, want %q", term, label, expectedLabel)
		}
		if previous, exists := seen[label]; exists {
			t.Fatalf("wallpaper fill modes %q and %q share Russian label %q", previous, term, label)
		}
		seen[label] = term
	}
}

func TestRussianWallpaperBackgroundColorLabels(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/translations/poexports/ru.json")
	if err != nil {
		t.Fatalf("read Russian translations: %v", err)
	}

	translations := map[string]map[string]string{}
	if err := json.Unmarshal(raw, &translations); err != nil {
		t.Fatalf("parse Russian translations: %v", err)
	}

	expected := map[string]string{
		"Background Color": "Цвет свободных полей",
		"Color shown for areas not covered by wallpaper": "Цвет областей, которые обои не закрывают",
		"White":             "Белый",
		"Surface Container": "Фон интерфейса",
	}
	for term, expectedLabel := range expected {
		if label := translations[term][term]; label != expectedLabel {
			t.Fatalf("Russian translation for %q = %q, want %q", term, label, expectedLabel)
		}
	}
}

func TestRussianWallpaperTransitionLabelsAreDistinct(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/translations/poexports/ru.json")
	if err != nil {
		t.Fatalf("read Russian translations: %v", err)
	}

	translations := map[string]map[string]string{}
	if err := json.Unmarshal(raw, &translations); err != nil {
		t.Fatalf("parse Russian translations: %v", err)
	}

	expected := map[string]string{
		"Random":     "Случайный",
		"None":       "Нет",
		"Fade":       "Плавное затухание",
		"Wipe":       "Шторка",
		"Disc":       "Круг",
		"Stripes":    "Полосы",
		"Iris Bloom": "Раскрытие диафрагмы",
		"Pixelate":   "Пикселизация",
		"Portal":     "Портал",
	}
	seen := map[string]string{}
	for term, expectedLabel := range expected {
		label := translations[term][term]
		if label != expectedLabel {
			t.Fatalf("Russian wallpaper transition translation for %q = %q, want %q", term, label, expectedLabel)
		}
		if previous, exists := seen[label]; exists {
			t.Fatalf("wallpaper transitions %q and %q share Russian label %q", previous, term, label)
		}
		seen[label] = term
	}
}

func TestWallpaperBackgroundColorOnlyAppearsForUncoveredAreas(t *testing.T) {
	raw, err := os.ReadFile("../../../quickshell/Modules/Settings/WallpaperTab.qml")
	if err != nil {
		t.Fatalf("read wallpaper settings: %v", err)
	}
	content := string(raw)
	if !strings.Contains(content, `["Fit", "Pad"].includes(fillModeRow.effectiveMode)`) {
		t.Fatal("background color control must only be shown for fill modes that can leave uncovered areas")
	}
}

func TestBuiltInWallpaperCannotBeDisabled(t *testing.T) {
	settingsRaw, err := os.ReadFile("../../../quickshell/Common/SettingsData.qml")
	if err != nil {
		t.Fatalf("read settings data: %v", err)
	}
	settings := string(settingsRaw)
	if !strings.Contains(settings, `if (componentId === "wallpaper") {`) || !strings.Contains(settings, `return Quickshell.screens;`) {
		t.Fatal("wallpaper background must always be created for every connected display")
	}
	if strings.Contains(settings, `componentId === "wallpaper" && Array.isArray(prefs) && prefs.length === 0`) {
		t.Fatal("empty screen preferences must not disable the built-in wallpaper")
	}

	displaysRaw, err := os.ReadFile("../../../quickshell/Modules/Settings/DisplayWidgetsTab.qml")
	if err != nil {
		t.Fatalf("read display widget settings: %v", err)
	}
	if strings.Contains(string(displaysRaw), `"id": "wallpaper"`) {
		t.Fatal("wallpaper must not be exposed as an optional per-screen shell component")
	}

	wallpaperSettingsRaw, err := os.ReadFile("../../../quickshell/Modules/Settings/WallpaperTab.qml")
	if err != nil {
		t.Fatalf("read wallpaper settings: %v", err)
	}
	wallpaperSettings := string(wallpaperSettingsRaw)
	for _, removedSetting := range []string{"disableWallpaper", "disableWallpapers", "External Wallpaper Management", "swww", "hyprpaper", "swaybg"} {
		if strings.Contains(wallpaperSettings, removedSetting) {
			t.Fatalf("wallpaper settings still expose removed external-manager option %q", removedSetting)
		}
	}

	migrationRaw, err := os.ReadFile("../../../quickshell/Common/settings/SettingsStore.js")
	if err != nil {
		t.Fatalf("read settings migrations: %v", err)
	}
	if !strings.Contains(string(migrationRaw), `delete settings.screenPreferences.wallpaper;`) {
		t.Fatal("legacy wallpaper-disable preferences must be removed during migration")
	}
}
