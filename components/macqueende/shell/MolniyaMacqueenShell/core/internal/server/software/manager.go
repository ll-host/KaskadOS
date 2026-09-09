package software

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

var packageNamePattern = regexp.MustCompile(`^[A-Za-z0-9@._+:-]+$`)

type Manager struct {
	mu      sync.RWMutex
	catalog *Catalog
	state   OperationState
	cancel  context.CancelFunc
	dataDir string
	sources map[string]Source
}

func NewManager() *Manager {
	home, _ := os.UserHomeDir()
	dataDir := filepath.Join(home, ".local", "share", "kaskados", "software")
	_ = os.MkdirAll(dataDir, 0o755)
	m := &Manager{
		catalog: NewCatalog(), state: OperationState{Phase: PhaseIdle},
		dataDir: dataDir, sources: make(map[string]Source),
	}
	m.loadSources()
	return m
}

func (m *Manager) Search(query string, source Source) SearchResult {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	return m.catalog.Search(ctx, query, source)
}

func (m *Manager) Installed() SearchResult {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	m.mu.RLock()
	provenance := make(map[string]Source, len(m.sources))
	for name, source := range m.sources {
		provenance[name] = source
	}
	m.mu.RUnlock()
	return m.catalog.Installed(ctx, provenance)
}

func (m *Manager) State() OperationState {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneState(m.state)
}

func (m *Manager) Cancel() {
	m.mu.Lock()
	cancel := m.cancel
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (m *Manager) Install(item Item) error {
	if err := validateItem(item); err != nil {
		return err
	}
	return m.start("install", item, func(ctx context.Context, logf func(string)) error {
		switch item.Source {
		case SourcePacman:
			err := runLogged(ctx, logf, "pkexec", "pacman", "-Syu", "--needed", "--noconfirm", item.PackageName)
			if err == nil {
				m.setSource(item.PackageName, "")
			}
			return err
		case SourceFlatpak:
			if err := runLogged(ctx, logf, "flatpak", "remote-add", "--user", "--if-not-exists", "flathub", "https://dl.flathub.org/repo/flathub.flatpakrepo"); err != nil {
				return err
			}
			return runLogged(ctx, logf, "flatpak", "install", "--user", "--noninteractive", "-y", item.RemoteOr("flathub"), item.ID)
		case SourceAUR:
			err := m.installAUR(ctx, item.PackageName, map[string]bool{}, logf)
			if err == nil {
				m.setSource(item.PackageName, SourceAUR)
			}
			return err
		default:
			return fmt.Errorf("unsupported source %q", item.Source)
		}
	})
}

func (m *Manager) Remove(item Item) error {
	if err := validateItem(item); err != nil {
		return err
	}
	if item.Source != SourceFlatpak && protectedPackage(item.PackageName) {
		return errors.New("этот системный пакет защищён от удаления через меню")
	}
	return m.start("remove", item, func(ctx context.Context, logf func(string)) error {
		if item.Source == SourceFlatpak {
			args := []string{"flatpak", "uninstall", "--system", "--noninteractive", "-y", item.ID}
			if !flatpakSystemInstalled(ctx, item.ID) {
				args = []string{"flatpak", "uninstall", "--user", "--noninteractive", "-y", item.ID}
				return runLogged(ctx, logf, args...)
			}
			return runLogged(ctx, logf, append([]string{"pkexec"}, args...)...)
		}
		err := runLogged(ctx, logf, "pkexec", "pacman", "-R", "--noconfirm", item.PackageName)
		if err == nil {
			m.setSource(item.PackageName, "")
		}
		return err
	})
}

func (m *Manager) InstallLocal(path string) error {
	resolved, err := validateLocalPackage(path)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	packageName, err := localPackageName(ctx, resolved)
	if err != nil {
		return err
	}
	item := Item{ID: packageName, PackageName: packageName, Name: packageName, Source: SourceLocal}
	return m.start("install-local", item, func(ctx context.Context, logf func(string)) error {
		err := runLogged(ctx, logf, "pkexec", "pacman", "-U", "--needed", "--noconfirm", resolved)
		if err == nil {
			m.setSource(packageName, SourceLocal)
		}
		return err
	})
}

func localPackageName(ctx context.Context, path string) (string, error) {
	out, err := exec.CommandContext(ctx, "pacman", "-Qp", "--print-format", "%n", path).Output()
	if err != nil {
		return "", errors.New("не удалось прочитать имя локального пакета")
	}
	name := strings.TrimSpace(string(out))
	if !packageNamePattern.MatchString(name) {
		return "", errors.New("локальный пакет содержит некорректное имя")
	}
	return name, nil
}

func (m *Manager) sourcesPath() string {
	return filepath.Join(m.dataDir, "sources.json")
}

func (m *Manager) loadSources() {
	raw, err := os.ReadFile(m.sourcesPath())
	if err != nil {
		return
	}
	var stored map[string]Source
	if json.Unmarshal(raw, &stored) != nil {
		return
	}
	for name, source := range stored {
		if packageNamePattern.MatchString(name) && (source == SourceAUR || source == SourceLocal) {
			m.sources[name] = source
		}
	}
}

func (m *Manager) setSource(name string, source Source) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if source == "" {
		delete(m.sources, name)
	} else {
		m.sources[name] = source
	}
	raw, err := json.MarshalIndent(m.sources, "", "  ")
	if err != nil {
		return
	}
	tmp := m.sourcesPath() + ".tmp"
	if os.WriteFile(tmp, raw, 0o600) == nil {
		_ = os.Rename(tmp, m.sourcesPath())
	}
}

