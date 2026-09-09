{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.dank-material-shell;
in
{
  packages = [
    cfg.package
  ]
  ++ lib.optional cfg.enableSystemMonitoring cfg.dgop.package
  ++ lib.optionals cfg.enableVPN [
    pkgs.glib
    pkgs.networkmanager
  ]
  ++ lib.optional cfg.enableDynamicTheming pkgs.matugen
  ++ lib.optional cfg.enableAudioWavelength pkgs.cava
  ++ lib.optional cfg.enableCalendarEvents pkgs.khal;
}
