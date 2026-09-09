package windowsapps

type Runtime struct {
	Tag     string `json:"tag"`
	Path    string `json:"path"`
	Managed bool   `json:"managed"`
}

type Release struct {
	Tag         string `json:"tag"`
	PublishedAt string `json:"publishedAt,omitempty"`
	PageURL     string `json:"pageUrl,omitempty"`
	ArchiveURL  string `json:"archiveUrl,omitempty"`
	ArchiveName string `json:"archiveName,omitempty"`
	ArchiveSize int64  `json:"archiveSize,omitempty"`
	ChecksumURL string `json:"checksumUrl,omitempty"`
	Prerelease  bool   `json:"prerelease,omitempty"`
	Installed   bool   `json:"installed"`
}

type App struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Executable  string `json:"executable"`
	Prefix      string `json:"prefix"`
	RuntimePath string `json:"runtimePath"`
	RuntimeTag  string `json:"runtimeTag"`
	Kind        string `json:"kind"`
	InstalledAt int64  `json:"installedAt,omitempty"`
}

type State struct {
	Phase        string `json:"phase"`
	Message      string `json:"message,omitempty"`
	App          *App   `json:"app,omitempty"`
	Progress     int    `json:"progress,omitempty"`
	StartedUnix  int64  `json:"startedUnix,omitempty"`
	FinishedUnix int64  `json:"finishedUnix,omitempty"`
	LogPath      string `json:"logPath,omitempty"`
}
