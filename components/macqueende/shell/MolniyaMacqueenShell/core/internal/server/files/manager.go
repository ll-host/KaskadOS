package files

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/trash"
)

type Entry struct {
	Name         string `json:"name"`
	Path         string `json:"path"`
	Directory    bool   `json:"directory"`
	SizeBytes    int64  `json:"sizeBytes,omitempty"`
	ModifiedUnix int64  `json:"modifiedUnix,omitempty"`
	MimeType     string `json:"mimeType,omitempty"`
	Hidden       bool   `json:"hidden,omitempty"`
}

type Listing struct {
	Path    string  `json:"path"`
	Parent  string  `json:"parent"`
	Entries []Entry `json:"entries"`
}

type Event struct {
	Show bool   `json:"show"`
	Path string `json:"path"`
}

type TrashEntry struct {
	Name         string `json:"name"`
	OriginalPath string `json:"originalPath"`
	DeletionDate string `json:"deletionDate"`
	TrashDir     string `json:"trashDir"`
	Path         string `json:"path"`
	Directory    bool   `json:"directory"`
	SizeBytes    int64  `json:"sizeBytes,omitempty"`
}

type Device struct {
	Name          string `json:"name"`
	Path          string `json:"path"`
	ParentPath    string `json:"parentPath,omitempty"`
	Label         string `json:"label"`
	FileSystem    string `json:"fileSystem"`
	MountPoint    string `json:"mountPoint,omitempty"`
	SizeBytes     int64  `json:"sizeBytes"`
	Removable     bool   `json:"removable"`
	Mounted       bool   `json:"mounted"`
	Compatibility string `json:"compatibility"`
}

type Operation struct {
	ID             string `json:"id"`
	Kind           string `json:"kind"`
	Name           string `json:"name"`
	Source         string `json:"source"`
	Destination    string `json:"destination"`
	State          string `json:"state"`
	TotalBytes     int64  `json:"totalBytes"`
	ProcessedBytes int64  `json:"processedBytes"`
	Error          string `json:"error,omitempty"`
	cancel         context.CancelFunc
}

type lsblkOutput struct {
	BlockDevices []lsblkDevice `json:"blockdevices"`
}

type lsblkDevice struct {
	Name       string        `json:"name"`
	Path       string        `json:"path"`
	ParentName string        `json:"pkname"`
	Label      string        `json:"label"`
	FileSystem string        `json:"fstype"`
	MountPoint string        `json:"mountpoint"`
	Size       json.Number   `json:"size"`
	Removable  boolish       `json:"rm"`
	Hotplug    boolish       `json:"hotplug"`
	Type       string        `json:"type"`
	Transport  string        `json:"tran"`
	Children   []lsblkDevice `json:"children"`
}

type boolish bool

func (b *boolish) UnmarshalJSON(data []byte) error {
	value := strings.Trim(string(data), "\"")
	*b = boolish(value == "1" || strings.EqualFold(value, "true"))
	return nil
}

type Manager struct {
	mu            sync.RWMutex
	subscribers   map[string]chan Event
	operationsMu  sync.RWMutex
	operations    map[string]*Operation
	nextOperation uint64
}

func NewManager() *Manager {
	return &Manager{
		subscribers: make(map[string]chan Event),
		operations:  make(map[string]*Operation),
	}
}

