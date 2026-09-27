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
	"unicode"
	"unicode/utf8"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/trash"
	"github.com/godbus/dbus/v5"
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
	ReadOnly      bool   `json:"readOnly"`
	Mounted       bool   `json:"mounted"`
	System        bool   `json:"system"`
	Layered       bool   `json:"layered"`
	Compatibility string `json:"compatibility"`
}

type StorageRegion struct {
	Kind           string  `json:"kind"`
	Name           string  `json:"name"`
	Path           string  `json:"path,omitempty"`
	ParentPath     string  `json:"parentPath"`
	Label          string  `json:"label,omitempty"`
	FileSystem     string  `json:"fileSystem,omitempty"`
	MountPoint     string  `json:"mountPoint,omitempty"`
	UUID           string  `json:"uuid,omitempty"`
	PartitionUUID  string  `json:"partitionUuid,omitempty"`
	PartitionType  string  `json:"partitionType,omitempty"`
	PartitionName  string  `json:"partitionName,omitempty"`
	OffsetBytes    int64   `json:"offsetBytes"`
	SizeBytes      int64   `json:"sizeBytes"`
	AvailableBytes int64   `json:"availableBytes,omitempty"`
	UsagePercent   float64 `json:"usagePercent,omitempty"`
	ReadOnly       bool    `json:"readOnly"`
	Mounted        bool    `json:"mounted"`
	System         bool    `json:"system"`
	Layered        bool    `json:"layered"`
	Compatibility  string  `json:"compatibility"`
}

type StorageDisk struct {
	Name           string          `json:"name"`
	Path           string          `json:"path"`
	Model          string          `json:"model,omitempty"`
	Vendor         string          `json:"vendor,omitempty"`
	Serial         string          `json:"serial,omitempty"`
	Transport      string          `json:"transport,omitempty"`
	PartitionTable string          `json:"partitionTable,omitempty"`
	PartitionUUID  string          `json:"partitionUuid,omitempty"`
	SizeBytes      int64           `json:"sizeBytes"`
	Removable      bool            `json:"removable"`
	Hotplug        bool            `json:"hotplug"`
	ReadOnly       bool            `json:"readOnly"`
	System         bool            `json:"system"`
	Regions        []StorageRegion `json:"regions"`
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
	Detail         string `json:"detail,omitempty"`
	Error          string `json:"error,omitempty"`
	cancel         context.CancelFunc
}

type lsblkOutput struct {
	BlockDevices []lsblkDevice `json:"blockdevices"`
}

type lsblkDevice struct {
	Name           string        `json:"name"`
	Path           string        `json:"path"`
	ParentName     string        `json:"pkname"`
	Label          string        `json:"label"`
	FileSystem     string        `json:"fstype"`
	MountPoint     string        `json:"mountpoint"`
	Size           json.Number   `json:"size"`
	Removable      boolish       `json:"rm"`
	ReadOnly       boolish       `json:"ro"`
	Hotplug        boolish       `json:"hotplug"`
	Type           string        `json:"type"`
	Transport      string        `json:"tran"`
	Model          string        `json:"model"`
	Vendor         string        `json:"vendor"`
	Serial         string        `json:"serial"`
	PartitionTable string        `json:"pttype"`
	PartitionUUID  string        `json:"ptuuid"`
	UUID           string        `json:"uuid"`
	PartitionType  string        `json:"parttype"`
	PartitionName  string        `json:"partlabel"`
	PartitionID    string        `json:"partuuid"`
	Start          json.Number   `json:"start"`
	LogicalSector  json.Number   `json:"log-sec"`
	Available      json.Number   `json:"fsavail"`
	Usage          string        `json:"fsuse%"`
	Children       []lsblkDevice `json:"children"`
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
	decoded, err := blockInventory()
	if err != nil {
		return nil, err
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

func blockInventory() (lsblkOutput, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "lsblk", "--json", "--bytes",
		"--output", "NAME,PATH,PKNAME,LABEL,FSTYPE,MOUNTPOINT,SIZE,RM,RO,HOTPLUG,TYPE,TRAN,MODEL,VENDOR,SERIAL,PTTYPE,PTUUID,UUID,PARTTYPE,PARTLABEL,PARTUUID,START,LOG-SEC,FSAVAIL,FSUSE%").Output()
	if err != nil {
		return lsblkOutput{}, fmt.Errorf("список накопителей: %w", err)
	}
	var decoded lsblkOutput
	decoder := json.NewDecoder(strings.NewReader(string(output)))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return lsblkOutput{}, fmt.Errorf("список накопителей: %w", err)
	}
	return decoded, nil
}

func (m *Manager) Storage() ([]StorageDisk, error) {
	decoded, err := blockInventory()
	if err != nil {
		return nil, err
	}
	disks := make([]StorageDisk, 0, len(decoded.BlockDevices))
	for _, item := range decoded.BlockDevices {
		if item.Type != "disk" {
			continue
		}
		disk := storageDisk(item)
		disks = append(disks, disk)
	}
	sort.SliceStable(disks, func(i, j int) bool {
		if disks[i].System != disks[j].System {
			return disks[i].System
		}
		if disks[i].Removable != disks[j].Removable {
			return !disks[i].Removable
		}
		return strings.ToLower(disks[i].Name) < strings.ToLower(disks[j].Name)
	})
	return disks, nil
}

