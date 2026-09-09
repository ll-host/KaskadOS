package sysupdate

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/log"
	"github.com/AvengeMedia/dankgo/syncmap"
)

const (
	defaultIntervalSeconds   = 30 * 60
	minIntervalSeconds       = 5 * 60
	recentLogCapacity        = 200
	checkTimeout             = 5 * time.Minute
	retryIntervalSeconds     = 5 * 60
	upgradeTimeout           = 2 * time.Hour
	postUpgradeCompleteDelay = 3 * time.Second
	maxUpgradeAttempts       = 4
	maxJournalSize           = 4 * 1024 * 1024
)

var upgradeRetryDelays = [...]time.Duration{0, 5 * time.Second, 20 * time.Second, 60 * time.Second}

type Manager struct {
	mu          sync.RWMutex
	state       State
	subscribers syncmap.Map[string, chan State]

	selection Selection

	notifyDirty chan struct{}
	stopChan    chan struct{}
	notifierWG  sync.WaitGroup
	schedulerWG sync.WaitGroup

	acquireCount int32
	wakeSched    chan struct{}

	refreshSerial sync.Mutex
	journalMu     sync.Mutex
	journalReady  bool
	journalPath   string

	opMu     sync.Mutex
	opCtx    context.Context
	opCancel context.CancelFunc
}

func NewManager() (*Manager, error) {
	m := &Manager{
		notifyDirty: make(chan struct{}, 1),
		stopChan:    make(chan struct{}),
		wakeSched:   make(chan struct{}, 1),
	}
	m.state = State{
		Phase:           PhaseIdle,
		IntervalSeconds: defaultIntervalSeconds,
		Backends:        []BackendInfo{},
		Packages:        []Package{},
	}
	if release := readDesktopRelease(); release.Version != "" {
		m.state.DesktopVersion = release.Version
		m.state.RestartSession = release.SessionRestartRequired
	}

	id, pretty := readOSRelease()
	m.state.Distro = id
	m.state.DistroPretty = pretty

	m.selection = Select(context.Background())
	m.state.Backends = m.selection.Info()
	if len(m.state.Backends) == 0 {
		m.state.Error = &ErrorInfo{
			Code:    ErrCodeNoBackend,
			Message: "no supported package manager found",
			Hint:    "install a supported package manager (pacman, dnf, apt, zypper) or flatpak",
		}
	}

	m.notifierWG.Add(1)
	go m.notifier()

	m.schedulerWG.Add(1)
	go m.scheduler()

	return m, nil
}

func (m *Manager) GetState() State {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return cloneState(m.state)
}

func (m *Manager) Subscribe(id string) chan State {
	ch := make(chan State, 16)
	m.subscribers.Store(id, ch)
	return ch
}

func (m *Manager) Unsubscribe(id string) {
	if val, ok := m.subscribers.LoadAndDelete(id); ok {
		close(val)
	}
}

func (m *Manager) Close() {
	select {
	case <-m.stopChan:
		return
	default:
		close(m.stopChan)
	}
	m.opMu.Lock()
	if m.opCancel != nil {
		m.opCancel()
	}
	m.opMu.Unlock()
	select {
	case m.wakeSched <- struct{}{}:
	default:
	}
	m.schedulerWG.Wait()
	m.notifierWG.Wait()
	m.subscribers.Range(func(key string, ch chan State) bool {
		close(ch)
		m.subscribers.Delete(key)
		return true
	})
}

func (m *Manager) SetInterval(seconds int) {
	if seconds < minIntervalSeconds {
		seconds = minIntervalSeconds
	}
	m.mu.Lock()
	m.state.IntervalSeconds = seconds
	m.state.NextCheckUnix = time.Now().Unix() + int64(seconds)
	m.mu.Unlock()
	m.wake()
	m.markDirty()
}

func (m *Manager) Refresh(opts RefreshOptions) {
	m.mu.RLock()
	phase := m.state.Phase
	m.mu.RUnlock()

	switch {
	case isOperationPhase(phase):
		return
	case phase == PhaseRefreshing && !opts.Force:
		m.refreshSerial.Lock()
		m.refreshSerial.Unlock()
		return
	}
	m.runRefresh(context.Background(), true)
}

