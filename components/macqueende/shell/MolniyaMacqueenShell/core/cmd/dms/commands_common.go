package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/log"
	"github.com/AvengeMedia/DankMaterialShell/core/internal/server"
	"github.com/AvengeMedia/DankMaterialShell/core/internal/shellembed"
	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Show version information",
	Run:   runVersion,
}

var ipcCmd = &cobra.Command{
	Use:   "ipc",
	Short: "Send IPC commands to running DMS shell",
	Long: `Send IPC commands to the running DMS shell.

  dms ipc call <target> <function> [args...]   invoke a command
  dms ipc list                                 list all targets and functions

Full reference: https://danklinux.com/docs/dankmaterialshell/keybinds-ipc`,
	ValidArgsFunction: func(cmd *cobra.Command, args []string, toComplete string) ([]string, cobra.ShellCompDirective) {
		return getShellIPCCompletions(args, toComplete), cobra.ShellCompDirectiveNoFileComp
	},
	Run: func(cmd *cobra.Command, args []string) {
		runShellIPCCommand(args)
	},
}

var ipcListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all IPC targets and functions",
	Run: func(cmd *cobra.Command, args []string) {
		printIPCHelp()
	},
}

func init() {
	ipcCmd.AddCommand(ipcListCmd)
	ipcCmd.SetHelpFunc(func(cmd *cobra.Command, args []string) {
		printIPCHelp()
	})
}

var debugSrvCmd = &cobra.Command{
	Use:   "debug-srv",
	Short: "Start the debug server",
	Long:  "Start the Unix socket debug server for DMS",
	Run: func(cmd *cobra.Command, args []string) {
		if err := startDebugServer(); err != nil {
			log.Fatalf("Error starting debug server: %v", err)
		}
	},
}

func runVersion(cmd *cobra.Command, args []string) {
	fmt.Printf("%s\n", formatVersion(Version))
}

// Git builds: dms (git) v0.6.2-XXXX
// Stable releases: dms v0.6.2
func formatVersion(version string) string {
	// Arch/Debian/Ubuntu/OpenSUSE git format: 0.6.2+git2264.c5c5ce84
	re := regexp.MustCompile(`^([\d.]+)\+git(\d+)\.`)
	if matches := re.FindStringSubmatch(version); matches != nil {
		return fmt.Sprintf("dms (git) v%s-%s", matches[1], matches[2])
	}

	// Fedora COPR git format: 0.0.git.2267.d430cae9
	re = regexp.MustCompile(`^[\d.]+\.git\.(\d+)\.`)
	if matches := re.FindStringSubmatch(version); matches != nil {
		baseVersion := getBaseVersion()
		return fmt.Sprintf("dms (git) v%s-%s", baseVersion, matches[1])
	}

	// Stable release format: 0.6.2
	re = regexp.MustCompile(`^([\d.]+)$`)
	if matches := re.FindStringSubmatch(version); matches != nil {
		return fmt.Sprintf("dms v%s", matches[1])
	}

	return fmt.Sprintf("dms %s", version)
}

var baseVersionRe = regexp.MustCompile(`^([\d.]+)`)

// Installed UI trees, for builds without an embedded UI.
var shellVersionPaths = []string{
	"/usr/share/quickshell/dms/VERSION",
	"/usr/local/share/quickshell/dms/VERSION",
	"/etc/xdg/quickshell/dms/VERSION",
}

func getBaseVersion() string {
	if ver := parseBaseVersion(shellembed.Version()); ver != "" {
		return ver
	}

	for _, path := range shellVersionPaths {
		content, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if ver := parseBaseVersion(string(content)); ver != "" {
			return ver
		}
	}

	return "1.0.2"
}

func parseBaseVersion(raw string) string {
	matches := baseVersionRe.FindStringSubmatch(strings.TrimPrefix(strings.TrimSpace(raw), "v"))
	if matches == nil {
		return ""
	}
	return matches[1]
}

func startDebugServer() error {
	server.CLIVersion = Version
	return server.Start(true)
}

func getCommonCommands() []*cobra.Command {
	commands := shellApp.Commands()
	return append(commands, []*cobra.Command{
		versionCmd,
		ipcCmd,
		debugSrvCmd,
		dank16Cmd,
		brightnessCmd,
		dpmsCmd,
		keybindsCmd,
		greeterCmd,
		setupCmd,
		colorCmd,
		qrCmd,
		screenshotCmd,
		notifyActionCmd,
		notifyCmd,
		genericNotifyActionCmd,
		matugenCmd,
		clipboardCmd,
		chromaCmd,
		doctorCmd,
		configCmd,
		dlCmd,
		randrCmd,
		blurCmd,
		trashCmd,
		systemCmd,
		switchUserCmd,
	}...)
}