func storageDisk(item lsblkDevice) StorageDisk {
	diskSize := numberInt64(item.Size)
	logicalSector := numberInt64(item.LogicalSector)
	if logicalSector <= 0 {
		logicalSector = 512
	}
	disk := StorageDisk{
		Name:           item.Name,
		Path:           item.Path,
		Model:          strings.TrimSpace(item.Model),
		Vendor:         strings.TrimSpace(item.Vendor),
		Serial:         strings.TrimSpace(item.Serial),
		Transport:      strings.TrimSpace(item.Transport),
		PartitionTable: strings.ToLower(strings.TrimSpace(item.PartitionTable)),
		PartitionUUID:  strings.TrimSpace(item.PartitionUUID),
		SizeBytes:      diskSize,
		Removable:      bool(item.Removable),
		Hotplug:        bool(item.Hotplug),
		ReadOnly:       bool(item.ReadOnly),
		Regions:        []StorageRegion{},
	}

	partitions := make([]StorageRegion, 0, len(item.Children))
	for _, child := range item.Children {
		if child.Type != "part" {
			continue
		}
		region := storageRegion(child, item.Path, logicalSector)
		partitions = append(partitions, region)
		if region.System {
			disk.System = true
		}
	}
	sort.SliceStable(partitions, func(i, j int) bool {
		return partitions[i].OffsetBytes < partitions[j].OffsetBytes
	})

	if len(partitions) == 0 && item.FileSystem != "" {
		region := storageRegion(item, item.Path, logicalSector)
		region.Kind = "volume"
		region.OffsetBytes = 0
		disk.Regions = append(disk.Regions, region)
		disk.System = region.System
		return disk
	}

	const alignment = int64(1024 * 1024)
	cursor := alignment
	usableEnd := diskSize - alignment
	for _, partition := range partitions {
		if partition.OffsetBytes > cursor+alignment {
			disk.Regions = append(disk.Regions, StorageRegion{
				Kind: "free", Name: "Свободное место", ParentPath: item.Path,
				OffsetBytes: cursor, SizeBytes: partition.OffsetBytes - cursor,
			})
		}
		disk.Regions = append(disk.Regions, partition)
		if end := partition.OffsetBytes + partition.SizeBytes; end > cursor {
			cursor = end
		}
	}
	if usableEnd > cursor+alignment {
		disk.Regions = append(disk.Regions, StorageRegion{
			Kind: "free", Name: "Свободное место", ParentPath: item.Path,
			OffsetBytes: cursor, SizeBytes: usableEnd - cursor,
		})
	}
	if len(disk.Regions) == 0 && diskSize > 2*alignment {
		disk.Regions = append(disk.Regions, StorageRegion{
			Kind: "free", Name: "Свободное место", ParentPath: item.Path,
			OffsetBytes: alignment, SizeBytes: diskSize - 2*alignment,
		})
	}
	return disk
}

func storageRegion(item lsblkDevice, parentPath string, logicalSector int64) StorageRegion {
	display := item
	layered := len(item.Children) > 0
	for len(display.Children) > 0 {
		display = display.Children[0]
	}
	label := strings.TrimSpace(display.Label)
	if label == "" {
		label = strings.TrimSpace(item.PartitionName)
	}
	if label == "" {
		label = item.Name
	}
	usage, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(display.Usage), "%"), 64)
	region := StorageRegion{
		Kind:           "partition",
		Name:           item.Name,
		Path:           item.Path,
		ParentPath:     parentPath,
		Label:          label,
		FileSystem:     strings.ToLower(display.FileSystem),
		MountPoint:     display.MountPoint,
		UUID:           strings.TrimSpace(display.UUID),
		PartitionUUID:  strings.TrimSpace(item.PartitionID),
		PartitionType:  strings.TrimSpace(item.PartitionType),
		PartitionName:  strings.TrimSpace(item.PartitionName),
		OffsetBytes:    numberInt64(item.Start) * logicalSector,
		SizeBytes:      numberInt64(item.Size),
		AvailableBytes: numberInt64(display.Available),
		UsagePercent:   usage,
		ReadOnly:       bool(item.ReadOnly) || bool(display.ReadOnly),
		Mounted:        display.MountPoint != "",
		System:         nodeContainsSystemMount(item),
		Layered:        layered,
		Compatibility:  fileSystemCompatibility(display.FileSystem),
	}
	return region
}

func nodeContainsSystemMount(item lsblkDevice) bool {
	if isSystemMount(item.MountPoint) {
		return true
	}
	for _, child := range item.Children {
		if nodeContainsSystemMount(child) {
			return true
		}
	}
	return false
}