func (m *Manager) Upgrade(opts UpgradeOptions) error {
	if len(m.selection.All()) == 0 {
		return errors.New("no backend available")
	}

	m.opMu.Lock()
	if m.opCancel != nil {
		m.opMu.Unlock()
		return errors.New("operation already running")
	}
	ctx, cancel := context.WithTimeout(context.Background(), upgradeTimeout)
	m.opCtx = ctx
	m.opCancel = cancel
	m.opMu.Unlock()

	go m.runUpgrade(ctx, opts)
	return nil
}

func (m *Manager) Cancel() {
	m.opMu.Lock()
	cancel := m.opCancel
	m.opMu.Unlock()
	if cancel == nil {
		return
	}
	cancel()
}

func (m *Manager) Acquire() {
	atomic.AddInt32(&m.acquireCount, 1)
	m.mu.Lock()
	if m.state.NextCheckUnix == 0 {
		m.state.NextCheckUnix = time.Now().Unix() + int64(m.state.IntervalSeconds)
	}
	m.mu.Unlock()
	m.wake()
}

func (m *Manager) Release() {
	if atomic.AddInt32(&m.acquireCount, -1) < 0 {
		atomic.StoreInt32(&m.acquireCount, 0)
	}
}

func (m *Manager) wake() {
	select {
	case m.wakeSched <- struct{}{}:
	default:
	}
}

func (m *Manager) scheduler() {
	defer m.schedulerWG.Done()
	for {
		if atomic.LoadInt32(&m.acquireCount) == 0 {
			select {
			case <-m.stopChan:
				return
			case <-m.wakeSched:
			}
			continue
		}

		m.mu.RLock()
		interval := m.state.IntervalSeconds
		next := m.state.NextCheckUnix
		m.mu.RUnlock()
		if interval < minIntervalSeconds {
			interval = minIntervalSeconds
		}
		now := time.Now().Unix()
		if next == 0 {
			next = now + int64(interval)
		}
		wait := max(time.Duration(next-now)*time.Second, 0)
		t := time.NewTimer(wait)
		select {
		case <-m.stopChan:
			t.Stop()
			return
		case <-m.wakeSched:
			t.Stop()
		case <-t.C:
			m.runRefresh(context.Background(), false)
		}
	}
}

func (m *Manager) runRefresh(parent context.Context, manual bool) {
	m.refreshSerial.Lock()
	defer m.refreshSerial.Unlock()

	if len(m.selection.All()) == 0 {
		return
	}

	ctx, cancel := context.WithTimeout(parent, checkTimeout)
	defer cancel()

	m.mu.Lock()
	if isOperationPhase(m.state.Phase) {
		m.mu.Unlock()
		return
	}
	m.state.Phase = PhaseRefreshing
	m.state.Error = nil
	m.state.RecentLog = nil
	m.mu.Unlock()
	m.markDirty()

	type backendResult struct {
		pkgs []Package
		err  error
	}
	backends := m.selection.All()
	results := make([]backendResult, len(backends))
	var wg sync.WaitGroup
	for i, b := range backends {
		wg.Add(1)
		go func(i int, b Backend) {
			defer wg.Done()
			pkgs, err := b.CheckUpdates(ctx)
			results[i] = backendResult{pkgs: pkgs, err: err}
		}(i, b)
	}
	wg.Wait()

	now := time.Now().Unix()
	m.mu.Lock()
	m.state.LastCheckUnix = now
	prev := m.state.Packages
	next := make([]Package, 0, len(prev))
	var firstErr error
	for i, r := range results {
		if r.err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("%s: %w", backends[i].ID(), r.err)
			}
			// Retain a failed backend's last known packages so a transient failure doesn't wipe the list.
			for _, p := range prev {
				if p.Backend == backends[i].ID() {
					next = append(next, p)
				}
			}
			continue
		}
		next = append(next, r.pkgs...)
	}
	m.state.Packages = next
	m.state.Count = len(next)
	m.state.NextCheckUnix = now + int64(m.state.IntervalSeconds)
	switch {
	case firstErr == nil:
		m.state.Phase = PhaseIdle
		m.state.LastSuccessUnix = now
	case manual:
		m.state.Phase = PhaseError
		m.state.Error = &ErrorInfo{Code: ErrCodeBackendFailed, Message: firstErr.Error()}
	default:
		// Background checks fail silently and retry sooner; only manual refreshes surface errors.
		m.state.Phase = PhaseIdle
		retry := min(int64(m.state.IntervalSeconds), retryIntervalSeconds)
		m.state.NextCheckUnix = now + retry
		log.Warnf("[sysupdate] background check failed, retrying in %ds: %v", retry, firstErr)
	}
	m.mu.Unlock()
	m.wake()
	m.markDirty()
}

