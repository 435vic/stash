{ lib, config, utils, pkgs, ... }:
let
  inherit (lib) mkOption types;
  
  cfg = config.stash;

  # 1. Check collisions; a collision occurs if
  #   - target exists AND
  #   - forced != true AND
  #   - source != target (in content, cmp -s) AND
  #   - backup not configured or impossible (backup alr exists)
  # 2. Clean up old gen's links
  #   - Delete links in the old generation NOT in the new generation (cmp by source path)
  #   - Recursively delete old directories
  # 3. Make new gen's links
  #   - Backup target path if it exists and not a symlink (and backups enabled)
  #   - If source == target don't symlink, not necessary
  #   - place symlink with --force (so target path matches new gen)
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
      modules = [
        ./stash.nix
        ({name, ...}: { config.homeDirectory = config.users.users.${name}.home; })
      ];
    });
    default = {};
    description = "Stash configuration for given user.";
  };

  config = {
    assertions = lib.flatten (
      lib.flip lib.mapAttrsToList cfg.users (
        user: config:
        lib.flip map config.assertions (assertion: {
          inherit (assertion) assertion;
          message = "${user} stash config: ${assertion.message}";
        })
      )
    );

    lib.stash = {
      fromStash = { stash, path }: {
        inherit stash path;
        static = false;
      };
    };
  };
}
