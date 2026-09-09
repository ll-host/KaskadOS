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