func numberInt64(value json.Number) int64 {
	parsed, _ := strconv.ParseInt(string(value), 10, 64)
	return parsed
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
			ReadOnly:      bool(item.ReadOnly),
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

func normalizeFormatRequest(fileSystem, label string) (string, string, error) {
	fileSystem = strings.ToLower(strings.TrimSpace(fileSystem))
	switch fileSystem {
	case "ext4", "btrfs", "exfat", "vfat", "ntfs":
	default:
		return "", "", errors.New("поддерживаются только Btrfs, EXT4, NTFS, exFAT и FAT32")
	}

	label = strings.TrimSpace(label)
	for _, character := range label {
		if unicode.IsControl(character) || strings.ContainsRune(`/\\*?<>|":`, character) {
			return "", "", errors.New("имя накопителя содержит недопустимые символы")
		}
	}

	switch fileSystem {
	case "vfat":
		label = strings.ToUpper(label)
		if len(label) > 11 || len(label) != utf8.RuneCountInString(label) {
			return "", "", errors.New("для FAT32 имя должно содержать до 11 латинских символов")
		}
	case "exfat":
		if utf8.RuneCountInString(label) > 15 {
			return "", "", errors.New("для exFAT имя должно содержать не больше 15 символов")
		}
	case "ext4":
		if len([]byte(label)) > 16 {
			return "", "", errors.New("для EXT4 имя должно занимать не больше 16 байт")
		}
	case "btrfs":
		if len([]byte(label)) > 255 {
			return "", "", errors.New("для Btrfs имя должно занимать меньше 256 байт")
		}
	case "ntfs":
		if utf8.RuneCountInString(label) > 32 {
			return "", "", errors.New("для NTFS имя должно содержать не больше 32 символов")
		}
	}
	return fileSystem, label, nil
}

func checkUDisksFormatAvailable(fileSystem string) error {
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("подключение к службе накопителей: %w", err)
	}
	defer connection.Close()

	var available bool
	var utility string
	call := connection.Object("org.freedesktop.UDisks2", dbus.ObjectPath("/org/freedesktop/UDisks2/Manager")).Call(
		"org.freedesktop.UDisks2.Manager.CanFormat", 0, fileSystem)
	if call.Err != nil {
		return fmt.Errorf("проверка поддержки %s: %w", fileSystem, call.Err)
	}
	if err := call.Store(&available, &utility); err != nil {
		return fmt.Errorf("проверка поддержки %s: %w", fileSystem, err)
	}
	if !available {
		if utility != "" {
			return fmt.Errorf("для %s не установлена утилита %s", fileSystem, utility)
		}
		return fmt.Errorf("форматирование в %s не поддерживается", fileSystem)
	}
	return nil
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
	if m.storageOperationActive() {
		return "", errors.New("дождитесь завершения операции с накопителем")
	}
	if device.Mounted {
		return device.MountPoint, nil
	}
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return "", fmt.Errorf("подключение к службе накопителей: %w", err)
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, devicePath)
	if err != nil {
		return "", err
	}
	var mountPoint string
	call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
		"org.freedesktop.UDisks2.Filesystem.Mount",
		dbus.FlagAllowInteractiveAuthorization,
		map[string]dbus.Variant{})
	if call.Err != nil {
		return "", fmt.Errorf("не удалось подключить накопитель: %w", call.Err)
	}
	if err := call.Store(&mountPoint); err != nil {
		return "", fmt.Errorf("не удалось определить точку подключения: %w", err)
	}
	return mountPoint, nil
}

func (m *Manager) Unmount(devicePath string) error {
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return err
	}
	device, err := m.deviceByPath(devicePath)
	if err != nil {
		return err
	}
	if m.storageOperationActive() {
		return errors.New("дождитесь завершения операции с накопителем")
	}
	if device.System {
		return errors.New("системный раздел нельзя отключить во время работы системы")
	}
	if !device.Mounted {
		return nil
	}
	if m.pathHasActiveOperation(device.MountPoint) {
		return errors.New("дождитесь завершения файловой операции на этом разделе")
	}
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("подключение к службе накопителей: %w", err)
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, devicePath)
	if err != nil {
		return err
	}
	call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
		"org.freedesktop.UDisks2.Filesystem.Unmount",
		dbus.FlagAllowInteractiveAuthorization,
		map[string]dbus.Variant{})
	if call.Err != nil {
		return fmt.Errorf("не удалось отключить раздел: %w", call.Err)
	}
	return nil
}

func (m *Manager) SafelyRemove(devicePath string) error {
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return err
	}
	if m.storageOperationActive() {
		return errors.New("дождитесь завершения операции с накопителем")
	}
	if disk, found := m.findStorageDisk(devicePath); found {
		return m.safelyRemoveDisk(disk)
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

func (m *Manager) findStorageDisk(devicePath string) (StorageDisk, bool) {
	disks, err := m.Storage()
	if err != nil {
		return StorageDisk{}, false
	}
	for _, disk := range disks {
		if disk.Path == devicePath {
			return disk, true
		}
		for _, region := range disk.Regions {
			if region.Path == devicePath {
				return disk, true
			}
		}
	}
	return StorageDisk{}, false
}

func (m *Manager) safelyRemoveDisk(disk StorageDisk) error {
	if disk.System {
		return errors.New("системный диск нельзя извлечь во время работы")
	}
	for _, region := range disk.Regions {
		if region.Mounted && m.pathHasActiveOperation(region.MountPoint) {
			return errors.New("дождитесь завершения файловой операции на этом накопителе")
		}
	}
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("подключение к службе накопителей: %w", err)
	}
	defer connection.Close()
	for _, region := range disk.Regions {
		if !region.Mounted || region.Path == "" {
			continue
		}
		objectPath, resolveErr := resolveUDisksDevice(connection, region.Path)
		if resolveErr != nil {
			return resolveErr
		}
		call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
			"org.freedesktop.UDisks2.Filesystem.Unmount", dbus.FlagAllowInteractiveAuthorization,
			map[string]dbus.Variant{})
		if call.Err != nil {
			return fmt.Errorf("не удалось отключить раздел %s: %w", region.Name, call.Err)
		}
	}
	if !disk.Removable && !disk.Hotplug {
		return nil
	}
	diskObjectPath, err := resolveUDisksDevice(connection, disk.Path)
	if err != nil {
		return err
	}
	driveValue, err := connection.Object("org.freedesktop.UDisks2", diskObjectPath).
		GetProperty("org.freedesktop.UDisks2.Block.Drive")
	if err != nil {
		return fmt.Errorf("не удалось определить физический накопитель: %w", err)
	}
	drivePath, ok := driveValue.Value().(dbus.ObjectPath)
	if !ok || !drivePath.IsValid() || drivePath == "/" {
		return errors.New("накопитель отключён, но его питание нельзя выключить программно")
	}
	call := connection.Object("org.freedesktop.UDisks2", drivePath).Call(
		"org.freedesktop.UDisks2.Drive.PowerOff", dbus.FlagAllowInteractiveAuthorization,
		map[string]dbus.Variant{})
	if call.Err != nil {
		return fmt.Errorf("разделы отключены, но питание накопителя выключить не удалось: %w", call.Err)
	}
	return nil
}