func (m *Manager) start(action string, item Item, operation func(context.Context, func(string)) error) error {
	m.mu.Lock()
	if m.state.Phase == PhasePreparing || m.state.Phase == PhaseRunning {
		m.mu.Unlock()
		return errors.New("другая операция с приложениями уже выполняется")
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.cancel = cancel
	m.state = OperationState{Phase: PhasePreparing, Action: action, Item: &item, Message: "Подготовка", StartedUnix: time.Now().Unix(), RecentLog: []string{}}
	m.mu.Unlock()

	go func() {
		m.setPhase(PhaseRunning, operationLabel(action))
		err := operation(ctx, m.appendLog)
		if err != nil {
			m.appendLog(err.Error())
			message := "Операция не завершена"
			if errors.Is(ctx.Err(), context.Canceled) {
				message = "Операция отменена"
			}
			m.finish(PhaseError, message)
			return
		}
		m.finish(PhaseComplete, successLabel(action))
	}()
	return nil
}

func (m *Manager) setPhase(phase Phase, message string) {
	m.mu.Lock()
	m.state.Phase = phase
	m.state.Message = message
	m.mu.Unlock()
}

func (m *Manager) finish(phase Phase, message string) {
	m.mu.Lock()
	m.state.Phase = phase
	m.state.Message = message
	m.state.EndedUnix = time.Now().Unix()
	m.cancel = nil
	m.mu.Unlock()
}

func (m *Manager) appendLog(line string) {
	line = strings.TrimSpace(line)
	if line == "" {
		return
	}
	if len(line) > 500 {
		line = line[:500]
	}
	m.mu.Lock()
	m.state.RecentLog = append(m.state.RecentLog, line)
	if len(m.state.RecentLog) > 80 {
		m.state.RecentLog = append([]string(nil), m.state.RecentLog[len(m.state.RecentLog)-80:]...)
	}
	m.mu.Unlock()
}

func (m *Manager) installAUR(ctx context.Context, name string, visiting map[string]bool, logf func(string)) error {
	if visiting[name] {
		return fmt.Errorf("циклическая AUR-зависимость: %s", name)
	}
	visiting[name] = true
	defer delete(visiting, name)
	packageBase, err := m.catalog.aurPackageBase(ctx, name)
	if err != nil {
		return err
	}

	cacheRoot, err := os.UserCacheDir()
	if err != nil {
		return err
	}
	workRoot := filepath.Join(cacheRoot, "kaskados", "software", "aur")
	if err := os.MkdirAll(workRoot, 0o755); err != nil {
		return err
	}
	workDir := filepath.Join(workRoot, packageBase)
	if err := os.RemoveAll(workDir); err != nil {
		return err
	}
	logf("Получение исходников AUR: " + packageBase)
	if err := runLogged(ctx, logf, "git", "clone", "--depth=1", "https://aur.archlinux.org/"+packageBase+".git", workDir); err != nil {
		return err
	}

	srcinfo, err := outputInDir(ctx, workDir, "makepkg", "--printsrcinfo")
	if err != nil {
		return fmt.Errorf("не удалось прочитать .SRCINFO: %w", err)
	}
	deps := parseSRCINFODependencies(srcinfo)
	missing := missingDependencies(ctx, deps)
	var official []string
	var aur []string
	for _, dep := range missing {
		base := dependencyName(dep)
		if base == "" || base == name {
			continue
		}
		if packageInRepos(ctx, base) {
			official = append(official, base)
		} else {
			aur = append(aur, base)
		}
	}
	official = uniqueStrings(official)
	aur = uniqueStrings(aur)
	if len(official) > 0 {
		logf("Установка зависимостей из репозиториев")
		args := append([]string{"pkexec", "pacman", "-Syu", "--needed", "--noconfirm"}, official...)
		if err := runLogged(ctx, logf, args...); err != nil {
			return err
		}
	}
	for _, dep := range aur {
		if err := m.installAUR(ctx, dep, visiting, logf); err != nil {
			return err
		}
	}

	logf("Сборка AUR-пакета: " + name)
	if err := runLoggedInDir(ctx, workDir, logf, "makepkg", "--cleanbuild", "--force", "--nodeps", "--noconfirm"); err != nil {
		return err
	}
	packages, err := builtPackages(workDir)
	if err != nil {
		return err
	}
	args := append([]string{"pkexec", "pacman", "-U", "--needed", "--noconfirm"}, packages...)
	if err := runLogged(ctx, logf, args...); err != nil {
		return err
	}
	for _, packagePath := range packages {
		packageName, packageErr := localPackageName(ctx, packagePath)
		if packageErr == nil {
			m.setSource(packageName, SourceAUR)
		}
	}
	return nil
}

func validateItem(item Item) error {
	if item.PackageName == "" || !packageNamePattern.MatchString(item.PackageName) {
		return errors.New("некорректное имя пакета")
	}
	if item.ID == "" {
		item.ID = item.PackageName
	}
	if !packageNamePattern.MatchString(item.ID) {
		return errors.New("некорректный идентификатор приложения")
	}
	return nil
}

func validateLocalPackage(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", errors.New("нужен абсолютный путь к пакету")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`\.pkg\.tar\.(?:zst|xz|gz|bz2|lz4|lrz|lzo|Z)$`).MatchString(filepath.Base(resolved)) {
		return "", errors.New("выбранный файл не является пакетом Arch Linux")
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", errors.New("путь не указывает на обычный файл")
	}
	return resolved, nil
}