func (m *Manager) List(path string, showHidden bool) (Listing, error) {
	resolved, err := directoryPath(path)
	if err != nil {
		return Listing{}, err
	}
	entries, err := os.ReadDir(resolved)
	if err != nil {
		return Listing{}, err
	}
	items := make([]Entry, 0, len(entries))
	for _, entry := range entries {
		hidden := strings.HasPrefix(entry.Name(), ".")
		if hidden && !showHidden {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		entryPath := filepath.Join(resolved, entry.Name())
		isDirectory := entry.IsDir()
		if entry.Type()&os.ModeSymlink != 0 {
			if targetInfo, statErr := os.Stat(entryPath); statErr == nil {
				isDirectory = targetInfo.IsDir()
			}
		}
		item := Entry{
			Name: entry.Name(), Path: entryPath, Directory: isDirectory,
			SizeBytes: info.Size(), ModifiedUnix: info.ModTime().Unix(), Hidden: hidden,
		}
		if !item.Directory {
			item.MimeType = mime.TypeByExtension(strings.ToLower(filepath.Ext(item.Name)))
		}
		items = append(items, item)
	}
	sort.SliceStable(items, func(i, j int) bool {
		if items[i].Directory != items[j].Directory {
			return items[i].Directory
		}
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
	parent := filepath.Dir(resolved)
	if parent == resolved {
		parent = ""
	}
	return Listing{Path: resolved, Parent: parent, Entries: items}, nil
}

func (m *Manager) Show(path string) error {
	if path == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return err
		}
		path = home
	}
	resolved, err := directoryPath(path)
	if err != nil {
		return err
	}
	event := Event{Show: true, Path: resolved}
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, channel := range m.subscribers {
		select {
		case channel <- event:
		default:
		}
	}
	return nil
}

func (m *Manager) Subscribe(id string) <-chan Event {
	m.mu.Lock()
	defer m.mu.Unlock()
	channel := make(chan Event, 8)
	m.subscribers[id] = channel
	return channel
}

func (m *Manager) Unsubscribe(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if channel := m.subscribers[id]; channel != nil {
		delete(m.subscribers, id)
		close(channel)
	}
}

func (m *Manager) MakeDirectory(parent, name string) error {
	parentPath, err := directoryPath(parent)
	if err != nil {
		return err
	}
	name, err = safeBaseName(name)
	if err != nil {
		return err
	}
	return os.Mkdir(filepath.Join(parentPath, name), 0o755)
}

func (m *Manager) Rename(path, newName string) error {
	resolved, err := existingPath(path)
	if err != nil {
		return err
	}
	newName, err = safeBaseName(newName)
	if err != nil {
		return err
	}
	target := filepath.Join(filepath.Dir(resolved), newName)
	if target == resolved {
		return nil
	}
	if _, err := os.Lstat(target); err == nil {
		return errors.New("файл или папка с таким именем уже существует")
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.Rename(resolved, target)
}

func (m *Manager) Trash(path string) error {
	resolved, err := existingPath(path)
	if err != nil {
		return err
	}
	_, err = trash.Put(resolved)
	return err
}

func (m *Manager) TrashList() ([]TrashEntry, error) {
	entries, err := trash.List()
	if err != nil {
		return nil, err
	}
	result := make([]TrashEntry, 0, len(entries))
	for _, entry := range entries {
		result = append(result, TrashEntry{
			Name:         entry.Name,
			OriginalPath: entry.OriginalPath,
			DeletionDate: entry.DeletionDate,
			TrashDir:     entry.TrashDir,
			Path:         entry.FilesPath,
			Directory:    entry.IsDir,
			SizeBytes:    entry.Size,
		})
	}
	sort.SliceStable(result, func(i, j int) bool {
		return result[i].DeletionDate > result[j].DeletionDate
	})
	return result, nil
}

func (m *Manager) TrashRestore(name, trashDir string) error {
	entry, err := resolveTrashEntry(name, trashDir)
	if err != nil {
		return err
	}
	return trash.Restore(entry.Name, entry.TrashDir)
}

func (m *Manager) TrashDelete(name, trashDir string) error {
	entry, err := resolveTrashEntry(name, trashDir)
	if err != nil {
		return err
	}
	if err := os.RemoveAll(entry.FilesPath); err != nil {
		return err
	}
	if err := os.Remove(entry.InfoPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func resolveTrashEntry(name, trashDir string) (trash.Entry, error) {
	name, err := safeBaseName(name)
	if err != nil {
		return trash.Entry{}, err
	}
	if !filepath.IsAbs(trashDir) {
		return trash.Entry{}, errors.New("некорректный путь корзины")
	}
	wantedDir := filepath.Clean(trashDir)
	entries, err := trash.List()
	if err != nil {
		return trash.Entry{}, err
	}
	for _, entry := range entries {
		if entry.Name == name && filepath.Clean(entry.TrashDir) == wantedDir {
			return entry, nil
		}
	}
	return trash.Entry{}, errors.New("объект не найден в корзине")
}

func (m *Manager) TrashEmpty() error {
	return trash.Empty()
}

func (m *Manager) Devices() ([]Device, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "lsblk", "--json", "--bytes",
		"--output", "NAME,PATH,PKNAME,LABEL,FSTYPE,MOUNTPOINT,SIZE,RM,HOTPLUG,TYPE,TRAN").Output()
	if err != nil {
		return nil, fmt.Errorf("список накопителей: %w", err)
	}
	var decoded lsblkOutput
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, fmt.Errorf("список накопителей: %w", err)
	}
	var result []Device
	for _, item := range decoded.BlockDevices {
		collectDevices(item, false, "", &result)
	}
	sort.SliceStable(result, func(i, j int) bool {
		if result[i].Mounted != result[j].Mounted {
			return result[i].Mounted
		}
		return strings.ToLower(result[i].Label) < strings.ToLower(result[j].Label)
	})
	return result, nil
}

func collectDevices(item lsblkDevice, parentExternal bool, parentPath string, result *[]Device) {
	external := parentExternal || bool(item.Removable) || bool(item.Hotplug) || item.Transport == "usb"
	currentParent := parentPath
	if item.Type == "disk" {
		currentParent = item.Path
	}
	size, _ := strconv.ParseInt(string(item.Size), 10, 64)
	if item.FileSystem != "" && !isSystemMount(item.MountPoint) && !strings.HasPrefix(item.FileSystem, "squashfs") {
		label := strings.TrimSpace(item.Label)
		if label == "" {
			label = item.Name
		}
		*result = append(*result, Device{
			Name:          item.Name,
			Path:          item.Path,
			ParentPath:    currentParent,
			Label:         label,
			FileSystem:    strings.ToLower(item.FileSystem),
			MountPoint:    item.MountPoint,
			SizeBytes:     size,
			Removable:     external,
			Mounted:       item.MountPoint != "",
			Compatibility: fileSystemCompatibility(item.FileSystem),
		})
	}
	for _, child := range item.Children {
		collectDevices(child, external, currentParent, result)
	}
}

func isSystemMount(mountPoint string) bool {
	switch mountPoint {
	case "/", "/boot", "/boot/efi", "/home", "/usr", "/var":
		return true
	default:
		return false
	}
}

func fileSystemCompatibility(fileSystem string) string {
	switch strings.ToLower(fileSystem) {
	case "ntfs", "ntfs3":
		return "windows"
	case "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs":
		return "kaskados"
	case "vfat", "fat", "fat16", "fat32", "exfat", "udf":
		return "universal"
	default:
		return "other"
	}
}

func (m *Manager) Mount(devicePath string) (string, error) {
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return "", err
	}
	device, err := m.deviceByPath(devicePath)
	if err != nil {
		return "", err
	}
	if device.Mounted {
		return device.MountPoint, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "udisksctl", "mount", "--block-device", devicePath, "--no-user-interaction").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("подключение накопителя: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	devices, listErr := m.Devices()
	if listErr == nil {
		for _, device := range devices {
			if device.Path == devicePath {
				return device.MountPoint, nil
			}
		}
	}
	return "", nil
}

func (m *Manager) SafelyRemove(devicePath string) error {
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return err
	}
	device, err := m.deviceByPath(devicePath)
	if err != nil {
		return err
	}
	mountPoint := device.MountPoint
	if mountPoint != "" && m.pathHasActiveOperation(mountPoint) {
		return errors.New("дождитесь завершения файловой операции на этом накопителе")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if mountPoint != "" {
		output, unmountErr := exec.CommandContext(ctx, "udisksctl", "unmount", "--block-device", devicePath, "--no-user-interaction").CombinedOutput()
		if unmountErr != nil {
			return fmt.Errorf("отключение накопителя: %w (%s)", unmountErr, strings.TrimSpace(string(output)))
		}
	}
	if !device.Removable || device.ParentPath == "" {
		return nil
	}
	parentPath, err := blockDevicePath(device.ParentPath)
	if err != nil {
		return nil
	}
	output, powerErr := exec.CommandContext(ctx, "udisksctl", "power-off", "--block-device", parentPath, "--no-user-interaction").CombinedOutput()
	if powerErr != nil {
		message := strings.ToLower(string(output))
		if strings.Contains(message, "not supported") || strings.Contains(message, "not a drive") {
			return nil
		}
		return fmt.Errorf("выключение накопителя: %w (%s)", powerErr, strings.TrimSpace(string(output)))
	}
	return nil
}

func (m *Manager) deviceByPath(path string) (Device, error) {
	devices, err := m.Devices()
	if err != nil {
		return Device{}, err
	}
	for _, device := range devices {
		if device.Path == path {
			return device, nil
		}
	}
	return Device{}, errors.New("накопитель не найден")
}

func blockDevicePath(path string) (string, error) {
	clean := filepath.Clean(path)
	if !strings.HasPrefix(clean, "/dev/") || clean == "/dev" {
		return "", errors.New("некорректный путь накопителя")
	}
	info, err := os.Stat(clean)
	if err != nil {
		return "", err
	}
	if info.Mode()&os.ModeDevice == 0 {
		return "", errors.New("указанный путь не является устройством")
	}
	return clean, nil
}

func (m *Manager) StartTransfer(source, destination string, move bool) (Operation, error) {
	source, err := existingPath(source)
	if err != nil {
		return Operation{}, err
	}
	destination, err = directoryPath(destination)
	if err != nil {
		return Operation{}, err
	}
	name := filepath.Base(source)
	target := uniqueTransferDestination(destination, name)
	if info, statErr := os.Stat(source); statErr == nil && info.IsDir() {
		relative, relErr := filepath.Rel(source, target)
		if relErr == nil && relative != "." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return Operation{}, errors.New("нельзя копировать папку внутрь самой себя")
		}
	}
	id := fmt.Sprintf("file-%d-%d", time.Now().UnixMilli(), atomic.AddUint64(&m.nextOperation, 1))
	kind := "copy"
	if move {
		kind = "move"
	}
	ctx, cancel := context.WithCancel(context.Background())
	operation := &Operation{ID: id, Kind: kind, Name: name, Source: source, Destination: target, State: "scanning", cancel: cancel}
	m.operationsMu.Lock()
	m.operations[id] = operation
	m.operationsMu.Unlock()
	result := operation.snapshot()
	go m.runTransfer(ctx, operation, move)
	return result, nil
}

func (m *Manager) Operation(id string) (Operation, error) {
	m.operationsMu.RLock()
	operation := m.operations[id]
	if operation == nil {
		m.operationsMu.RUnlock()
		return Operation{}, errors.New("операция не найдена")
	}
	result := operation.snapshot()
	m.operationsMu.RUnlock()
	return result, nil
}

func (m *Manager) CancelOperation(id string) error {
	m.operationsMu.RLock()
	operation := m.operations[id]
	if operation == nil {
		m.operationsMu.RUnlock()
		return errors.New("операция не найдена")
	}
	cancel := operation.cancel
	m.operationsMu.RUnlock()
	if cancel != nil {
		cancel()
	}
	return nil
}

func (operation *Operation) snapshot() Operation {
	result := *operation
	result.cancel = nil
	return result
}

func (m *Manager) updateOperation(id string, update func(*Operation)) {
	m.operationsMu.Lock()
	if operation := m.operations[id]; operation != nil {
		update(operation)
	}
	m.operationsMu.Unlock()
}

func (m *Manager) runTransfer(ctx context.Context, operation *Operation, move bool) {
	defer m.scheduleOperationExpiry(operation.ID)
	total, err := pathSize(ctx, operation.Source)
	if err != nil {
		m.finishOperation(operation.ID, "failed", err)
		return
	}
	m.updateOperation(operation.ID, func(item *Operation) {
		item.TotalBytes = total
		item.State = "running"
	})
	if move && sameFileSystem(operation.Source, filepath.Dir(operation.Destination)) {
		if err := os.Rename(operation.Source, operation.Destination); err == nil {
			m.updateOperation(operation.ID, func(item *Operation) {
				item.ProcessedBytes = item.TotalBytes
				item.State = "completed"
			})
			return
		}
	}
	if available, availableErr := availableBytes(filepath.Dir(operation.Destination)); availableErr == nil && total > available {
		m.finishOperation(operation.ID, "failed", fmt.Errorf("недостаточно места: требуется %d байт, доступно %d", total, available))
		return
	}
	err = copyPath(ctx, operation.Source, operation.Destination, func(delta int64) {
		m.updateOperation(operation.ID, func(item *Operation) { item.ProcessedBytes += delta })
	})
	if err != nil {
		_ = os.RemoveAll(operation.Destination)
		state := "failed"
		if errors.Is(err, context.Canceled) {
			state = "cancelled"
		}
		m.finishOperation(operation.ID, state, err)
		return
	}
	if move {
		if err := os.RemoveAll(operation.Source); err != nil {
			m.finishOperation(operation.ID, "failed", err)
			return
		}
	}
	m.updateOperation(operation.ID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.State = "completed"
	})
}