func (m *Manager) StartFormat(devicePath, fileSystem, label string, confirmed bool) (Operation, error) {
	if !confirmed {
		return Operation{}, errors.New("форматирование не подтверждено")
	}
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	device, err := m.deviceByPath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	if device.System {
		return Operation{}, errors.New("нельзя форматировать системный или загрузочный раздел")
	}
	if device.Layered {
		return Operation{}, errors.New("сначала отключите вложенное шифрование или логические тома")
	}
	if device.ReadOnly {
		return Operation{}, errors.New("накопитель защищён от записи")
	}
	if device.MountPoint != "" && m.pathHasActiveOperation(device.MountPoint) {
		return Operation{}, errors.New("дождитесь завершения файловой операции на этом накопителе")
	}
	fileSystem, label, err = normalizeFormatRequest(fileSystem, label)
	if err != nil {
		return Operation{}, err
	}
	if err := checkUDisksFormatAvailable(fileSystem); err != nil {
		return Operation{}, err
	}

	id := fmt.Sprintf("format-%d-%d", time.Now().UnixMilli(), atomic.AddUint64(&m.nextOperation, 1))
	operationName := label
	if operationName == "" {
		operationName = device.Name
	}
	operation := &Operation{
		ID: id, Kind: "format", Name: operationName, Source: device.Path,
		State: "running", TotalBytes: 3,
		Detail: "Подготавливаем накопитель",
	}
	m.operationsMu.Lock()
	if m.storageOperationActiveLocked() {
		m.operationsMu.Unlock()
		return Operation{}, errors.New("дождитесь завершения другой операции с накопителем")
	}
	m.operations[id] = operation
	m.operationsMu.Unlock()
	result := operation.snapshot()
	go m.runFormat(operation, device, fileSystem, label)
	return result, nil
}

func (m *Manager) StartCreatePartition(diskPath string, offsetBytes, sizeBytes int64, fileSystem, label string, confirmed bool) (Operation, error) {
	if !confirmed {
		return Operation{}, errors.New("создание раздела не подтверждено")
	}
	diskPath, err := blockDevicePath(diskPath)
	if err != nil {
		return Operation{}, err
	}
	disk, err := m.storageDiskByPath(diskPath)
	if err != nil {
		return Operation{}, err
	}
	if disk.ReadOnly {
		return Operation{}, errors.New("накопитель защищён от записи")
	}
	if disk.PartitionTable != "gpt" && disk.PartitionTable != "dos" {
		return Operation{}, errors.New("сначала создайте таблицу разделов GPT или MBR")
	}
	if offsetBytes < 1024*1024 || sizeBytes < 8*1024*1024 {
		return Operation{}, errors.New("некорректный размер нового раздела")
	}
	if !diskContainsFreeRegion(disk, offsetBytes, sizeBytes) {
		return Operation{}, errors.New("выбранная область больше доступного свободного места")
	}
	fileSystem, label, err = normalizeFormatRequest(fileSystem, label)
	if err != nil {
		return Operation{}, err
	}
	if err := checkUDisksFormatAvailable(fileSystem); err != nil {
		return Operation{}, err
	}
	operation, err := m.beginStorageOperation("storage-create", label, disk.Path, 3)
	if err != nil {
		return Operation{}, err
	}
	go m.runCreatePartition(operation.ID, disk, offsetBytes, sizeBytes, fileSystem, label)
	return operation, nil
}

func (m *Manager) StartDeletePartition(devicePath string, confirmed bool) (Operation, error) {
	if !confirmed {
		return Operation{}, errors.New("удаление раздела не подтверждено")
	}
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	disk, region, err := m.storageRegionByPath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	if region.Kind != "partition" {
		return Operation{}, errors.New("выбранный объект не является разделом")
	}
	if region.System {
		return Operation{}, errors.New("нельзя удалить системный или загрузочный раздел")
	}
	if region.Layered {
		return Operation{}, errors.New("сначала отключите вложенное шифрование или логические тома")
	}
	if disk.ReadOnly || region.ReadOnly {
		return Operation{}, errors.New("накопитель защищён от записи")
	}
	operation, err := m.beginStorageOperation("storage-delete", region.Label, disk.Path, 2)
	if err != nil {
		return Operation{}, err
	}
	operation.Source = region.Path
	m.replaceOperation(operation)
	go m.runDeletePartition(operation.ID, region)
	return operation, nil
}

