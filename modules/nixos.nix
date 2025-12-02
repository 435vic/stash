# NixOS-specific module for Stash
#
# Imports the common module factory and adds systemd service integration
# for automatic activation on system boot/switch.
{
  lib,
  config,
  utils,
  pkgs,
  ...
}:
let
  inherit ((import ./common.nix { inherit lib pkgs; })) mkStashModule;

  cfg = config.stash;

  mkSystemdUnit =
    username: generationPackage:
    lib.nameValuePair "stash-${utils.escapeSystemdPath username}" {
      description = "Stash activation for ${username}";
      wantedBy = [ "multi-user.target" ];
      wants = [ "nix-daemon.socket" ];
      after = [ "nix-daemon.socket" ];
      before = [ "systemd-user-sessions.service" ];

      unitConfig = {
        RequiresMountsFor = config.users.users.${username}.home;
      };

      stopIfChanged = false;

      serviceConfig = {
        User = username;
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5m";
        SyslogIdentifier = "stash-activate-${username}";
        ExecStart = "${config.lib.stash.packages.stash-activate}/bin/stash-activate ${generationPackage}";
      };
    };

  stashModule = mkStashModule {
    getUserConfig = username: {
      homeDirectory = config.users.users.${username}.home;
      user = username;
    };
  };
in
{
  imports = [ stashModule ];

  config = {
    systemd.services = lib.mapAttrs' (
      username: userCfg: mkSystemdUnit username userCfg.generationPackage
    ) cfg.users;
  };
}
