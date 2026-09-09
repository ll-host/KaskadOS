package main

import (
	"fmt"

	"github.com/AvengeMedia/DankMaterialShell/core/internal/server/models"
	"github.com/spf13/cobra"
)

var windowsCmd = &cobra.Command{
	Use:   "windows",
	Short: "Управление Windows-приложениями KaskadOS",
}

var windowsLaunchCmd = &cobra.Command{
	Use:   "launch ID",
	Short: "Запустить зарегистрированное Windows-приложение",
	Args:  cobra.ExactArgs(1),
	RunE: func(_ *cobra.Command, args []string) error {
		response, err := sendServerRequest(models.Request{
			ID: 1, Method: "windows.launch", Params: map[string]any{"id": args[0]},
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
	windowsCmd.AddCommand(windowsLaunchCmd)
	rootCmd.AddCommand(windowsCmd)
}