func (m *Manager) runUpgrade(ctx context.Context, opts UpgradeOptions) {
	defer func() {
		m.opMu.Lock()
		if m.opCancel != nil {
			m.opCancel = nil
			m.opCtx = nil
		}
		m.opMu.Unlock()
	}()

	if opts.CustomCommand != "" {
		m.runCustomUpgrade(ctx, opts)
		return
	}
	previousRelease := readDesktopRelease()

	if len(opts.Targets) == 0 {
		m.mu.RLock()
		opts.Targets = append([]Package(nil), m.state.Packages...)
		m.mu.RUnlock()
	}
	if isPacmanFamily(m.selection.System) {
		opts.Ignored = dropPacmanRepoIgnores(opts.Ignored, opts.Targets)
	}
	opts.Targets = dropIgnoredTargets(opts.Targets, opts.Ignored)

	backends := upgradeBackends(m.selection, opts)
	if len(backends) == 0 {
		if len(opts.Targets) > 0 {
			m.setError(ErrCodeNoBackend, "all pending updates are excluded by current settings (AUR/Flatpak disabled)")
		} else {
			m.setError(ErrCodeNoBackend, "no backend selected for upgrade")
		}
		return
	}

	opID := fmt.Sprintf("op-%d", time.Now().UnixNano())
	journalPath, journalErr := m.beginJournal(opts.Automatic)
	if journalErr != nil {
		log.Warnf("[sysupdate] create update journal: %v", journalErr)
	}
	m.mu.Lock()
	m.state.Phase = PhaseUpgrading
	m.state.OperationID = opID
	m.state.OperationStarted = time.Now().Unix()
	m.state.OperationStage = "preparing"
	m.state.UpgradeAttempt = 1
	m.state.UpgradeMax = maxUpgradeAttempts
	m.state.RecentLog = m.state.RecentLog[:0]
	m.state.Error = nil
	m.state.DesktopUpdated = false
	m.state.PreviousDesktop = ""
	m.state.JournalPath = journalPath
	m.mu.Unlock()
	m.markDirty()

	onLine := func(line string) { m.appendLog(line) }
	currentTargets := append([]Package(nil), opts.Targets...)
	for attempt := 1; attempt <= maxUpgradeAttempts; attempt++ {
		if attempt > 1 {
			if !m.waitForUpgradeRetry(ctx, attempt, upgradeRetryDelays[attempt-1]) {
				m.finishUpgradeError(ctx, "обновление отменено", nil)
				return
			}
		}

		attemptOpts := opts
		attemptOpts.Targets = currentTargets
		attemptBackends := upgradeBackends(m.selection, attemptOpts)
		m.setUpgradeProgress(PhaseUpgrading, "installing", attempt)

		var upgradeErr error
		for _, b := range attemptBackends {
			m.appendLog(fmt.Sprintf("== %s (attempt %d/%d) ==", b.DisplayName(), attempt, maxUpgradeAttempts))
			if err := b.Upgrade(ctx, attemptOpts, onLine); err != nil {
				upgradeErr = fmt.Errorf("%s: %w", b.ID(), err)
				break
			}
		}
		if upgradeErr != nil {
			if attempt < maxUpgradeAttempts && isRetryableUpgradeError(upgradeErr) {
				m.appendLog("Temporary update error; retrying in the same maintenance session.")
				continue
			}
			m.finishUpgradeError(ctx, "не удалось завершить обновление", upgradeErr)
			return
		}

		m.setUpgradeProgress(PhaseVerifying, "verifying", attempt)
		verifyCtx, verifyCancel := context.WithTimeout(ctx, checkTimeout)
		pending, verifyErr := checkPendingUpdates(verifyCtx, attemptBackends, attemptOpts)
		verifyCancel()
		if verifyErr != nil {
			if attempt < maxUpgradeAttempts && isRetryableUpgradeError(verifyErr) {
				m.appendLog("Update verification failed temporarily; retrying.")
				continue
			}
			m.finishUpgradeError(ctx, "не удалось проверить результат обновления", verifyErr)
			return
		}

		m.replacePendingPackages(pending)
		if len(pending) == 0 {
			m.finishSuccessfulUpgrade(previousRelease)
			return
		}

		currentTargets = pending
		m.appendLog(fmt.Sprintf("Verification found %d pending update(s).", len(pending)))
		if attempt == maxUpgradeAttempts {
			m.finishUpgradeError(ctx, "часть обновлений осталась не установлена", nil)
			return
		}
	}
}