func (m *Manager) StartCreatePartitionTable(diskPath, table string, confirmed bool) (Operation, error) {
	if !confirmed {
		return Operation{}, errors.New("очистка накопителя не подтверждена")
	}
	diskPath, err := blockDevicePath(diskPath)
	if err != nil {
		return Operation{}, err
	}
	disk, err := m.storageDiskByPath(diskPath)
	if err != nil {
		return Operation{}, err
	}
	table = strings.ToLower(strings.TrimSpace(table))
	if table != "gpt" && table != "dos" {
		return Operation{}, errors.New("поддерживаются таблицы разделов GPT и MBR")
	}
	if disk.System {
		return Operation{}, errors.New("нельзя очистить диск, с которого запущена система")
	}
	if disk.ReadOnly {
		return Operation{}, errors.New("накопитель защищён от записи")
	}
	for _, region := range disk.Regions {
		if region.Mounted {
			return Operation{}, errors.New("перед очисткой отключите все разделы накопителя")
		}
	}
	operation, err := m.beginStorageOperation("storage-table", disk.Name, disk.Path, 2)
	if err != nil {
		return Operation{}, err
	}
	go m.runCreatePartitionTable(operation.ID, disk, table)
	return operation, nil
}

func (m *Manager) StartResizePartition(devicePath string, sizeBytes int64, confirmed bool) (Operation, error) {
	if !confirmed {
		return Operation{}, errors.New("изменение размера не подтверждено")
	}
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	disk, region, err := m.storageRegionByPath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	if region.Kind != "partition" || region.FileSystem == "" {
		return Operation{}, errors.New("размер можно изменить только у раздела с файловой системой")
	}
	if region.System || region.Layered {
		return Operation{}, errors.New("этот раздел нельзя изменять во время работы системы")
	}
	if disk.ReadOnly || region.ReadOnly {
		return Operation{}, errors.New("накопитель защищён от записи")
	}
	if sizeBytes < 16*1024*1024 || sizeBytes == region.SizeBytes {
		return Operation{}, errors.New("укажите другой допустимый размер раздела")
	}
	if sizeBytes > region.SizeBytes && !diskHasSpaceAfter(disk, region, sizeBytes-region.SizeBytes) {
		return Operation{}, errors.New("после раздела недостаточно непрерывного свободного места")
	}
	operation, err := m.beginStorageOperation("storage-resize", region.Label, disk.Path, 4)
	if err != nil {
		return Operation{}, err
	}
	operation.Source = region.Path
	m.replaceOperation(operation)
	go m.runResizePartition(operation.ID, region, sizeBytes)
	return operation, nil
}

func (m *Manager) StartFilesystemMaintenance(devicePath string, repair, confirmed bool) (Operation, error) {
	if repair && !confirmed {
		return Operation{}, errors.New("исправление файловой системы не подтверждено")
	}
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	disk, region, err := m.storageRegionByPath(devicePath)
	if err != nil {
		return Operation{}, err
	}
	if region.FileSystem == "" || region.Layered {
		return Operation{}, errors.New("для этого раздела проверка недоступна")
	}
	if repair && (disk.ReadOnly || region.ReadOnly) {
		return Operation{}, errors.New("раздел защищён от записи")
	}
	if region.System {
		return Operation{}, errors.New("системный раздел нельзя отключить для проверки во время работы")
	}
	kind := "storage-check"
	if repair {
		kind = "storage-repair"
	}
	operation, err := m.beginStorageOperation(kind, region.Label, disk.Path, 3)
	if err != nil {
		return Operation{}, err
	}
	operation.Source = region.Path
	m.replaceOperation(operation)
	go m.runFilesystemMaintenance(operation.ID, region, repair)
	return operation, nil
}

func (m *Manager) SetFilesystemLabel(devicePath, label string) error {
	devicePath, err := blockDevicePath(devicePath)
	if err != nil {
		return err
	}
	_, region, err := m.storageRegionByPath(devicePath)
	if err != nil {
		return err
	}
	if region.System || region.ReadOnly || region.Layered {
		return errors.New("имя этого раздела нельзя изменить")
	}
	fileSystem := region.FileSystem
	if fileSystem == "ntfs3" {
		fileSystem = "ntfs"
	}
	_, label, err = normalizeFormatRequest(fileSystem, label)
	if err != nil {
		return err
	}
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		return fmt.Errorf("подключение к службе накопителей: %w", err)
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, devicePath)
	if err != nil {
		return err
	}
	call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
		"org.freedesktop.UDisks2.Filesystem.SetLabel", dbus.FlagAllowInteractiveAuthorization,
		label, map[string]dbus.Variant{})
	if call.Err != nil {
		return fmt.Errorf("не удалось изменить имя раздела: %w", call.Err)
	}
	return nil
}

func (m *Manager) beginStorageOperation(kind, name, source string, steps int64) (Operation, error) {
	if strings.TrimSpace(name) == "" {
		name = filepath.Base(source)
	}
	operation := &Operation{
		ID:   fmt.Sprintf("storage-%d-%d", time.Now().UnixMilli(), atomic.AddUint64(&m.nextOperation, 1)),
		Kind: kind, Name: name, Source: source, State: "running", TotalBytes: steps,
		Detail: "Подготавливаем операцию",
	}
	m.operationsMu.Lock()
	defer m.operationsMu.Unlock()
	if m.storageOperationActiveLocked() {
		return Operation{}, errors.New("дождитесь завершения другой операции с накопителем")
	}
	m.operations[operation.ID] = operation
	return operation.snapshot(), nil
}

