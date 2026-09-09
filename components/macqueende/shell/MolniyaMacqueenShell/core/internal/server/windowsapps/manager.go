package windowsapps

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const releasesAPI = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases?per_page=100"

var (
	installerPattern = regexp.MustCompile(`(?i)(?:^|[\s._-])(?:setup|install(?:er)?|installshield)(?:$|[\s._-])`)
	tagNumberPattern = regexp.MustCompile(`\d+`)
	safeTagPattern   = regexp.MustCompile(`^[A-Za-z0-9._+-]+$`)
	safeNamePattern  = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
	appIDPattern     = regexp.MustCompile(`^[a-f0-9]{16}$`)
)

type Manager struct {
	mu         sync.RWMutex
	dataDir    string
	cacheDir   string
	apps       []App
	state      State
	cancel     context.CancelFunc
	processes  map[string]*exec.Cmd
	httpClient *http.Client
}

func NewManager() (*Manager, error) {
	dataHome, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	dataDir := filepath.Join(dataHome, ".local", "share", "kaskados", "windows-apps")
	cacheDir := filepath.Join(dataHome, ".cache", "kaskados", "windows-apps")
	for _, dir := range []string{dataDir, cacheDir, filepath.Join(dataDir, "runtimes"), filepath.Join(dataDir, "prefixes"), filepath.Join(dataDir, "logs")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	m := &Manager{
		dataDir: dataDir, cacheDir: cacheDir, state: State{Phase: "idle"},
		processes: make(map[string]*exec.Cmd),
		httpClient: &http.Client{
			CheckRedirect: validateReleaseRedirect,
			Transport: &http.Transport{
				Proxy:                 http.ProxyFromEnvironment,
				DialContext:           (&net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
				TLSHandshakeTimeout:   15 * time.Second,
				ResponseHeaderTimeout: 30 * time.Second,
				IdleConnTimeout:       90 * time.Second,
			},
		},
	}
	m.apps, _ = m.loadApps()
	return m, nil
}

func (m *Manager) Apps() []App {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return append([]App(nil), m.apps...)
}

func (m *Manager) Runtimes() []Runtime {
	managedRoot := filepath.Join(m.dataDir, "runtimes")
	roots := []string{
		managedRoot,
		filepath.Join(filepath.Dir(filepath.Dir(m.dataDir)), "proton-ge-manager", "runtimes"),
	}
	if home, err := os.UserHomeDir(); err == nil {
		roots = append(roots,
			filepath.Join(home, ".steam", "root", "compatibilitytools.d"),
			filepath.Join(home, ".local", "share", "Steam", "compatibilitytools.d"))
	}
	seen := make(map[string]bool)
	var runtimes []Runtime
	for _, root := range roots {
		matches, _ := filepath.Glob(filepath.Join(root, "*", "proton"))
		for _, proton := range matches {
			info, err := os.Stat(proton)
			if err != nil || !info.Mode().IsRegular() {
				continue
			}
			path := filepath.Dir(proton)
			tag := filepath.Base(path)
			if seen[tag] {
				continue
			}
			seen[tag] = true
			runtimes = append(runtimes, Runtime{
				Tag:     tag,
				Path:    path,
				Managed: withinChildRoot(managedRoot, path),
			})
		}
	}
	sort.SliceStable(runtimes, func(i, j int) bool { return newerVersionTag(runtimes[i].Tag, runtimes[j].Tag) })
	return runtimes
}

func (m *Manager) Releases() ([]Release, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, releasesAPI, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "KaskadOS-WindowsApps/0.1")
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GitHub API: %s", resp.Status)
	}
	var raw []struct {
		Tag         string `json:"tag_name"`
		PublishedAt string `json:"published_at"`
		PageURL     string `json:"html_url"`
		Prerelease  bool   `json:"prerelease"`
		Assets      []struct {
			Name string `json:"name"`
			URL  string `json:"browser_download_url"`
			Size int64  `json:"size"`
		} `json:"assets"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&raw); err != nil {
		return nil, err
	}
	installed := make(map[string]bool)
	for _, runtime := range m.Runtimes() {
		installed[runtime.Tag] = true
	}
	var releases []Release
	for _, entry := range raw {
		var archiveName, archiveURL, checksumURL string
		var archiveSize int64
		for _, asset := range entry.Assets {
			lowerName := strings.ToLower(asset.Name)
			wrongArchitecture := strings.Contains(lowerName, "aarch64") || strings.Contains(lowerName, "arm64")
			if archiveURL == "" && strings.HasSuffix(lowerName, ".tar.gz") && !wrongArchitecture {
				archiveName, archiveURL, archiveSize = asset.Name, asset.URL, asset.Size
			}
			if checksumURL == "" && (strings.HasSuffix(lowerName, ".sha512sum") || strings.HasSuffix(lowerName, ".sha512")) && !wrongArchitecture {
				checksumURL = asset.URL
			}
		}
		if entry.Tag == "" || archiveURL == "" || checksumURL == "" {
			continue
		}
		releases = append(releases, Release{
			Tag: entry.Tag, PublishedAt: entry.PublishedAt, PageURL: entry.PageURL,
			ArchiveURL: archiveURL, ArchiveName: archiveName, ArchiveSize: archiveSize,
			ChecksumURL: checksumURL, Prerelease: entry.Prerelease, Installed: installed[entry.Tag],
		})
	}
	return releases, nil
}

func (m *Manager) State() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	state := m.state
	if state.App != nil {
		app := *state.App
		state.App = &app
	}
	return state
}

func (m *Manager) Cancel() {
	m.mu.Lock()
	cancel := m.cancel
	var process *exec.Cmd
	if m.state.App != nil {
		process = m.processes[m.state.App.ID]
	}
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if process != nil && process.Process != nil {
		_ = syscall.Kill(-process.Process.Pid, syscall.SIGTERM)
	}
}

func (m *Manager) InstallRuntime(release Release) error {
	if release.Tag == "" || release.ArchiveURL == "" || release.ChecksumURL == "" || !safeTag(release.Tag) || !safeArchiveName(release.ArchiveName) || !trustedReleaseURL(release.ArchiveURL) {
		return errors.New("некорректный выпуск Proton")
	}
	if !trustedReleaseURL(release.ChecksumURL) {
		return errors.New("некорректная ссылка контрольной суммы")
	}
	return m.startOperation("Загрузка "+release.Tag, nil, func(ctx context.Context) error {
		archive := filepath.Join(m.cacheDir, release.ArchiveName)
		defer os.Remove(archive)
		if err := m.download(ctx, release.ArchiveURL, archive); err != nil {
			return err
		}
		m.setMessage("Проверка SHA-512")
		expected, err := m.fetchChecksum(ctx, release.ChecksumURL, release.ArchiveName)
		if err != nil {
			return err
		}
		if err := verifySHA512(archive, expected); err != nil {
			return err
		}
		m.setMessage("Распаковка " + release.Tag)
		return extractRuntime(archive, filepath.Join(m.dataDir, "runtimes"), release.Tag)
	})
}

func (m *Manager) OpenExecutable(path, runtimeTag string) error {
	exe, err := validateExecutable(path)
	if err != nil {
		return err
	}
	runtime, err := m.runtime(runtimeTag)
	if err != nil {
		return err
	}
	prefix := m.prefixFor(exe, runtime.Tag)
	app := App{
		ID: appID(exe), Name: strings.TrimSuffix(filepath.Base(exe), filepath.Ext(exe)),
		Executable: exe, Prefix: prefix, RuntimePath: runtime.Path, RuntimeTag: runtime.Tag,
		Kind: "windows", InstalledAt: time.Now().Unix(),
	}
	if installerPattern.MatchString(strings.TrimSuffix(strings.ToLower(filepath.Base(exe)), filepath.Ext(exe))) {
		return m.runInstaller(app)
	}
	if err := m.upsertApp(app); err != nil {
		return err
	}
	return m.Launch(app.ID)
}

func (m *Manager) SetRuntime(id, runtimeTag string) error {
	runtime, err := m.runtime(runtimeTag)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	selectedIndex := -1
	for i := range m.apps {
		if m.apps[i].ID == id {
			selectedIndex = i
			break
		}
	}
	_, running := m.processes[id]
	if selectedIndex < 0 {
		return errors.New("Windows-приложение не найдено")
	}
	if running {
		return errors.New("сначала закройте запущенное Windows-приложение")
	}
	if info, statErr := os.Stat(filepath.Join(runtime.Path, "proton")); statErr != nil || !info.Mode().IsRegular() {
		return errors.New("выбранная версия Proton недоступна")
	}
	original := m.apps[selectedIndex]
	m.apps[selectedIndex].RuntimePath = runtime.Path
	m.apps[selectedIndex].RuntimeTag = runtime.Tag
	if !withinChildRoot(m.apps[selectedIndex].Prefix, m.apps[selectedIndex].Executable) {
		m.apps[selectedIndex].Prefix = m.prefixFor(m.apps[selectedIndex].Executable, runtime.Tag)
	}
	if err := m.saveAppsLocked(); err != nil {
		m.apps[selectedIndex] = original
		return err
	}
	if err := m.writeDesktop(m.apps[selectedIndex]); err != nil {
		m.apps[selectedIndex] = original
		_ = m.saveAppsLocked()
		return err
	}
	return nil
}

func (m *Manager) RemoveRuntime(runtimeTag string) error {
	if !safeTag(runtimeTag) {
		return errors.New("некорректная версия Proton")
	}
	managedRoot := filepath.Join(m.dataDir, "runtimes")
	target := filepath.Join(managedRoot, runtimeTag)
	if !withinChildRoot(managedRoot, target) || filepath.Base(target) != runtimeTag {
		return errors.New("эту версию Proton нельзя удалить здесь")
	}
	info, err := os.Stat(filepath.Join(target, "proton"))
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("установленная версия Proton не найдена")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.state.Phase == "preparing" || m.state.Phase == "downloading" {
		return errors.New("дождитесь завершения установки Proton")
	}
	if m.state.App != nil && (m.state.Phase == "starting" || m.state.Phase == "running") && filepath.Clean(m.state.App.RuntimePath) == filepath.Clean(target) {
		return errors.New("сначала закройте приложение, использующее эту версию Proton")
	}
	for _, app := range m.apps {
		if filepath.Clean(app.RuntimePath) == filepath.Clean(target) {
			return fmt.Errorf("сначала выберите другую версию Proton для %s", app.Name)
		}
	}
	if err := os.RemoveAll(target); err != nil {
		return err
	}
	for _, pattern := range []string{runtimeTag + ".tar.gz", runtimeTag + "*.tar.gz"} {
		matches, _ := filepath.Glob(filepath.Join(m.cacheDir, pattern))
		for _, cached := range matches {
			if withinChildRoot(m.cacheDir, cached) {
				_ = os.Remove(cached)
			}
		}
	}
	return nil
}

func (m *Manager) runtime(runtimeTag string) (Runtime, error) {
	runtimes := m.Runtimes()
	if len(runtimes) == 0 {
		return Runtime{}, errors.New("сначала установите хотя бы одну версию GE-Proton")
	}
	if runtimeTag == "" {
		return runtimes[0], nil
	}
	if !safeTag(runtimeTag) {
		return Runtime{}, errors.New("некорректная версия Proton")
	}
	for _, runtime := range runtimes {
		if runtime.Tag == runtimeTag {
			return runtime, nil
		}
	}
	return Runtime{}, errors.New("выбранная версия Proton не установлена")
}

func (m *Manager) Launch(id string) error {
	m.mu.RLock()
	var selected *App
	for i := range m.apps {
		if m.apps[i].ID == id {
			app := m.apps[i]
			selected = &app
			break
		}
	}
	m.mu.RUnlock()
	if selected == nil {
		return errors.New("Windows-приложение не найдено")
	}
	if _, err := validateExecutable(selected.Executable); err != nil {
		return err
	}
	if !withinChildRoot(selected.Prefix, selected.Executable) {
		expectedPrefix := m.prefixFor(selected.Executable, selected.RuntimeTag)
		if filepath.Clean(selected.Prefix) != filepath.Clean(expectedPrefix) {
			m.mu.Lock()
			for i := range m.apps {
				if m.apps[i].ID == selected.ID {
					originalPrefix := m.apps[i].Prefix
					m.apps[i].Prefix = expectedPrefix
					if err := m.saveAppsLocked(); err != nil {
						m.apps[i].Prefix = originalPrefix
						m.mu.Unlock()
						return err
					}
					selected.Prefix = expectedPrefix
					break
				}
			}
			m.mu.Unlock()
		}
	}
	return m.launchApp(*selected, false, nil)
}

func (m *Manager) Remove(id string, removePrefix bool) error {
	m.mu.Lock()
	var app App
	for i := range m.apps {
		if m.apps[i].ID == id {
			app = m.apps[i]
			break
		}
	}
	if app.ID == "" {
		m.mu.Unlock()
		return errors.New("Windows-приложение не найдено")
	}
	for appID := range m.processes {
		for _, candidate := range m.apps {
			if candidate.ID == appID && (candidate.ID == id || (removePrefix && candidate.Prefix == app.Prefix)) {
				m.mu.Unlock()
				return errors.New("сначала закройте запущенное Windows-приложение")
			}
		}
	}
	original := append([]App(nil), m.apps...)
	removed := make([]App, 0, 1)
	kept := make([]App, 0, len(m.apps))
	for _, candidate := range m.apps {
		if candidate.ID == id || (removePrefix && candidate.Prefix == app.Prefix) {
			removed = append(removed, candidate)
			continue
		}
		kept = append(kept, candidate)
	}
	m.apps = kept
	err := m.saveAppsLocked()
	if err != nil {
		m.apps = original
	}
	m.mu.Unlock()
	if err != nil {
		return err
	}
	for _, candidate := range removed {
		_ = os.Remove(m.desktopPath(candidate.ID))
	}
	if removePrefix {
		allowedRoot := filepath.Join(m.dataDir, "prefixes")
		if withinChildRoot(allowedRoot, app.Prefix) {
			if err := os.RemoveAll(app.Prefix); err != nil {
				return err
			}
		}
	}
	return nil
}

func (m *Manager) runInstaller(installer App) error {
	before := scanPrefixExecutables(installer.Prefix)
	return m.launchApp(installer, true, func() {
		after := scanPrefixExecutables(installer.Prefix)
		var discovered []string
		for path := range after {
			if !before[path] && usefulExecutable(path) {
				discovered = append(discovered, path)
			}
		}
		sort.Strings(discovered)
		for _, path := range discovered {
			app := App{
				ID: appID(path), Name: friendlyWindowsName(path), Executable: path,
				Prefix: installer.Prefix, RuntimePath: installer.RuntimePath, RuntimeTag: installer.RuntimeTag,
				Kind: "windows", InstalledAt: time.Now().Unix(),
			}
			_ = m.upsertApp(app)
		}
		if len(discovered) > 0 {
			m.setMessage(fmt.Sprintf("Установка завершена, найдено приложений: %d", len(discovered)))
		} else {
			m.setMessage("Установщик завершён. Приложение можно добавить из его EXE-файла.")
		}
	})
}

func (m *Manager) launchApp(app App, installer bool, after func()) error {
	if _, err := exec.LookPath("umu-run"); err != nil {
		return errors.New("не установлен umu-launcher")
	}
	if _, err := os.Stat(filepath.Join(app.RuntimePath, "proton")); err != nil {
		return errors.New("выбранная версия Proton недоступна")
	}
	if err := os.MkdirAll(app.Prefix, 0o755); err != nil {
		return err
	}
	m.mu.RLock()
	_, alreadyRunning := m.processes[app.ID]
	m.mu.RUnlock()
	if alreadyRunning {
		return errors.New("приложение уже запускается или работает")
	}
	logPath := filepath.Join(m.dataDir, "logs", app.ID+"-"+time.Now().Format("20060102-150405")+".log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	cmd := exec.Command("umu-run", app.Executable)
	cmd.Dir = filepath.Dir(app.Executable)
	cmd.Env = append(os.Environ(),
		"WINEPREFIX="+app.Prefix,
		"PROTONPATH="+app.RuntimePath,
		"GAMEID=umu-default",
		"STORE=none",
	)
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return err
	}
	m.mu.Lock()
	m.processes[app.ID] = cmd
	m.state = State{Phase: "starting", Message: "Запускается: " + app.Name, App: &app, StartedUnix: time.Now().Unix(), LogPath: logPath}
	m.mu.Unlock()

	go func() {
		started := time.NewTimer(12 * time.Second)
		done := make(chan error, 1)
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			started.Stop()
			logFile.Close()
			m.finishProcess(app, err, installer, after)
		case <-started.C:
			m.mu.Lock()
			if m.state.App != nil && m.state.App.ID == app.ID && m.state.Phase == "starting" {
				m.state.Phase = "running"
				m.state.Message = "Работает: " + app.Name
			}
			m.mu.Unlock()
			err := <-done
			logFile.Close()
			m.finishProcess(app, err, installer, after)
		}
	}()
	return nil
}

func (m *Manager) finishProcess(app App, err error, installer bool, after func()) {
	m.mu.Lock()
	delete(m.processes, app.ID)
	if m.state.App != nil && m.state.App.ID == app.ID {
		m.state.FinishedUnix = time.Now().Unix()
		if err != nil {
			m.state.Phase = "error"
			m.state.Message = "Не удалось запустить " + app.Name
		} else {
			m.state.Phase = "complete"
			m.state.Message = "Работа завершена: " + app.Name
		}
	}
	m.mu.Unlock()
	if installer && after != nil && err == nil {
		after()
	}
}

func (m *Manager) startOperation(message string, app *App, operation func(context.Context) error) error {
	m.mu.Lock()
	if m.state.Phase == "downloading" || m.state.Phase == "preparing" {
		m.mu.Unlock()
		return errors.New("другая операция уже выполняется")
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.state = State{Phase: "preparing", Message: message, App: app, StartedUnix: time.Now().Unix()}
	m.mu.Unlock()
	go func() {
		err := operation(ctx)
		m.mu.Lock()
		m.cancel = nil
		m.state.FinishedUnix = time.Now().Unix()
		if err != nil {
			m.state.Phase = "error"
			m.state.Message = "Операция не завершена"
		} else {
			m.state.Phase = "complete"
			if m.state.Message == message || strings.HasPrefix(m.state.Message, "Проверка") || strings.HasPrefix(m.state.Message, "Распаковка") {
				m.state.Message = "Готово"
			}
			m.state.Progress = 100
		}
		m.mu.Unlock()
	}()
	return nil
}

func (m *Manager) setMessage(message string) {
	m.mu.Lock()
	m.state.Message = message
	m.mu.Unlock()
}

func (m *Manager) download(ctx context.Context, source, destination string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return err
	}
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download: %s", resp.Status)
	}
	partial := destination + ".part"
	out, err := os.OpenFile(partial, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer func() { out.Close(); _ = os.Remove(partial) }()
	buf := make([]byte, 1024*1024)
	var received int64
	for {
		n, readErr := resp.Body.Read(buf)
		if n > 0 {
			if _, err := out.Write(buf[:n]); err != nil {
				return err
			}
			received += int64(n)
			if resp.ContentLength > 0 {
				m.mu.Lock()
				m.state.Phase = "downloading"
				m.state.Progress = min(99, int(received*100/resp.ContentLength))
				m.mu.Unlock()
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return readErr
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(partial, destination)
}

func (m *Manager) fetchChecksum(ctx context.Context, source, archiveName string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return "", err
	}
	resp, err := m.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("checksum: %s", resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024))
	if err != nil {
		return "", err
	}
	for line := range strings.SplitSeq(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && len(fields[0]) == 128 && (len(fields) == 1 || filepath.Base(strings.TrimLeft(fields[len(fields)-1], "*")) == archiveName) {
			return strings.ToLower(fields[0]), nil
		}
	}
	return "", errors.New("SHA-512 для архива не найден")
}

func (m *Manager) prefixFor(exe, runtimeTag string) string {
	hash := sha256.Sum256([]byte(exe))
	base := strings.TrimSuffix(filepath.Base(exe), filepath.Ext(exe))
	base = safeNamePattern.ReplaceAllString(base, "-")
	if base == "" {
		base = "windows-app"
	}
	return filepath.Join(m.dataDir, "prefixes", base+"-"+hex.EncodeToString(hash[:5])+"-"+runtimeFamily(runtimeTag))
}

func runtimeFamily(runtimeTag string) string {
	normalized := strings.ToLower(runtimeTag)
	if strings.Contains(normalized, "proton") {
		if major := tagNumberPattern.FindString(normalized); major != "" {
			return "proton-" + major
		}
	}
	normalized = strings.Trim(safeNamePattern.ReplaceAllString(normalized, "-"), "-.")
	if normalized == "" {
		return "runtime"
	}
	return normalized
}

func (m *Manager) registryPath() string { return filepath.Join(m.dataDir, "apps.json") }

func (m *Manager) loadApps() ([]App, error) {
	data, err := os.ReadFile(m.registryPath())
	if errors.Is(err, os.ErrNotExist) {
		return []App{}, nil
	}
	if err != nil {
		return nil, err
	}
	var apps []App
	if err := json.Unmarshal(data, &apps); err != nil {
		return nil, err
	}
	valid := make([]App, 0, len(apps))
	for _, app := range apps {
		if !appIDPattern.MatchString(app.ID) || !filepath.IsAbs(app.Executable) || !filepath.IsAbs(app.RuntimePath) || !withinChildRoot(filepath.Join(m.dataDir, "prefixes"), app.Prefix) {
			continue
		}
		valid = append(valid, app)
	}
	return valid, nil
}

func (m *Manager) upsertApp(app App) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	original := append([]App(nil), m.apps...)
	found := false
	for i := range m.apps {
		if m.apps[i].ID == app.ID {
			m.apps[i], found = app, true
			break
		}
	}
	if !found {
		m.apps = append(m.apps, app)
	}
	if err := m.saveAppsLocked(); err != nil {
		m.apps = original
		return err
	}
	if err := m.writeDesktop(app); err != nil {
		m.apps = original
		_ = m.saveAppsLocked()
		return err
	}
	return nil
}

func (m *Manager) saveAppsLocked() error {
	data, err := json.MarshalIndent(m.apps, "", "  ")
	if err != nil {
		return err
	}
	tmp := m.registryPath() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, m.registryPath())
}

func (m *Manager) desktopPath(id string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "applications", "kaskados-windows-"+id+".desktop")
}

func (m *Manager) writeDesktop(app App) error {
	path := m.desktopPath(app.ID)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	name := strings.NewReplacer("\n", " ", "\r", " ").Replace(app.Name)
	content := fmt.Sprintf("[Desktop Entry]\nType=Application\nName=%s\nComment=Windows-приложение через GE-Proton\nExec=dms windows launch %s\nIcon=application-x-ms-dos-executable\nTerminal=false\nCategories=Game;Utility;\nX-KaskadOS-Source=windows\n", name, app.ID)
	return os.WriteFile(path, []byte(content), 0o644)
}

func verifySHA512(path, expected string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	hash := sha512.New()
	if _, err := io.Copy(hash, file); err != nil {
		return err
	}
	if hex.EncodeToString(hash.Sum(nil)) != strings.ToLower(expected) {
		return errors.New("SHA-512 не совпадает")
	}
	return nil
}

func extractRuntime(archive, targetRoot, tag string) error {
	if !safeTag(tag) {
		return errors.New("некорректное имя версии")
	}
	if err := os.MkdirAll(targetRoot, 0o755); err != nil {
		return err
	}
	destination := filepath.Join(targetRoot, tag)
	if _, err := os.Stat(destination); err == nil {
		return errors.New("эта версия Proton уже установлена")
	}
	temp, err := os.MkdirTemp(targetRoot, ".extract-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temp)
	file, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()
	reader := tar.NewReader(gz)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		clean := filepath.Clean(header.Name)
		if filepath.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			return errors.New("небезопасный путь в архиве")
		}
		path := filepath.Join(temp, clean)
		if !withinRoot(temp, path) {
			return errors.New("путь выходит за каталог распаковки")
		}
		if !archiveParentsSafe(temp, path) {
			return errors.New("путь проходит через ссылку внутри архива")
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(path, os.FileMode(header.Mode)&0o755); err != nil {
				return err
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			out, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode)&0o755)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(out, reader)
			closeErr := out.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
		case tar.TypeSymlink:
			if filepath.IsAbs(header.Linkname) {
				return errors.New("небезопасная ссылка в архиве")
			}
			linkTarget := filepath.Clean(filepath.Join(filepath.Dir(path), header.Linkname))
			if !withinRoot(temp, linkTarget) {
				return errors.New("ссылка выходит за каталог распаковки")
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.Symlink(header.Linkname, path); err != nil {
				return err
			}
		case tar.TypeLink:
			if filepath.IsAbs(header.Linkname) {
				return errors.New("небезопасная жёсткая ссылка в архиве")
			}
			linkTarget := filepath.Join(temp, filepath.Clean(header.Linkname))
			if !withinRoot(temp, linkTarget) || !archiveParentsSafe(temp, linkTarget) {
				return errors.New("жёсткая ссылка выходит за каталог распаковки")
			}
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				return err
			}
			if err := os.Link(linkTarget, path); err != nil {
				return err
			}
		}
	}
	protons, _ := filepath.Glob(filepath.Join(temp, "*", "proton"))
	if len(protons) != 1 {
		return errors.New("архив не содержит ожидаемый файл proton")
	}
	source := filepath.Dir(protons[0])
	return os.Rename(source, destination)
}

func validateExecutable(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("нужен абсолютный путь к EXE")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	if strings.ToLower(filepath.Ext(resolved)) != ".exe" {
		return "", errors.New("выбранный файл не является EXE")
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("EXE-файл недоступен")
	}
	return resolved, nil
}

func scanPrefixExecutables(prefix string) map[string]bool {
	result := make(map[string]bool)
	root := filepath.Join(prefix, "pfx", "drive_c")
	_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() && strings.EqualFold(entry.Name(), "windows") {
			return filepath.SkipDir
		}
		if !entry.IsDir() && strings.EqualFold(filepath.Ext(path), ".exe") {
			result[path] = true
		}
		return nil
	})
	return result
}

func usefulExecutable(path string) bool {
	name := strings.ToLower(filepath.Base(path))
	for _, fragment := range []string{"unins", "uninstall", "updater", "update.exe", "crash", "helper", "service", "vc_redist", "dxsetup"} {
		if strings.Contains(name, fragment) {
			return false
		}
	}
	return strings.Contains(strings.ToLower(path), "program files") || strings.Contains(strings.ToLower(path), "users")
}

func friendlyWindowsName(path string) string {
	name := strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
	name = strings.NewReplacer("_", " ", "-", " ").Replace(name)
	return strings.TrimSpace(name)
}

func appID(path string) string {
	hash := sha256.Sum256([]byte(path))
	return hex.EncodeToString(hash[:8])
}

func safeTag(tag string) bool {
	return safeTagPattern.MatchString(tag)
}

func safeArchiveName(name string) bool {
	return name != "" && filepath.Base(name) == name && strings.HasSuffix(strings.ToLower(name), ".tar.gz")
}

func newerVersionTag(left, right string) bool {
	leftNumbers := tagNumberPattern.FindAllString(left, -1)
	rightNumbers := tagNumberPattern.FindAllString(right, -1)
	for index := 0; index < max(len(leftNumbers), len(rightNumbers)); index++ {
		leftPart, rightPart := 0, 0
		if index < len(leftNumbers) {
			_, _ = fmt.Sscanf(leftNumbers[index], "%d", &leftPart)
		}
		if index < len(rightNumbers) {
			_, _ = fmt.Sscanf(rightNumbers[index], "%d", &rightPart)
		}
		if leftPart != rightPart {
			return leftPart > rightPart
		}
	}
	return left > right
}

func trustedReleaseURL(raw string) bool {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	return host == "github.com" || strings.HasSuffix(host, ".githubusercontent.com")
}

func validateReleaseRedirect(req *http.Request, via []*http.Request) error {
	if len(via) > 10 || !trustedReleaseURL(req.URL.String()) {
		return errors.New("небезопасное перенаправление загрузки")
	}
	return nil
}

func withinRoot(root, path string) bool {
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	pathAbs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(rootAbs, pathAbs)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func withinChildRoot(root, path string) bool {
	if !withinRoot(root, path) {
		return false
	}
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	pathAbs, err := filepath.Abs(path)
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(rootAbs, pathAbs)
	return err == nil && rel != "."
}

func archiveParentsSafe(root, path string) bool {
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return false
	}
	parentAbs, err := filepath.Abs(filepath.Dir(path))
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(rootAbs, parentAbs)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return false
	}
	current := rootAbs
	if rel == "." {
		return true
	}
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		current = filepath.Join(current, part)
		info, statErr := os.Lstat(current)
		if errors.Is(statErr, os.ErrNotExist) {
			return true
		}
		if statErr != nil || info.Mode()&os.ModeSymlink != 0 {
			return false
		}
	}
	return true
}