func (m *Manager) runCustomUpgrade(ctx context.Context, opts UpgradeOptions) {
	previousRelease := readDesktopRelease()
	term := findTerminal(opts.Terminal)
	if term == "" {
		m.setError(ErrCodeBackendFailed, "no terminal found (pick one in DMS settings, set $TERMINAL, or install kitty/ghostty/foot/alacritty)")
		return
	}

	opID := fmt.Sprintf("op-%d", time.Now().UnixNano())
	journalPath, journalErr := m.beginJournal(opts.Automatic)
	if journalErr != nil {
		log.Warnf("[sysupdate] create update journal: %v", journalErr)
	}
	m.mu.Lock()
	m.state.Phase = PhaseUpgrading
	m.state.OperationID = opID
	m.state.OperationStarted = time.Now().Unix()
	m.state.RecentLog = m.state.RecentLog[:0]
	m.state.Error = nil
	m.state.JournalPath = journalPath
	m.mu.Unlock()
	m.markDirty()

	onLine := func(line string) { m.appendLog(line) }
	argv := wrapInTerminal(term, "DMS — System Update (custom)", opts.CustomCommand, opts.TerminalArgs)
	if err := Run(ctx, argv, RunOptions{OnLine: onLine}); err != nil {
		m.finishUpgradeError(ctx, "не удалось завершить обновление", err)
		return
	}

	m.finishSuccessfulUpgrade(previousRelease)
	m.runRefresh(context.Background(), false)
}

func (m *Manager) finishSuccessfulUpgrade(previous desktopRelease) {
	m.appendLog("Upgrade complete.")
	m.endJournal("Обновление завершено успешно.")

	timer := time.NewTimer(postUpgradeCompleteDelay)
	defer timer.Stop()

	select {
	case <-m.stopChan:
		return
	case <-timer.C:
	}

	current := readDesktopRelease()
	now := time.Now().Unix()
	m.mu.Lock()
	m.state.Phase = PhaseIdle
	m.state.OperationID = ""
	m.state.OperationStarted = 0
	m.state.OperationStage = "complete"
	m.state.UpgradeCompleted = now
	m.state.LastSuccessUnix = now
	m.state.Packages = m.state.Packages[:0]
	m.state.Count = 0
	m.state.PreviousDesktop = previous.Version
	m.state.DesktopVersion = current.Version
	m.state.DesktopUpdated = previous.Version != "" && current.Version != "" && previous.Version != current.Version
	m.state.RestartSession = current.SessionRestartRequired && m.state.DesktopUpdated
	m.mu.Unlock()
	m.markDirty()
}

func (m *Manager) setUpgradeProgress(phase Phase, stage string, attempt int) {
	m.mu.Lock()
	m.state.Phase = phase
	m.state.OperationStage = stage
	m.state.UpgradeAttempt = attempt
	m.state.Error = nil
	m.mu.Unlock()
	m.markDirty()
}

func (m *Manager) waitForUpgradeRetry(ctx context.Context, attempt int, delay time.Duration) bool {
	m.setUpgradeProgress(PhaseRetrying, "waiting-retry", attempt)
	m.appendLog(fmt.Sprintf("Retrying in %s.", delay))
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-m.stopChan:
		return false
	case <-timer.C:
		return true
	}
}

func (m *Manager) finishUpgradeError(ctx context.Context, message string, technical error) {
	code := ErrCodeBackendFailed
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		code = ErrCodeTimeout
		message = "обновление заняло слишком много времени"
	case errors.Is(ctx.Err(), context.Canceled):
		code = ErrCodeCancelled
		message = "обновление отменено"
	}
	if technical != nil {
		m.appendLog("ERROR: " + technical.Error())
	}
	m.endJournal("Обновление не завершено.")
	journalPath := m.currentJournalPath()
	hint := "Повторите обновление."
	if journalPath != "" {
		hint = fmt.Sprintf("Журнал сохранён: %s\nПовторите обновление или приложите этот файл при обращении к разработчику.", journalPath)
	}
	m.mu.Lock()
	m.state.Phase = PhaseError
	m.state.OperationID = ""
	m.state.OperationStarted = 0
	m.state.OperationStage = "failed"
	m.state.Error = &ErrorInfo{
		Code:    code,
		Message: message,
		Hint:    hint,
	}
	m.mu.Unlock()
	m.markDirty()
}

