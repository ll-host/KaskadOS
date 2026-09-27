package files

import "github.com/AvengeMedia/DankMaterialShell/core/internal/server/models"

func HandleRequest(conn *models.Conn, req models.Request, manager *Manager) {
	switch req.Method {
	case "files.list":
		listing, err := manager.List(models.GetOr(req, "path", ""), models.GetOr(req, "showHidden", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, listing)
	case "files.show":
		if err := manager.Show(models.GetOr(req, "path", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.mkdir":
		if err := manager.MakeDirectory(models.GetOr(req, "parent", ""), models.GetOr(req, "name", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.rename":
		if err := manager.Rename(models.GetOr(req, "path", ""), models.GetOr(req, "name", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.trash":
		if err := manager.Trash(models.GetOr(req, "path", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.trashList":
		entries, err := manager.TrashList()
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, entries)
	case "files.trashRestore":
		if err := manager.TrashRestore(models.GetOr(req, "name", ""), models.GetOr(req, "trashDir", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.trashDelete":
		if err := manager.TrashDelete(models.GetOr(req, "name", ""), models.GetOr(req, "trashDir", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.trashEmpty":
		if err := manager.TrashEmpty(); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.devices":
		devices, err := manager.Devices()
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, devices)
	case "files.storage":
		storage, err := manager.Storage()
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, storage)
	case "files.mount":
		mountPoint, err := manager.Mount(models.GetOr(req, "path", ""))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true, Value: mountPoint})
	case "files.unmount":
		if err := manager.Unmount(models.GetOr(req, "path", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.safelyRemove":
		if err := manager.SafelyRemove(models.GetOr(req, "path", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.format":
		operation, err := manager.StartFormat(
			models.GetOr(req, "path", ""),
			models.GetOr(req, "fileSystem", ""),
			models.GetOr(req, "label", ""),
			models.GetOr(req, "confirmed", false),
		)
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.partitionCreate":
		operation, err := manager.StartCreatePartition(
			models.GetOr(req, "diskPath", ""),
			requestInt64(req, "offsetBytes"),
			requestInt64(req, "sizeBytes"),
			models.GetOr(req, "fileSystem", ""),
			models.GetOr(req, "label", ""),
			models.GetOr(req, "confirmed", false),
		)
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.partitionDelete":
		operation, err := manager.StartDeletePartition(
			models.GetOr(req, "path", ""), models.GetOr(req, "confirmed", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.partitionTableCreate":
		operation, err := manager.StartCreatePartitionTable(
			models.GetOr(req, "diskPath", ""), models.GetOr(req, "table", ""),
			models.GetOr(req, "confirmed", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.partitionResize":
		operation, err := manager.StartResizePartition(
			models.GetOr(req, "path", ""), requestInt64(req, "sizeBytes"),
			models.GetOr(req, "confirmed", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.filesystemCheck", "files.filesystemRepair":
		operation, err := manager.StartFilesystemMaintenance(
			models.GetOr(req, "path", ""), req.Method == "files.filesystemRepair",
			models.GetOr(req, "confirmed", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.filesystemLabel":
		if err := manager.SetFilesystemLabel(models.GetOr(req, "path", ""), models.GetOr(req, "label", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.transfer":
		operation, err := manager.StartTransfer(models.GetOr(req, "source", ""), models.GetOr(req, "destination", ""), models.GetOr(req, "move", false))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.operation":
		operation, err := manager.Operation(models.GetOr(req, "id", ""))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, operation)
	case "files.cancelOperation":
		if err := manager.CancelOperation(models.GetOr(req, "id", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.open":
		if err := manager.Open(models.GetOr(req, "path", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "files.extract":
		destination, err := manager.Extract(models.GetOr(req, "path", ""))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true, Value: destination})
	case "files.archive":
		output, err := manager.Archive(models.GetOr(req, "path", ""), models.GetOr(req, "format", "zip"))
		if err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true, Value: output})
	default:
		models.RespondError(conn, req.ID, "unknown method: "+req.Method)
	}
}

func requestInt64(req models.Request, key string) int64 {
	switch value := req.Params[key].(type) {
	case float64:
		return int64(value)
	case int64:
		return value
	case int:
		return int64(value)
	default:
		return 0
	}
}
