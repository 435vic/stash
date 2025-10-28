{ lib, config, utils, pkgs, ... }:
let
  inherit (lib) mkOption types;

  mkSystemdUnit = userCfg: execStart: lib.nameValuePair "stash-${utils.escapeSystemdPath}" (let
    inherit (userCfg) username;
  in {
    description = "stash setup for ${username}";
    wantedBy = [ "multi-user.target" ];
    wants = [ "nix-daemon.socket" ];
    after = [ "nix-daemon.socket" ];
    before = [ "systemd-user-sessions.service" ];

    unitConfig = {
      requiresMountsFor = config.users.users.${username}.home;
    };

    stopIfChanged = false;

    serviceConfig = {
      user = username;
      type = "oneshot";
      timeoutStartSec = "5m";
      syslogIdentifier = "stash-activate-${username}";
      execStart = execStart;
    };
  });
in {
  options.stash.users = mkOption {
    type = lib.types.attrsOf (lib.types.submoduleWith {
      specialArgs = { inherit pkgs; };
      modules = [ ./stash.nix ];
    });
    default = {};
    description = "Stash configuration for given user.";
  };
}