func protectedPackage(name string) bool {
	if strings.HasPrefix(name, "kaskados-") || strings.HasPrefix(name, "macqueen") {
		return true
	}
	switch name {
	case "base", "filesystem", "glibc", "linux", "linux-firmware", "pacman", "systemd", "sudo", "polkit", "sddm", "grub":
		return true
	default:
		return false
	}
}

func runLogged(ctx context.Context, logf func(string), argv ...string) error {
	return runLoggedInDir(ctx, "", logf, argv...)
}

func runLoggedInDir(ctx context.Context, dir string, logf func(string), argv ...string) error {
	if len(argv) == 0 {
		return errors.New("пустая команда")
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	var wg sync.WaitGroup
	for _, stream := range []struct {
		name string
		scan *bufio.Scanner
	}{{"", bufio.NewScanner(stdout)}, {"", bufio.NewScanner(stderr)}} {
		wg.Add(1)
		go func(scanner *bufio.Scanner) {
			defer wg.Done()
			scanner.Buffer(make([]byte, 64*1024), 1024*1024)
			for scanner.Scan() {
				logf(scanner.Text())
			}
		}(stream.scan)
	}
	wg.Wait()
	return cmd.Wait()
}

func outputInDir(ctx context.Context, dir string, argv ...string) (string, error) {
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = dir
	out, err := cmd.Output()
	return string(out), err
}

func parseSRCINFODependencies(text string) []string {
	var deps []string
	for line := range strings.SplitSeq(text, "\n") {
		line = strings.TrimSpace(line)
		for _, prefix := range []string{
			"depends = ", "makedepends = ", "checkdepends = ",
			"depends_x86_64 = ", "makedepends_x86_64 = ", "checkdepends_x86_64 = ",
		} {
			if strings.HasPrefix(line, prefix) {
				deps = append(deps, strings.TrimSpace(strings.TrimPrefix(line, prefix)))
			}
		}
	}
	return uniqueStrings(deps)
}

func missingDependencies(ctx context.Context, deps []string) []string {
	if len(deps) == 0 {
		return nil
	}
	args := append([]string{"-T"}, deps...)
	out, err := exec.CommandContext(ctx, "pacman", args...).Output()
	if err == nil && len(out) == 0 {
		return nil
	}
	var missing []string
	for line := range strings.SplitSeq(string(out), "\n") {
		if dep := strings.TrimSpace(line); dep != "" {
			missing = append(missing, dep)
		}
	}
	return missing
}

func dependencyName(dep string) string {
	if idx := strings.IndexAny(dep, "<>="); idx >= 0 {
		dep = dep[:idx]
	}
	if idx := strings.Index(dep, ":"); idx >= 0 {
		dep = dep[:idx]
	}
	return strings.TrimSpace(dep)
}

func packageInRepos(ctx context.Context, name string) bool {
	return exec.CommandContext(ctx, "pacman", "-Si", name).Run() == nil
}

func builtPackages(dir string) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(dir, "*.pkg.tar.*"))
	if err != nil {
		return nil, err
	}
	var packages []string
	for _, path := range matches {
		if strings.HasSuffix(path, ".sig") {
			continue
		}
		packages = append(packages, path)
	}
	sort.Strings(packages)
	if len(packages) == 0 {
		return nil, errors.New("makepkg не создал пакет")
	}
	return packages, nil
}

func flatpakSystemInstalled(ctx context.Context, id string) bool {
	return exec.CommandContext(ctx, "flatpak", "info", "--system", id).Run() == nil
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]bool)
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value != "" && !seen[value] {
			seen[value] = true
			out = append(out, value)
		}
	}
	return out
}

func cloneState(state OperationState) OperationState {
	state.RecentLog = append([]string(nil), state.RecentLog...)
	if state.Item != nil {
		item := *state.Item
		state.Item = &item
	}
	return state
}

func operationLabel(action string) string {
	switch action {
	case "remove":
		return "Удаление"
	case "install-local":
		return "Установка локального пакета"
	default:
		return "Установка"
	}
}

func successLabel(action string) string {
	if action == "remove" {
		return "Удаление завершено"
	}
	return "Установка завершена"
}

func (item Item) RemoteOr(fallback string) string {
	if item.Remote != "" {
		return item.Remote
	}
	return fallback
}