func (m *Manager) replacePendingPackages(packages []Package) {
	m.mu.Lock()
	m.state.Packages = append(m.state.Packages[:0], packages...)
	m.state.Count = len(packages)
	m.mu.Unlock()
	m.markDirty()
}

func checkPendingUpdates(ctx context.Context, backends []Backend, opts UpgradeOptions) ([]Package, error) {
	var pending []Package
	for _, b := range backends {
		packages, err := b.CheckUpdates(ctx)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", b.ID(), err)
		}
		for _, pkg := range packages {
			if pkg.Repo == RepoAUR && !opts.IncludeAUR {
				continue
			}
			if pkg.Repo == RepoFlatpak && !opts.IncludeFlatpak {
				continue
			}
			pending = append(pending, pkg)
		}
	}
	return dropIgnoredTargets(pending, opts.Ignored), nil
}

func isRetryableUpgradeError(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	permanent := []string{
		"invalid or corrupted package",
		"signature",
		"conflicting files",
		"conflicts with",
		"could not satisfy dependencies",
		"not enough free disk space",
		"disk full",
		"authentication failed",
		"permission denied",
	}
	for _, marker := range permanent {
		if strings.Contains(text, marker) {
			return false
		}
	}
	retryable := []string{
		"connection",
		"could not resolve",
		"failed to synchronize all databases",
		"failed retrieving file",
		"failed to download",
		"download library error",
		"the requested url returned error",
		"operation too slow",
		"operation timed out",
		"temporary failure",
		"network is unreachable",
		"database is locked",
		"unable to lock database",
		"resource temporarily unavailable",
		"unexpected eof",
		"end of file",
	}
	for _, marker := range retryable {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

func isOperationPhase(phase Phase) bool {
	return phase == PhaseUpgrading || phase == PhaseVerifying || phase == PhaseRetrying
}

type desktopRelease struct {
	Version                string `json:"version"`
	SessionRestartRequired bool   `json:"sessionRestartRequired"`
}

func readDesktopRelease() desktopRelease {
	paths := []string{
		"/usr/share/kaskados/release.json",
		"/opt/macqueende/release/release.json",
	}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var release desktopRelease
		if json.Unmarshal(raw, &release) == nil && release.Version != "" {
			return release
		}
	}
	return desktopRelease{}
}

func dropIgnoredTargets(targets []Package, ignored []string) []Package {
	if len(ignored) == 0 {
		return targets
	}
	skip := make(map[string]bool, len(ignored))
	for _, name := range ignored {
		skip[name] = true
	}
	out := targets[:0]
	for _, p := range targets {
		if skip[p.Name] {
			continue
		}
		out = append(out, p)
	}
	return out
}

func upgradeBackends(sel Selection, opts UpgradeOptions) []Backend {
	var out []Backend
	if sel.System != nil {
		out = appendUpgradeBackend(out, sel.System, opts)
	}
	for _, b := range sel.Overlay {
		switch {
		case b.Repo() == RepoFlatpak && !opts.IncludeFlatpak:
			continue
		}
		out = appendUpgradeBackend(out, b, opts)
	}
	return out
}

func appendUpgradeBackend(out []Backend, b Backend, opts UpgradeOptions) []Backend {
	if !BackendHasTargets(b, opts.Targets, opts.IncludeAUR, opts.IncludeFlatpak) {
		return out
	}
	return append(out, b)
}

func (m *Manager) appendLog(line string) {
	m.mu.Lock()
	if cap(m.state.RecentLog) == 0 {
		m.state.RecentLog = make([]string, 0, recentLogCapacity)
	}
	if len(m.state.RecentLog) >= recentLogCapacity {
		copy(m.state.RecentLog, m.state.RecentLog[1:])
		m.state.RecentLog = m.state.RecentLog[:recentLogCapacity-1]
	}
	m.state.RecentLog = append(m.state.RecentLog, line)
	m.mu.Unlock()
	if err := m.writeJournalLine(line); err != nil {
		log.Warnf("[sysupdate] write update journal: %v", err)
	}
	m.markDirty()
}

func (m *Manager) beginJournal(automatic bool) (string, error) {
	m.journalMu.Lock()
	defer m.journalMu.Unlock()
	m.journalReady = false
	m.journalPath = ""

	path, err := updateJournalPath()
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", err
	}

	if info, statErr := os.Stat(path); statErr == nil && info.Size() >= maxJournalSize {
		if renameErr := os.Rename(path, path+".1"); renameErr != nil {
			return "", renameErr
		}
	} else if statErr != nil && !errors.Is(statErr, os.ErrNotExist) {
		return "", statErr
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return "", err
	}
	mode := "ручное"
	if automatic {
		mode = "автоматическое"
	}
	_, writeErr := fmt.Fprintf(file, "\n=== %s · %s обновление ===\n", time.Now().Format(time.RFC3339), mode)
	closeErr := file.Close()
	if writeErr != nil {
		return "", writeErr
	}
	if closeErr != nil {
		return "", closeErr
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return "", err
	}

	m.journalPath = path
	m.journalReady = true
	return path, nil
}