func (m *Manager) replaceOperation(replacement Operation) {
	m.operationsMu.Lock()
	if operation := m.operations[replacement.ID]; operation != nil {
		cancel := operation.cancel
		*operation = replacement
		operation.cancel = cancel
	}
	m.operationsMu.Unlock()
}

func (m *Manager) storageDiskByPath(path string) (StorageDisk, error) {
	disks, err := m.Storage()
	if err != nil {
		return StorageDisk{}, err
	}
	for _, disk := range disks {
		if disk.Path == path {
			return disk, nil
		}
	}
	return StorageDisk{}, errors.New("физический накопитель не найден")
}

func (m *Manager) storageRegionByPath(path string) (StorageDisk, StorageRegion, error) {
	disks, err := m.Storage()
	if err != nil {
		return StorageDisk{}, StorageRegion{}, err
	}
	for _, disk := range disks {
		for _, region := range disk.Regions {
			if region.Path == path {
				return disk, region, nil
			}
		}
	}
	return StorageDisk{}, StorageRegion{}, errors.New("раздел не найден")
}

func diskContainsFreeRegion(disk StorageDisk, offsetBytes, sizeBytes int64) bool {
	requestedEnd := offsetBytes + sizeBytes
	if requestedEnd < offsetBytes {
		return false
	}
	for _, region := range disk.Regions {
		if region.Kind != "free" {
			continue
		}
		if offsetBytes >= region.OffsetBytes && requestedEnd <= region.OffsetBytes+region.SizeBytes {
			return true
		}
	}
	return false
}

func diskHasSpaceAfter(disk StorageDisk, selected StorageRegion, extraBytes int64) bool {
	selectedEnd := selected.OffsetBytes + selected.SizeBytes
	for _, region := range disk.Regions {
		if region.Kind == "free" && region.OffsetBytes >= selectedEnd &&
			region.OffsetBytes-selectedEnd <= 1024*1024 &&
			region.SizeBytes >= extraBytes {
			return true
		}
	}
	return false
}

func (m *Manager) runCreatePartition(operationID string, disk StorageDisk, offsetBytes, sizeBytes int64, fileSystem, label string) {
	defer m.scheduleOperationExpiry(operationID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, disk.Path)
	if err != nil {
		m.finishOperation(operationID, "failed", err)
		return
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = "Создаём раздел"
	})
	formatOptions := map[string]dbus.Variant{
		"update-partition-type": dbus.MakeVariant(true),
		"take-ownership":        dbus.MakeVariant(fileSystem == "ext4" || fileSystem == "btrfs"),
	}
	if label != "" {
		formatOptions["label"] = dbus.MakeVariant(label)
	}
	var created dbus.ObjectPath
	call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
		"org.freedesktop.UDisks2.PartitionTable.CreatePartitionAndFormat",
		dbus.FlagAllowInteractiveAuthorization,
		uint64(offsetBytes), uint64(sizeBytes), "", "",
		map[string]dbus.Variant{}, fileSystem, formatOptions)
	if call.Err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("не удалось создать раздел: %w", call.Err))
		return
	}
	if err := call.Store(&created); err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("не удалось определить созданный раздел: %w", err))
		return
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 2
		item.Detail = "Подключаем новый раздел"
	})
	mountPoint, mountErr := mountFormattedDevice(connection, created)
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.State = "completed"
		if mountErr == nil {
			item.Destination = mountPoint
			item.Detail = "Раздел создан и подключён"
		} else {
			item.Detail = "Раздел создан. Подключите его кнопкой"
		}
	})
}

func (m *Manager) runDeletePartition(operationID string, region StorageRegion) {
	defer m.scheduleOperationExpiry(operationID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, region.Path)
	if err != nil {
		m.finishOperation(operationID, "failed", err)
		return
	}
	object := connection.Object("org.freedesktop.UDisks2", objectPath)
	if region.Mounted {
		m.updateOperation(operationID, func(item *Operation) { item.Detail = "Отключаем раздел" })
		call := object.Call("org.freedesktop.UDisks2.Filesystem.Unmount", dbus.FlagAllowInteractiveAuthorization, map[string]dbus.Variant{})
		if call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("не удалось отключить раздел: %w", call.Err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = "Удаляем раздел"
	})
	call := object.Call("org.freedesktop.UDisks2.Partition.Delete", dbus.FlagAllowInteractiveAuthorization,
		map[string]dbus.Variant{"tear-down": dbus.MakeVariant(true)})
	if call.Err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("не удалось удалить раздел: %w", call.Err))
		return
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.Detail = "Раздел удалён"
		item.State = "completed"
	})
}

func (m *Manager) runCreatePartitionTable(operationID string, disk StorageDisk, table string) {
	defer m.scheduleOperationExpiry(operationID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, disk.Path)
	if err != nil {
		m.finishOperation(operationID, "failed", err)
		return
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = "Создаём новую таблицу разделов"
	})
	call := connection.Object("org.freedesktop.UDisks2", objectPath).Call(
		"org.freedesktop.UDisks2.Block.Format", dbus.FlagAllowInteractiveAuthorization,
		table, map[string]dbus.Variant{"tear-down": dbus.MakeVariant(true)})
	if call.Err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("не удалось создать таблицу разделов: %w", call.Err))
		return
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.Detail = "Таблица разделов создана"
		item.State = "completed"
	})
}

