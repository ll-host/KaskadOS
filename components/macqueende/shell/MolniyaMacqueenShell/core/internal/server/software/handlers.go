package software

import (
	"github.com/AvengeMedia/DankMaterialShell/core/internal/server/models"
)

func HandleRequest(conn *models.Conn, req models.Request, manager *Manager) {
	switch req.Method {
	case "software.search":
		query := models.GetOr(req, "query", "")
		source := Source(models.GetOr(req, "source", ""))
		if source != "" && source != SourcePacman && source != SourceAUR && source != SourceFlatpak {
			models.RespondError(conn, req.ID, "неизвестный источник приложений")
			return
		}
		models.Respond(conn, req.ID, manager.Search(query, source))
	case "software.installed":
		models.Respond(conn, req.ID, manager.Installed())
	case "software.state":
		models.Respond(conn, req.ID, manager.State())
	case "software.install":
		item, ok := itemFromRequest(req)
		if !ok {
			models.RespondError(conn, req.ID, "некорректные данные приложения")
			return
		}
		if err := manager.Install(item); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "software.remove":
		item, ok := itemFromRequest(req)
		if !ok {
			models.RespondError(conn, req.ID, "некорректные данные приложения")
			return
		}
		if err := manager.Remove(item); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "software.installLocal":
		path, ok := models.Get[string](req, "path")
		if !ok {
			models.RespondError(conn, req.ID, "не указан путь к пакету")
			return
		}
		if err := manager.InstallLocal(path); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "software.cancel":
		manager.Cancel()
		models.Respond(conn, req.ID, manager.State())
	default:
		models.RespondError(conn, req.ID, "unknown method: "+req.Method)
	}
}

func itemFromRequest(req models.Request) (Item, bool) {
	id, okID := models.Get[string](req, "id")
	packageName, okPackage := models.Get[string](req, "packageName")
	name := models.GetOr(req, "name", packageName)
	sourceText, okSource := models.Get[string](req, "source")
	if !okID || !okPackage || !okSource {
		return Item{}, false
	}
	return Item{
		ID: id, PackageName: packageName, Name: name,
		Description: models.GetOr(req, "description", ""),
		Version:     models.GetOr(req, "version", ""),
		Source:      Source(sourceText), Installed: models.GetOr(req, "installed", false),
		Remote: models.GetOr(req, "remote", ""),
	}, true
}
