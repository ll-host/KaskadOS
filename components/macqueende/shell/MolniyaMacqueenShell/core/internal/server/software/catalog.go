package software

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

type Catalog struct {
	httpClient   *http.Client
	pacmanSyncM  sync.Mutex
	flatpakInitM sync.Mutex
	flatpakReady bool
}

func NewCatalog() *Catalog {
	return &Catalog{httpClient: &http.Client{Timeout: 12 * time.Second}}
}

func (c *Catalog) Search(ctx context.Context, query string, source Source) SearchResult {
	query = strings.TrimSpace(query)
	if query == "" {
		return SearchResult{Items: []Item{}, Sources: availableSources()}
	}
	if len(query) > 120 {
		query = query[:120]
	}

	problems := make([]string, 0, 2)
	var problemsM sync.Mutex
	pacmanReady := true
	if source == "" || source == SourcePacman {
		if err := c.ensurePacmanDatabases(ctx); err != nil {
			pacmanReady = false
			problems = append(problems, "Не удалось подготовить каталог Pacman. Проверьте подключение к интернету и повторите поиск.")
		}
	}
	flatpakReady := true
	if source == "" || source == SourceFlatpak {
		if err := c.ensureFlatpakCatalog(ctx); err != nil {
			flatpakReady = false
			problems = append(problems, "Не удалось подготовить Flathub. Проверьте подключение к интернету и повторите поиск.")
		}
	}

	installed := installedNames(ctx)
	type searchFunc func(context.Context, string, map[string]bool) []Item
	flatpakSearch := func(ctx context.Context, query string, installed map[string]bool) []Item {
		items, err := c.searchFlatpak(ctx, query, installed)
		if err != nil {
			problemsM.Lock()
			problems = append(problems, "Не удалось выполнить поиск во Flathub. Проверьте подключение к интернету и повторите поиск.")
			problemsM.Unlock()
		}
		return items
	}
	searches := make([]searchFunc, 0, 3)
	switch source {
	case SourcePacman:
		if pacmanReady {
			searches = append(searches, c.searchPacman)
		}
	case SourceFlatpak:
		if flatpakReady {
			searches = append(searches, flatpakSearch)
		}
	case SourceAUR:
		searches = append(searches, c.searchAUR)
	default:
		if pacmanReady {
			searches = append(searches, c.searchPacman)
		}
		if flatpakReady {
			searches = append(searches, flatpakSearch)
		}
		searches = append(searches, c.searchAUR)
	}

	results := make(chan []Item, len(searches))
	var wg sync.WaitGroup
	for _, search := range searches {
		wg.Add(1)
		go func(fn func(context.Context, string, map[string]bool) []Item) {
			defer wg.Done()
			results <- fn(ctx, query, installed)
		}(search)
	}
	go func() {
		wg.Wait()
		close(results)
	}()

	items := make([]Item, 0, 60)
	seen := make(map[string]bool)
	for group := range results {
		for _, item := range group {
			key := string(item.Source) + ":" + item.ID
			if seen[key] {
				continue
			}
			seen[key] = true
			items = append(items, item)
		}
	}
	sortSearchResults(items, query)
	if len(items) > 100 {
		items = items[:100]
	}
	return SearchResult{Items: items, Sources: availableSources(), Problem: strings.Join(problems, " ")}
}

func (c *Catalog) ensurePacmanDatabases(ctx context.Context) error {
	if pacmanDatabasesReady() {
		return nil
	}

	c.pacmanSyncM.Lock()
	defer c.pacmanSyncM.Unlock()
	if pacmanDatabasesReady() {
		return nil
	}

	const helper = "/usr/lib/kaskados/kaskados-system-update"
	if _, err := os.Stat(helper); err != nil {
		return err
	}

	var cmd *exec.Cmd
	if os.Geteuid() == 0 {
		cmd = exec.CommandContext(ctx, helper, "pacman-catalog")
	} else {
		cmd = exec.CommandContext(ctx, "pkexec", helper, "pacman-catalog")
	}
	if output, err := cmd.CombinedOutput(); err != nil {
		return errors.New(strings.TrimSpace(string(output)))
	}
	if !pacmanDatabasesReady() {
		return errors.New("pacman did not create repository databases")
	}
	return nil
}

func pacmanDatabasesReady() bool {
	for _, path := range []string{
		"/var/lib/pacman/sync/core.db",
		"/var/lib/pacman/sync/extra.db",
	} {
		info, err := os.Stat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() == 0 {
			return false
		}
	}
	return true
}