func (m *Manager) runResizePartition(operationID string, region StorageRegion, sizeBytes int64) {
	defer m.scheduleOperationExpiry(operationID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, region.Path)
	if err != nil {
		m.finishOperation(operationID, "failed", err)
		return
	}
	object := connection.Object("org.freedesktop.UDisks2", objectPath)
	if region.Mounted {
		m.updateOperation(operationID, func(item *Operation) { item.Detail = "Отключаем раздел" })
		call := object.Call("org.freedesktop.UDisks2.Filesystem.Unmount", dbus.FlagAllowInteractiveAuthorization, map[string]dbus.Variant{})
		if call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("не удалось отключить раздел: %w", call.Err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = "Изменяем размер файловой системы"
	})
	options := map[string]dbus.Variant{}
	if sizeBytes < region.SizeBytes {
		if call := object.Call("org.freedesktop.UDisks2.Filesystem.Resize", dbus.FlagAllowInteractiveAuthorization, uint64(sizeBytes), options); call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("не удалось уменьшить файловую систему: %w", call.Err))
			return
		}
		m.updateOperation(operationID, func(item *Operation) { item.ProcessedBytes = 2; item.Detail = "Уменьшаем раздел" })
		if call := object.Call("org.freedesktop.UDisks2.Partition.Resize", dbus.FlagAllowInteractiveAuthorization, uint64(sizeBytes), options); call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("файловая система уменьшена, но границу раздела изменить не удалось: %w", call.Err))
			return
		}
	} else {
		if call := object.Call("org.freedesktop.UDisks2.Partition.Resize", dbus.FlagAllowInteractiveAuthorization, uint64(sizeBytes), options); call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("не удалось увеличить раздел: %w", call.Err))
			return
		}
		m.updateOperation(operationID, func(item *Operation) {
			item.ProcessedBytes = 2
			item.Detail = "Расширяем файловую систему"
		})
		if call := object.Call("org.freedesktop.UDisks2.Filesystem.Resize", dbus.FlagAllowInteractiveAuthorization, uint64(0), options); call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("раздел увеличен, но файловую систему расширить не удалось: %w", call.Err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) { item.ProcessedBytes = 3; item.Detail = "Завершаем операцию" })
	if region.Mounted {
		if _, err := mountFormattedDevice(connection, objectPath); err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("размер изменён, но подключить раздел обратно не удалось: %w", err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.Detail = "Размер раздела изменён"
		item.State = "completed"
	})
}

func (m *Manager) runFilesystemMaintenance(operationID string, region StorageRegion, repair bool) {
	defer m.scheduleOperationExpiry(operationID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()
	objectPath, err := resolveUDisksDevice(connection, region.Path)
	if err != nil {
		m.finishOperation(operationID, "failed", err)
		return
	}
	object := connection.Object("org.freedesktop.UDisks2", objectPath)
	if region.Mounted {
		m.updateOperation(operationID, func(item *Operation) { item.Detail = "Отключаем раздел" })
		call := object.Call("org.freedesktop.UDisks2.Filesystem.Unmount", dbus.FlagAllowInteractiveAuthorization, map[string]dbus.Variant{})
		if call.Err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("не удалось отключить раздел: %w", call.Err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = map[bool]string{true: "Исправляем файловую систему", false: "Проверяем файловую систему"}[repair]
	})
	method := "org.freedesktop.UDisks2.Filesystem.Check"
	if repair {
		method = "org.freedesktop.UDisks2.Filesystem.Repair"
	}
	var successful bool
	call := object.Call(method, dbus.FlagAllowInteractiveAuthorization, map[string]dbus.Variant{})
	if call.Err != nil {
		m.finishOperation(operationID, "failed", fmt.Errorf("операция с файловой системой не выполнена: %w", call.Err))
		return
	}
	if err := call.Store(&successful); err != nil || !successful {
		if err == nil {
			err = errors.New("файловая система требует дополнительного восстановления")
		}
		m.finishOperation(operationID, "failed", err)
		return
	}
	m.updateOperation(operationID, func(item *Operation) { item.ProcessedBytes = 2; item.Detail = "Завершаем операцию" })
	if region.Mounted {
		if _, err := mountFormattedDevice(connection, objectPath); err != nil {
			m.finishOperation(operationID, "failed", fmt.Errorf("операция выполнена, но подключить раздел обратно не удалось: %w", err))
			return
		}
	}
	m.updateOperation(operationID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.Detail = map[bool]string{true: "Файловая система исправлена", false: "Ошибок не найдено"}[repair]
		item.State = "completed"
	})
}

