package windowsapps

import "github.com/AvengeMedia/DankMaterialShell/core/internal/server/models"

func HandleRequest(conn *models.Conn, req models.Request, manager *Manager) {
	switch req.Method {
	case "windows.apps":
		models.Respond(conn, req.ID, manager.Apps())
	case "windows.runtimes":
		models.Respond(conn, req.ID, manager.Runtimes())
	case "windows.releases":
		releases, err := manager.Releases()
		if err != nil {
			models.RespondError(conn, req.ID, "не удалось получить список версий Proton")
			return
		}
		models.Respond(conn, req.ID, releases)
	case "windows.state":
		models.Respond(conn, req.ID, manager.State())
	case "windows.installRuntime":
		release, ok := releaseFromRequest(req)
		if !ok {
			models.RespondError(conn, req.ID, "некорректные данные версии Proton")
			return
		}
		if err := manager.InstallRuntime(release); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "windows.open":
		path, ok := models.Get[string](req, "path")
		if !ok {
			models.RespondError(conn, req.ID, "не указан путь к EXE")
			return
		}
		if err := manager.OpenExecutable(path, models.GetOr(req, "runtimeTag", "")); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "windows.setRuntime":
		id, idOK := models.Get[string](req, "id")
		runtimeTag, runtimeOK := models.Get[string](req, "runtimeTag")
		if !idOK || !runtimeOK {
			models.RespondError(conn, req.ID, "не указано приложение или версия Proton")
			return
		}
		if err := manager.SetRuntime(id, runtimeTag); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "windows.removeRuntime":
		runtimeTag, ok := models.Get[string](req, "runtimeTag")
		if !ok {
			models.RespondError(conn, req.ID, "не указана версия Proton")
			return
		}
		if err := manager.RemoveRuntime(runtimeTag); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "windows.launch":
		id, ok := models.Get[string](req, "id")
		if !ok {
			models.RespondError(conn, req.ID, "не указан идентификатор приложения")
			return
		}
		if err := manager.Launch(id); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, manager.State())
	case "windows.remove":
		id, ok := models.Get[string](req, "id")
		if !ok {
			models.RespondError(conn, req.ID, "не указан идентификатор приложения")
			return
		}
		if err := manager.Remove(id, models.GetOr(req, "removePrefix", false)); err != nil {
			models.RespondError(conn, req.ID, err.Error())
			return
		}
		models.Respond(conn, req.ID, models.SuccessResult{Success: true})
	case "windows.cancel":
		manager.Cancel()
		models.Respond(conn, req.ID, manager.State())
	default:
		models.RespondError(conn, req.ID, "unknown method: "+req.Method)
	}
}

func releaseFromRequest(req models.Request) (Release, bool) {
	tag, tagOK := models.Get[string](req, "tag")
	archiveURL, urlOK := models.Get[string](req, "archiveUrl")
	if !tagOK || !urlOK {
		return Release{}, false
	}
	return Release{
		Tag:         tag,
		PublishedAt: models.GetOr(req, "publishedAt", ""),
		PageURL:     models.GetOr(req, "pageUrl", ""),
		ArchiveURL:  archiveURL,
		ArchiveName: models.GetOr(req, "archiveName", tag+".tar.gz"),
		ArchiveSize: int64(models.GetOr[float64](req, "archiveSize", 0)),
		ChecksumURL: models.GetOr(req, "checksumUrl", ""),
		Prerelease:  models.GetOr(req, "prerelease", false),
	}, true
}
