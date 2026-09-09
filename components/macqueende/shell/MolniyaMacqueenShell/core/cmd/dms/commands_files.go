package main

import (
	"fmt"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/server/models"
	"github.com/spf13/cobra"
)

var filesCmd = &cobra.Command{
	Use:   "files",
	Short: "Файловый менеджер KaskadOS",
}

var filesOpenCmd = &cobra.Command{
	Use:   "open [PATH]",
	Short: "Открыть файловый менеджер",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(_ *cobra.Command, args []string) error {
		path := ""
		if len(args) > 0 {
			path = args[0]
		}
		response, err := sendServerRequest(models.Request{
			ID: 1, Method: "files.show", Params: map[string]any{"path": path},
		})
		if err != nil {
			return err
		}
		if response.Error != "" {
			return fmt.Errorf("%s", response.Error)
		}
		return nil
	},
}

func init() {
	filesCmd.AddCommand(filesOpenCmd)
	rootCmd.AddCommand(filesCmd)
}