func (m *Manager) scheduleOperationExpiry(id string) {
	time.AfterFunc(10*time.Minute, func() {
		m.operationsMu.Lock()
		delete(m.operations, id)
		m.operationsMu.Unlock()
	})
}

func (m *Manager) finishOperation(id, state string, err error) {
	m.updateOperation(id, func(item *Operation) {
		item.State = state
		if err != nil && !errors.Is(err, context.Canceled) {
			item.Error = err.Error()
		}
	})
}

func (m *Manager) pathHasActiveOperation(path string) bool {
	path = filepath.Clean(path)
	m.operationsMu.RLock()
	defer m.operationsMu.RUnlock()
	for _, operation := range m.operations {
		if operation.State != "scanning" && operation.State != "running" {
			continue
		}
		for _, candidate := range []string{operation.Source, operation.Destination} {
			relative, err := filepath.Rel(path, candidate)
			if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				return true
			}
		}
	}
	return false
}

func (m *Manager) Open(path string) error {
	resolved, err := existingPath(path)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "gio", "open", resolved).CombinedOutput()
	if err != nil {
		return fmt.Errorf("gio open: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (m *Manager) Extract(path string) (string, error) {
	archive, err := existingPath(path)
	if err != nil {
		return "", err
	}
	if !isArchive(archive) {
		return "", errors.New("формат архива не поддерживается")
	}
	destination := uniqueDestination(filepath.Dir(archive), archiveStem(filepath.Base(archive)))
	if err := os.Mkdir(destination, 0o755); err != nil {
		return "", err
	}
	completed := false
	defer func() {
		if !completed {
			_ = os.RemoveAll(destination)
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	out, err := exec.CommandContext(ctx, "bsdtar", "-xf", archive, "--no-same-owner", "--no-same-permissions", "-C", destination).CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("распаковка: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	completed = true
	return destination, nil
}

func (m *Manager) Archive(path, format string) (string, error) {
	resolved, err := existingPath(path)
	if err != nil {
		return "", err
	}
	extension := map[string]string{"zip": ".zip", "7z": ".7z", "tar.gz": ".tar.gz", "tar.zst": ".tar.zst"}[format]
	if extension == "" {
		return "", errors.New("формат архива не поддерживается")
	}
	output := uniqueFile(filepath.Join(filepath.Dir(resolved), filepath.Base(resolved)+extension))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bsdtar", "-a", "-cf", output, filepath.Base(resolved))
	cmd.Dir = filepath.Dir(resolved)
	combined, err := cmd.CombinedOutput()
	if err != nil {
		_ = os.Remove(output)
		return "", fmt.Errorf("создание архива: %w (%s)", err, strings.TrimSpace(string(combined)))
	}
	return output, nil
}

func directoryPath(path string) (string, error) {
	clean, err := existingPath(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(clean)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", errors.New("каталог недоступен")
	}
	return resolved, nil
}

func existingPath(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("нужен абсолютный путь")
	}
	clean := filepath.Clean(path)
	if _, err := os.Lstat(clean); err != nil {
		return "", err
	}
	return clean, nil
}

func safeBaseName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || name == "." || name == ".." || filepath.Base(name) != name || strings.ContainsAny(name, "/\x00") {
		return "", errors.New("некорректное имя")
	}
	return name, nil
}

func isArchive(path string) bool {
	lower := strings.ToLower(path)
	for _, suffix := range []string{".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.zst", ".txz"} {
		if strings.HasSuffix(lower, suffix) {
			return true
		}
	}
	return false
}

func archiveStem(name string) string {
	lower := strings.ToLower(name)
	for _, suffix := range []string{".tar.gz", ".tar.xz", ".tar.zst", ".zip", ".7z", ".rar", ".tar", ".tgz", ".txz"} {
		if strings.HasSuffix(lower, suffix) {
			return name[:len(name)-len(suffix)]
		}
	}
	return name + "-распаковано"
}

func uniqueDestination(parent, base string) string {
	if base == "" {
		base = "распаковано"
	}
	for index := 0; ; index++ {
		name := base
		if index > 0 {
			name = fmt.Sprintf("%s (%d)", base, index)
		}
		candidate := filepath.Join(parent, name)
		if _, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
}

func uniqueFile(path string) string {
	ext := archiveExtension(path)
	base := strings.TrimSuffix(path, ext)
	for index := 0; ; index++ {
		candidate := path
		if index > 0 {
			candidate = fmt.Sprintf("%s (%d)%s", base, index, ext)
		}
		if _, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
}

func archiveExtension(path string) string {
	lower := strings.ToLower(path)
	for _, extension := range []string{".tar.gz", ".tar.xz", ".tar.zst", ".zip", ".7z", ".rar", ".tar", ".tgz", ".txz"} {
		if strings.HasSuffix(lower, extension) {
			return path[len(path)-len(extension):]
		}
	}
	return filepath.Ext(path)
}

func uniqueTransferDestination(parent, name string) string {
	target := filepath.Join(parent, name)
	if _, err := os.Lstat(target); errors.Is(err, os.ErrNotExist) {
		return target
	}
	extension := filepath.Ext(name)
	stem := strings.TrimSuffix(name, extension)
	for index := 2; ; index++ {
		candidate := filepath.Join(parent, fmt.Sprintf("%s (%d)%s", stem, index, extension))
		if _, err := os.Lstat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
}

func pathSize(ctx context.Context, path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(current string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if entry.Type()&os.ModeSymlink != 0 || entry.IsDir() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		total += info.Size()
		return nil
	})
	return total, err
}

func sameFileSystem(source, destination string) bool {
	sourceInfo, sourceErr := os.Stat(source)
	destinationInfo, destinationErr := os.Stat(destination)
	if sourceErr != nil || destinationErr != nil {
		return false
	}
	sourceStat, sourceOK := sourceInfo.Sys().(*syscall.Stat_t)
	destinationStat, destinationOK := destinationInfo.Sys().(*syscall.Stat_t)
	return sourceOK && destinationOK && sourceStat.Dev == destinationStat.Dev
}

func availableBytes(path string) (int64, error) {
	var stats syscall.Statfs_t
	if err := syscall.Statfs(path, &stats); err != nil {
		return 0, err
	}
	return int64(stats.Bavail) * int64(stats.Bsize), nil
}

func copyPath(ctx context.Context, source, destination string, progress func(int64)) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		return os.Symlink(target, destination)
	}
	if !info.IsDir() {
		return copyFile(ctx, source, destination, info.Mode(), progress)
	}
	if err := os.Mkdir(destination, info.Mode().Perm()); err != nil {
		return err
	}
	entries, err := os.ReadDir(source)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if err := copyPath(ctx, filepath.Join(source, entry.Name()), filepath.Join(destination, entry.Name()), progress); err != nil {
			return err
		}
	}
	return os.Chtimes(destination, info.ModTime(), info.ModTime())
}

func copyFile(ctx context.Context, source, destination string, mode os.FileMode, progress func(int64)) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode.Perm())
	if err != nil {
		return err
	}
	completed := false
	defer func() {
		_ = output.Close()
		if !completed {
			_ = os.Remove(destination)
		}
	}()
	buffer := make([]byte, 1024*1024)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		read, readErr := input.Read(buffer)
		if read > 0 {
			written, writeErr := output.Write(buffer[:read])
			if writeErr != nil {
				return writeErr
			}
			if written != read {
				return io.ErrShortWrite
			}
			progress(int64(written))
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	if err := output.Sync(); err != nil {
		return err
	}
	completed = true
	return output.Close()
}
