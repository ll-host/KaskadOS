package files

import (
	"context"
	"errors"
	"fmt"
	"mime"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
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

type Manager struct {
	mu          sync.RWMutex
	subscribers map[string]chan Event
}

func NewManager() *Manager {
	return &Manager{subscribers: make(map[string]chan Event)}
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
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "gio", "trash", resolved).CombinedOutput()
	if err != nil {
		return fmt.Errorf("gio trash: %w (%s)", err, strings.TrimSpace(string(out)))
	}
	return nil
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