func (c *Catalog) ensureFlatpakCatalog(ctx context.Context) error {
	if !commandExists("flatpak") {
		return errors.New("flatpak is not installed")
	}

	c.flatpakInitM.Lock()
	defer c.flatpakInitM.Unlock()
	if c.flatpakReady {
		return nil
	}

	add := exec.CommandContext(
		ctx,
		"flatpak", "remote-add", "--user", "--if-not-exists",
		"flathub", "https://dl.flathub.org/repo/flathub.flatpakrepo",
	)
	if output, err := add.CombinedOutput(); err != nil {
		return commandOutputError(err, output)
	}

	update := exec.CommandContext(
		ctx,
		"flatpak", "update", "--user", "--appstream",
		"--noninteractive", "-y", "flathub",
	)
	if output, err := update.CombinedOutput(); err != nil {
		return commandOutputError(err, output)
	}

	c.flatpakReady = true
	return nil
}

func commandOutputError(err error, output []byte) error {
	message := strings.TrimSpace(string(output))
	if message == "" {
		return err
	}
	return errors.New(message)
}

func sortSearchResults(items []Item, query string) {
	normalizedQuery := strings.ToLower(query)
	sort.SliceStable(items, func(i, j int) bool {
		leftRank := searchRank(items[i], normalizedQuery)
		rightRank := searchRank(items[j], normalizedQuery)
		if leftRank != rightRank {
			return leftRank < rightRank
		}
		leftSource := sourceRank(items[i].Source)
		rightSource := sourceRank(items[j].Source)
		if leftSource != rightSource {
			return leftSource < rightSource
		}
		if items[i].Installed != items[j].Installed {
			return items[i].Installed
		}
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
}

func searchRank(item Item, query string) int {
	name := strings.ToLower(item.Name)
	packageName := strings.ToLower(item.PackageName)
	description := strings.ToLower(item.Description)
	switch {
	case name == query || packageName == query:
		return 0
	case strings.HasPrefix(name, query) || strings.HasPrefix(packageName, query):
		return 1
	case strings.Contains(name, query) || strings.Contains(packageName, query):
		return 2
	case strings.Contains(description, query):
		return 3
	default:
		return 4
	}
}

func sourceRank(source Source) int {
	switch source {
	case SourcePacman:
		return 0
	case SourceFlatpak:
		return 1
	case SourceAUR:
		return 2
	default:
		return 3
	}
}

func (c *Catalog) Installed(ctx context.Context, provenance map[string]Source) SearchResult {
	items := installedPacman(ctx, provenance)
	items = append(items, installedFlatpaks(ctx)...)
	sort.SliceStable(items, func(i, j int) bool {
		return strings.ToLower(items[i].Name) < strings.ToLower(items[j].Name)
	})
	return SearchResult{Items: items, Sources: availableSources()}
}

func availableSources() []Source {
	sources := []Source{SourcePacman}
	if commandExists("flatpak") {
		sources = append(sources, SourceFlatpak)
	}
	if commandExists("git") && commandExists("makepkg") {
		sources = append(sources, SourceAUR)
	}
	sources = append(sources, SourceLocal)
	return sources
}

func (c *Catalog) searchPacman(ctx context.Context, query string, installed map[string]bool) []Item {
	if !commandExists("pacman") {
		return nil
	}
	out, err := exec.CommandContext(ctx, "pacman", "-Ss", regexp.QuoteMeta(query)).Output()
	if err != nil && len(out) == 0 {
		return nil
	}
	var items []Item
	lines := strings.Split(string(out), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(lines[i], " ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		parts := strings.SplitN(fields[0], "/", 2)
		if len(parts) != 2 {
			continue
		}
		description := ""
		if i+1 < len(lines) && strings.HasPrefix(lines[i+1], " ") {
			description = strings.TrimSpace(lines[i+1])
			i++
		}
		name := parts[1]
		items = append(items, Item{
			ID: name, PackageName: name, Name: name, Description: description,
			Version: fields[1], Source: SourcePacman, Installed: installed[name], Remote: parts[0],
		})
		if len(items) >= 40 {
			break
		}
	}
	return items
}

func (c *Catalog) searchFlatpak(ctx context.Context, query string, installed map[string]bool) ([]Item, error) {
	if !commandExists("flatpak") {
		return nil, errors.New("flatpak is not installed")
	}
	out, err := exec.CommandContext(
		ctx,
		"flatpak", "search", "--user",
		"--columns=application:full,name:full,description:full,version:full",
		query,
	).CombinedOutput()
	if err != nil {
		return nil, commandOutputError(err, out)
	}
	var items []Item
	for scanner := bufio.NewScanner(strings.NewReader(string(out))); scanner.Scan(); {
		fields := strings.Split(scanner.Text(), "\t")
		if len(fields) < 2 || fields[0] == "" {
			continue
		}
		item := Item{ID: fields[0], PackageName: fields[0], Name: fields[1], Source: SourceFlatpak, Installed: installed[fields[0]], Remote: "flathub"}
		if len(fields) > 2 {
			item.Description = fields[2]
		}
		if len(fields) > 3 {
			item.Version = fields[3]
		}
		items = append(items, item)
		if len(items) >= 40 {
			break
		}
	}
	return items, nil
}

type aurRPCResponse struct {
	Results []struct {
		Name        string `json:"Name"`
		PackageBase string `json:"PackageBase"`
		Version     string `json:"Version"`
		Description string `json:"Description"`
	} `json:"results"`
}

func (c *Catalog) searchAUR(ctx context.Context, query string, installed map[string]bool) []Item {
	if !commandExists("git") || !commandExists("makepkg") {
		return nil
	}
	endpoint := "https://aur.archlinux.org/rpc/v5/search/" + url.PathEscape(query) + "?by=name-desc"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	var payload aurRPCResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil
	}
	items := make([]Item, 0, min(len(payload.Results), 30))
	for _, result := range payload.Results {
		items = append(items, Item{
			ID: result.Name, PackageName: result.Name, Name: result.Name,
			Description: result.Description, Version: result.Version,
			Source: SourceAUR, Installed: installed[result.Name], Remote: "AUR",
		})
		if len(items) >= 30 {
			break
		}
	}
	return items
}

func (c *Catalog) aurPackageBase(ctx context.Context, packageName string) (string, error) {
	endpoint, err := url.Parse("https://aur.archlinux.org/rpc/v5/info")
	if err != nil {
		return "", err
	}
	query := endpoint.Query()
	query.Add("arg[]", packageName)
	endpoint.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return "", err
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errors.New("AUR не ответил на запрос пакета")
	}
	var payload aurRPCResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if len(payload.Results) != 1 || !packageNamePattern.MatchString(payload.Results[0].PackageBase) {
		return "", errors.New("пакет не найден в AUR")
	}
	return payload.Results[0].PackageBase, nil
}

func installedNames(ctx context.Context) map[string]bool {
	installed := make(map[string]bool)
	if out, err := exec.CommandContext(ctx, "pacman", "-Qq").Output(); err == nil {
		for line := range strings.SplitSeq(string(out), "\n") {
			if name := strings.TrimSpace(line); name != "" {
				installed[name] = true
			}
		}
	}
	if commandExists("flatpak") {
		if out, err := exec.CommandContext(ctx, "flatpak", "list", "--columns=application").Output(); err == nil {
			for line := range strings.SplitSeq(string(out), "\n") {
				if name := strings.TrimSpace(line); name != "" {
					installed[name] = true
				}
			}
		}
	}
	return installed
}

func installedPacman(ctx context.Context, provenance map[string]Source) []Item {
	foreign := make(map[string]bool)
	if out, err := exec.CommandContext(ctx, "pacman", "-Qmq").Output(); err == nil {
		for line := range strings.SplitSeq(string(out), "\n") {
			foreign[strings.TrimSpace(line)] = true
		}
	}
	out, err := exec.CommandContext(ctx, "pacman", "-Q").Output()
	if err != nil {
		return nil
	}
	var items []Item
	for line := range strings.SplitSeq(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		source := SourcePacman
		remote := "Официальные репозитории"
		if foreign[fields[0]] {
			source = provenance[fields[0]]
			switch source {
			case SourceAUR:
				remote = "AUR"
			case SourceLocal:
				remote = "Локальный пакет"
			default:
				source = SourceForeign
				remote = "Внешний источник"
			}
		}
		items = append(items, Item{ID: fields[0], PackageName: fields[0], Name: fields[0], Version: fields[1], Source: source, Installed: true, Remote: remote})
	}
	return items
}

func installedFlatpaks(ctx context.Context) []Item {
	if !commandExists("flatpak") {
		return nil
	}
	out, err := exec.CommandContext(ctx, "flatpak", "list", "--columns=application,name,description,version,origin").Output()
	if err != nil {
		return nil
	}
	var items []Item
	for line := range strings.SplitSeq(string(out), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) < 2 || fields[0] == "" {
			continue
		}
		item := Item{ID: fields[0], PackageName: fields[0], Name: fields[1], Source: SourceFlatpak, Installed: true}
		if len(fields) > 2 {
			item.Description = fields[2]
		}
		if len(fields) > 3 {
			item.Version = fields[3]
		}
		if len(fields) > 4 {
			item.Remote = fields[4]
		}
		items = append(items, item)
	}
	return items
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
