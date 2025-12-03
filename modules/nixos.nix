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

  # Check if any stash for a user has init.enable = true
  userHasInitEnabled = userCfg: lib.any (s: s.init.enable) (lib.attrValues userCfg.stashes);

  # Get stashes with init enabled for a user
  stashesWithInit = userCfg: lib.filterAttrs (_: s: s.init.enable) userCfg.stashes;

  # Generate init commands for each stash
  mkInitCommands =
    stashesToInit:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: stash:
        let
          ref = if stash.init.source.ref != null then stash.init.source.ref else "";
          funcName = "init_${stash.init.source.type}";
          lastArg =
            if stash.init.source.type == "git" then
              lib.escapeShellArg ref
            else
              toString stash.init.source.stripComponents;
        in
        "${funcName} ${lib.escapeShellArg name} ${lib.escapeShellArg stash.path} ${lib.escapeShellArg stash.init.source.url} ${lastArg}"
      ) stashesToInit
    );

  # Generate the init script for a user's stashes
  mkInitScript =
    username: userCfg:
    let
      stashCli = config.lib.stash.packages.stash-cli;
      stashesToInit = stashesWithInit userCfg;
      initCommands = mkInitCommands stashesToInit;
    in
    pkgs.writeShellScript "stash-init-${username}" ''
      set -euo pipefail

      log() {
        echo "[stash-init] $*"
      }

      init_git() {
        local name="$1"
        local path="$2"
        local url="$3"
        local ref="$4"

        if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
          log "Stash '$name' already exists at $path, skipping"
          return 0
        fi

        log "Cloning git repository for stash '$name'..."
        mkdir -p "$(dirname "$path")"

        if [ -n "$ref" ]; then
          ${pkgs.git}/bin/git clone --branch "$ref" "$url" "$path"
        else
          ${pkgs.git}/bin/git clone "$url" "$path"
        fi

        log "Successfully cloned stash '$name'"
      }

      init_tarball() {
        local name="$1"
        local path="$2"
        local url="$3"
        local strip="$4"

        if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
          log "Stash '$name' already exists at $path, skipping"
          return 0
        fi

        log "Downloading tarball for stash '$name'..."
        mkdir -p "$path"

        ${pkgs.curl}/bin/curl -fsSL "$url" | \
          ${pkgs.gnutar}/bin/tar -xz --strip-components="$strip" -C "$path"

        log "Successfully extracted stash '$name'"
      }

      init_zip() {
        local name="$1"
        local path="$2"
        local url="$3"
        local strip="$4"

        if [ -d "$path" ] && [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
          log "Stash '$name' already exists at $path, skipping"
          return 0
        fi

        log "Downloading zip archive for stash '$name'..."
        mkdir -p "$path"

        local tmpdir
        tmpdir=$(mktemp -d)
        trap "rm -rf '$tmpdir'" EXIT

        local zipfile="$tmpdir/archive.zip"
        ${pkgs.curl}/bin/curl -fsSL -o "$zipfile" "$url"

        # Extract to temp directory first for strip-components support
        ${pkgs.unzip}/bin/unzip -q "$zipfile" -d "$tmpdir/extracted"

        if [ "$strip" -gt 0 ]; then
          # Find the directory at the strip depth and copy contents
          local src
          src=$(find "$tmpdir/extracted" -mindepth "$strip" -maxdepth "$strip" -type d | head -1)
          if [ -n "$src" ]; then
            cp -r "$src"/* "$path"/ 2>/dev/null || cp -r "$src"/.[!.]* "$path"/ 2>/dev/null || true
          fi
        else
          cp -r "$tmpdir/extracted"/* "$path"/ 2>/dev/null || true
        fi

        log "Successfully extracted stash '$name'"
      }

      # Initialize each stash
      ${initCommands}

      # Run stash sync to create symlinks for the newly fetched content
      log "Running stash sync..."
      ${stashCli}/bin/stash sync
    '';

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
        ExecStart = "${generationPackage}/activate";
      };
    };

  mkInitSystemdUnit =
    username: userCfg:
    lib.nameValuePair "stash-init-${utils.escapeSystemdPath username}" {
      description = "Stash initialization for ${username}";

      # Run after network is available, but don't block boot
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        # Run after main stash activation so gcroots exist for `stash sync`
        "stash-${utils.escapeSystemdPath username}.service"
      ];

      unitConfig = {
        RequiresMountsFor = config.users.users.${username}.home;
        # Only start automatically on boot, not on every reload
        RefuseManualStop = false;
      };

      serviceConfig = {
        User = username;
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "10m"; # Longer timeout for network operations
        SyslogIdentifier = "stash-init-${username}";
        ExecStart = mkInitScript username userCfg;

        # Restart on failure with backoff
        Restart = "on-failure";
        RestartSec = "30s";
        RestartMaxDelaySec = "5m";
      };

      # Start on boot but don't block anything
      wantedBy = [ "default.target" ];
    };

  stashModule = mkStashModule {
    getUserConfig = username: {
      homeDirectory = config.users.users.${username}.home;
      user = username;
    };
  };

  # Build the services attrset, only including init units where needed
  activationUnits = lib.mapAttrs' (
    username: userCfg: mkSystemdUnit username userCfg.generationPackage
  ) cfg.users;

  initUnits = lib.mapAttrs' mkInitSystemdUnit (lib.filterAttrs (_: userHasInitEnabled) cfg.users);
in
{
  imports = [ stashModule ];

  config = {
    systemd.services = activationUnits // initUnits;
  };
}
