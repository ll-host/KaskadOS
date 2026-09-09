package software

type Source string

const (
	SourcePacman  Source = "pacman"
	SourceAUR     Source = "aur"
	SourceFlatpak Source = "flatpak"
	SourceLocal   Source = "local"
	SourceForeign Source = "foreign"
)

type Item struct {
	ID          string `json:"id"`
	PackageName string `json:"packageName"`
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
	Version     string `json:"version,omitempty"`
	Source      Source `json:"source"`
	Installed   bool   `json:"installed"`
	Launchable  bool   `json:"launchable,omitempty"`
	Icon        string `json:"icon,omitempty"`
	Remote      string `json:"remote,omitempty"`
}

type SearchResult struct {
	Items   []Item   `json:"items"`
	Sources []Source `json:"sources"`
	Problem string   `json:"problem,omitempty"`
}

type Phase string

const (
	PhaseIdle      Phase = "idle"
	PhasePreparing Phase = "preparing"
	PhaseRunning   Phase = "running"
	PhaseComplete  Phase = "complete"
	PhaseError     Phase = "error"
)

type OperationState struct {
	Phase       Phase    `json:"phase"`
	Action      string   `json:"action,omitempty"`
	Item        *Item    `json:"item,omitempty"`
	Message     string   `json:"message,omitempty"`
	StartedUnix int64    `json:"startedUnix,omitempty"`
	EndedUnix   int64    `json:"endedUnix,omitempty"`
	RecentLog   []string `json:"recentLog,omitempty"`
}