func (m *Manager) runFormat(operation *Operation, device Device, fileSystem, label string) {
	defer m.scheduleOperationExpiry(operation.ID)
	connection, err := dbus.ConnectSystemBus()
	if err != nil {
		m.finishOperation(operation.ID, "failed", fmt.Errorf("подключение к службе накопителей: %w", err))
		return
	}
	defer connection.Close()

	objectPath, err := resolveUDisksDevice(connection, device.Path)
	if err != nil {
		m.finishOperation(operation.ID, "failed", err)
		return
	}
	object := connection.Object("org.freedesktop.UDisks2", objectPath)
	interactive := dbus.FlagAllowInteractiveAuthorization
	if device.Mounted {
		call := object.Call("org.freedesktop.UDisks2.Filesystem.Unmount", interactive, map[string]dbus.Variant{})
		if call.Err != nil {
			m.finishOperation(operation.ID, "failed", fmt.Errorf("не удалось отключить накопитель: %w", call.Err))
			return
		}
	}
	m.updateOperation(operation.ID, func(item *Operation) {
		item.ProcessedBytes = 1
		item.Detail = "Создаём файловую систему " + formatDisplayName(fileSystem)
	})

	options := map[string]dbus.Variant{
		"update-partition-type": dbus.MakeVariant(true),
		"take-ownership":        dbus.MakeVariant(fileSystem == "ext4" || fileSystem == "btrfs"),
	}
	if label != "" {
		options["label"] = dbus.MakeVariant(label)
	}
	call := object.Call("org.freedesktop.UDisks2.Block.Format", interactive, fileSystem, options)
	if call.Err != nil {
		formatErr := fmt.Errorf("форматирование не выполнено: %w", call.Err)
		if device.Mounted {
			if _, mountErr := mountFormattedDevice(connection, objectPath); mountErr != nil {
				formatErr = fmt.Errorf("%w; накопитель также не удалось подключить обратно: %v", formatErr, mountErr)
			}
		}
		m.finishOperation(operation.ID, "failed", formatErr)
		return
	}
	m.updateOperation(operation.ID, func(item *Operation) {
		item.ProcessedBytes = 2
		item.Detail = "Подключаем готовый накопитель"
	})

	mountPoint, err := mountFormattedDevice(connection, objectPath)
	if err != nil {
		m.updateOperation(operation.ID, func(item *Operation) {
			item.ProcessedBytes = item.TotalBytes
			item.Detail = "Готово. Подключите накопитель кнопкой"
			item.State = "completed"
		})
		return
	}
	m.updateOperation(operation.ID, func(item *Operation) {
		item.ProcessedBytes = item.TotalBytes
		item.Destination = mountPoint
		item.Detail = "Накопитель готов"
		item.State = "completed"
	})
}

func resolveUDisksDevice(connection *dbus.Conn, devicePath string) (dbus.ObjectPath, error) {
	var devices []dbus.ObjectPath
	call := connection.Object("org.freedesktop.UDisks2", dbus.ObjectPath("/org/freedesktop/UDisks2/Manager")).Call(
		"org.freedesktop.UDisks2.Manager.ResolveDevice", 0,
		map[string]dbus.Variant{"path": dbus.MakeVariant(devicePath)}, map[string]dbus.Variant{})
	if call.Err != nil {
		return "", fmt.Errorf("поиск накопителя в UDisks: %w", call.Err)
	}
	if err := call.Store(&devices); err != nil {
		return "", fmt.Errorf("поиск накопителя в UDisks: %w", err)
	}
	if len(devices) != 1 || !devices[0].IsValid() {
		return "", errors.New("UDisks не смог однозначно определить накопитель")
	}
	return devices[0], nil
}

func mountFormattedDevice(connection *dbus.Conn, objectPath dbus.ObjectPath) (string, error) {
	object := connection.Object("org.freedesktop.UDisks2", objectPath)
	deadline := time.Now().Add(20 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		var mountPoint string
		call := object.Call("org.freedesktop.UDisks2.Filesystem.Mount", dbus.FlagAllowInteractiveAuthorization, map[string]dbus.Variant{})
		if call.Err == nil {
			if err := call.Store(&mountPoint); err == nil && mountPoint != "" {
				return mountPoint, nil
			} else if err != nil {
				lastErr = err
			}
		} else {
			lastErr = call.Err
		}
		time.Sleep(300 * time.Millisecond)
	}
	if lastErr == nil {
		lastErr = errors.New("точка подключения не появилась")
	}
	return "", lastErr
}

func formatDisplayName(fileSystem string) string {
	switch fileSystem {
	case "vfat":
		return "FAT32"
	case "exfat":
		return "exFAT"
	case "btrfs":
		return "Btrfs"
	case "ntfs":
		return "NTFS"
	default:
		return "EXT4"
	}
}

func (m *Manager) formatActiveForDevice(devicePath string) bool {
	m.operationsMu.RLock()
	defer m.operationsMu.RUnlock()
	return m.formatActiveForDeviceLocked(devicePath)
}

func (m *Manager) formatActiveForDeviceLocked(devicePath string) bool {
	for _, operation := range m.operations {
		if operation.Kind == "format" && operation.Source == devicePath && operation.State == "running" {
			return true
		}
	}
	return false
}

func (m *Manager) storageOperationActiveLocked() bool {
	for _, operation := range m.operations {
		if (operation.State == "running" || operation.State == "scanning") &&
			(operation.Kind == "format" || strings.HasPrefix(operation.Kind, "storage-")) {
			return true
		}
	}
	return false
}

func (m *Manager) storageOperationActive() bool {
	m.operationsMu.RLock()
	defer m.operationsMu.RUnlock()
	return m.storageOperationActiveLocked()
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
	disks, storageErr := m.Storage()
	if storageErr == nil {
		for _, disk := range disks {
			for _, region := range disk.Regions {
				if region.Path != path {
					continue
				}
				return Device{
					Name: region.Name, Path: region.Path, ParentPath: disk.Path,
					Label: region.Label, FileSystem: region.FileSystem,
					MountPoint: region.MountPoint, SizeBytes: region.SizeBytes,
					Removable: disk.Removable || disk.Hotplug, ReadOnly: disk.ReadOnly || region.ReadOnly,
					Mounted: region.Mounted, System: region.System, Layered: region.Layered,
					Compatibility: region.Compatibility,
				}, nil
			}
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
	if operation.Kind == "format" || strings.HasPrefix(operation.Kind, "storage-") {
		m.operationsMu.RUnlock()
		return errors.New("операцию с накопителем нельзя прерывать")
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
