{
  lib,
  dmsPkgs,
  pkgs,
  ...
}:
let
  inherit (lib) types;
  path = [
    "programs"
    "dank-material-shell"
  ];
  builtInRemovedMsg = "This is now built-in in DMS and doesn't need additional dependencies.";
in
{
  imports = [
    (lib.mkRemovedOptionModule (path ++ [ "enableBrightnessControl" ]) builtInRemovedMsg)
    (lib.mkRemovedOptionModule (path ++ [ "enableColorPicker" ]) builtInRemovedMsg)
    (lib.mkRemovedOptionModule (path ++ [ "enableClipboard" ]) builtInRemovedMsg)
    (lib.mkRemovedOptionModule (
      path ++ [ "enableSystemSound" ]
    ) "qtmultimedia is now included on dms-shell package.")
    ./dms-rename.nix
  ];

  options.programs.dank-material-shell = {
    enable = lib.mkEnableOption "DankMaterialShell";
    package = lib.mkPackageOption dmsPkgs "dms-shell" {
      extraDescription = "The DankMaterialShell package to use (defaults to be built from source)";
    };

    systemd = {
      enable = lib.mkEnableOption "DankMaterialShell systemd startup";
      restartIfChanged = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Auto-restart dms.service when dank-material-shell changes";
      };
    };

    dgop = {
      package = lib.mkPackageOption pkgs "dgop" { };
    };

    enableSystemMonitoring = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Add needed dependencies to use system monitoring widgets";
    };

    enableVPN = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Add needed dependencies to use the VPN widget";
    };

    enableDynamicTheming = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Add needed dependencies to have dynamic theming support";
    };

    enableAudioWavelength = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Add needed dependencies to have audio wavelength support";
    };

    enableCalendarEvents = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Add calendar events support via khal";
    };

    enableClipboardPaste = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Deprecated: paste is built into dms; no extra dependencies needed. Kept as a no-op for compatibility.";
    };

    quickshell = {
      package = lib.mkPackageOption pkgs "quickshell" {
        extraDescription = "(we recommend at least 0.3.0, currently available in nixos-unstable)";
      };
    };

  };
}