func (m *Manager) writeJournalLine(line string) error {
	m.journalMu.Lock()
	defer m.journalMu.Unlock()
	if !m.journalReady || m.journalPath == "" {
		return nil
	}
	file, err := os.OpenFile(m.journalPath, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		m.journalReady = false
		return err
	}
	_, writeErr := fmt.Fprintf(file, "%s %s\n", time.Now().Format("15:04:05"), line)
	closeErr := file.Close()
	if writeErr != nil {
		m.journalReady = false
		return writeErr
	}
	if closeErr != nil {
		m.journalReady = false
		return closeErr
	}
	return nil
}

func (m *Manager) endJournal(message string) {
	if err := m.writeJournalLine(message); err != nil {
		log.Warnf("[sysupdate] finish update journal: %v", err)
	}
	m.journalMu.Lock()
	m.journalReady = false
	m.journalMu.Unlock()
}

func (m *Manager) currentJournalPath() string {
	m.journalMu.Lock()
	defer m.journalMu.Unlock()
	return m.journalPath
}

func updateJournalPath() (string, error) {
	stateHome := strings.TrimSpace(os.Getenv("XDG_STATE_HOME"))
	if stateHome == "" || !filepath.IsAbs(stateHome) {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		stateHome = filepath.Join(home, ".local", "state")
	}
	return filepath.Join(stateHome, "kaskados", "system-update.log"), nil
}

func (m *Manager) setError(code ErrorCode, msg string) {
	m.mu.Lock()
	m.state.Phase = PhaseError
	m.state.Error = &ErrorInfo{Code: code, Message: msg}
	m.mu.Unlock()
	m.markDirty()
}

func (m *Manager) markDirty() {
	select {
	case m.notifyDirty <- struct{}{}:
	default:
	}
}

func (m *Manager) notifier() {
	defer m.notifierWG.Done()
	for {
		select {
		case <-m.stopChan:
			return
		case <-m.notifyDirty:
			snap := m.GetState()
			m.subscribers.Range(func(key string, ch chan State) bool {
				select {
				case ch <- snap:
				default:
				}
				return true
			})
		}
	}
}

func cloneState(s State) State {
	out := s
	out.Backends = append([]BackendInfo(nil), s.Backends...)
	out.Packages = append([]Package(nil), s.Packages...)
	out.RecentLog = append([]string(nil), s.RecentLog...)
	if s.Error != nil {
		errCopy := *s.Error
		out.Error = &errCopy
	}
	return out
}

func readOSRelease() (id, pretty string) {
	f, err := os.Open("/etc/os-release")
	if err != nil {
		return "", ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		k, v, ok := strings.Cut(scanner.Text(), "=")
		if !ok {
			continue
		}
		v = strings.Trim(v, "\"")
		switch k {
		case "ID":
			id = v
		case "PRETTY_NAME":
			pretty = v
		}
	}
	if err := scanner.Err(); err != nil {
		log.Debugf("[sysupdate] read os-release: %v", err)
	}
	return id, pretty
}
