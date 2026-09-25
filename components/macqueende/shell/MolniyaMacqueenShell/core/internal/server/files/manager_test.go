package files

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFileSystemCompatibility(t *testing.T) {
	tests := map[string]string{
		"ntfs":  "windows",
		"ext4":  "kaskados",
		"btrfs": "kaskados",
		"exfat": "universal",
		"vfat":  "universal",
		"zfs":   "other",
	}
	for fileSystem, expected := range tests {
		if actual := fileSystemCompatibility(fileSystem); actual != expected {
			t.Fatalf("fileSystemCompatibility(%q) = %q, want %q", fileSystem, actual, expected)
		}
	}
}

func TestCollectDevicesSkipsSystemMounts(t *testing.T) {
	root := lsblkDevice{Path: "/dev/sda", Type: "disk", Transport: "usb", Children: []lsblkDevice{
		{Name: "sda1", Path: "/dev/sda1", Type: "part", FileSystem: "vfat", MountPoint: "/boot/efi", Size: "1024"},
		{Name: "sda2", Path: "/dev/sda2", Type: "part", FileSystem: "exfat", MountPoint: "/run/media/test/USB", Size: "2048"},
	}}
	var devices []Device
	collectDevices(root, false, "", &devices)
	if len(devices) != 1 {
		t.Fatalf("got %d devices, want 1", len(devices))
	}
	if devices[0].Path != "/dev/sda2" || devices[0].ParentPath != "/dev/sda" || !devices[0].Removable {
		t.Fatalf("unexpected device: %+v", devices[0])
	}
}

func TestTransferCopiesAndReportsProgress(t *testing.T) {
	root := t.TempDir()
	sourceDir := filepath.Join(root, "source")
	destinationDir := filepath.Join(root, "destination")
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(destinationDir, 0o755); err != nil {
		t.Fatal(err)
	}
	payload := bytes.Repeat([]byte("kaskados"), 256*1024)
	source := filepath.Join(sourceDir, "payload.bin")
	if err := os.WriteFile(source, payload, 0o640); err != nil {
		t.Fatal(err)
	}

	manager := NewManager()
	operation, err := manager.StartTransfer(source, destinationDir, false)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for operation.State == "scanning" || operation.State == "running" {
		if time.Now().After(deadline) {
			t.Fatal("transfer did not finish")
		}
		time.Sleep(5 * time.Millisecond)
		operation, err = manager.Operation(operation.ID)
		if err != nil {
			t.Fatal(err)
		}
	}
	if operation.State != "completed" {
		t.Fatalf("transfer state = %q, error = %q", operation.State, operation.Error)
	}
	if operation.ProcessedBytes != int64(len(payload)) || operation.TotalBytes != int64(len(payload)) {
		t.Fatalf("progress = %d/%d, want %d", operation.ProcessedBytes, operation.TotalBytes, len(payload))
	}
	copied, err := os.ReadFile(filepath.Join(destinationDir, "payload.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(copied, payload) {
		t.Fatal("copied payload differs from source")
	}
}

func TestTrashRestoreAndDeleteOnlyListedEntry(t *testing.T) {
	root := t.TempDir()
	t.Setenv("XDG_DATA_HOME", filepath.Join(root, "data"))
	manager := NewManager()

	restorePath := filepath.Join(root, "restore-me.txt")
	if err := os.WriteFile(restorePath, []byte("restore"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := manager.Trash(restorePath); err != nil {
		t.Fatal(err)
	}
	entries, err := manager.TrashList()
	if err != nil {
		t.Fatal(err)
	}
	var restoreEntry *TrashEntry
	for index := range entries {
		if entries[index].OriginalPath == restorePath {
			restoreEntry = &entries[index]
			break
		}
	}
	if restoreEntry == nil {
		t.Fatal("trashed restore entry was not listed")
	}
	if err := manager.TrashRestore(restoreEntry.Name, restoreEntry.TrashDir); err != nil {
		t.Fatal(err)
	}
	if content, err := os.ReadFile(restorePath); err != nil || string(content) != "restore" {
		t.Fatalf("restored content = %q, error = %v", content, err)
	}

	deletePath := filepath.Join(root, "delete-me.txt")
	if err := os.WriteFile(deletePath, []byte("delete"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := manager.Trash(deletePath); err != nil {
		t.Fatal(err)
	}
	entries, err = manager.TrashList()
	if err != nil {
		t.Fatal(err)
	}
	var deleteEntry *TrashEntry
	for index := range entries {
		if entries[index].OriginalPath == deletePath {
			deleteEntry = &entries[index]
			break
		}
	}
	if deleteEntry == nil {
		t.Fatal("trashed delete entry was not listed")
	}
	entry := *deleteEntry
	if err := manager.TrashDelete(entry.Name, filepath.Join(root, "forged-trash")); err == nil {
		t.Fatal("forged trash directory was accepted")
	}
	if _, err := os.Lstat(entry.Path); err != nil {
		t.Fatalf("forged delete altered the real trash entry: %v", err)
	}
	if err := manager.TrashDelete(entry.Name, entry.TrashDir); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(entry.Path); !os.IsNotExist(err) {
		t.Fatalf("trash payload still exists: %v", err)
	}
}
