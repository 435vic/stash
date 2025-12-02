# Common module factory for Stash - shared across NixOS, nix-darwin, and standalone
#
# This file exports a function `mkStashModule` that creates a platform-specific
# Stash module. Platform modules (nixos.nix, darwin.nix) call this function
# with their specific configuration for resolving user home directories.
#
# Usage:
#   mkStashModule {
#     getUserConfig = username: {
#       homeDirectory = config.users.users.${username}.home;
#       user = username;
#     };
#   }
{ lib, pkgs }:

{
  # Function to create a platform-specific Stash module
  #
  # Arguments:
  #   getUserConfig: A function that takes a username and returns an attrset
  #                  with `homeDirectory` and `user` to inject into the per-user module.
  mkStashModule =
    { getUserConfig }:
    { config, ... }:
    let
      cfg = config.stash;
      stashPkgs = import ../pkgs { inherit pkgs; };
    in
    {
      options.stash = {
        users = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submoduleWith {
              specialArgs = { inherit pkgs; };
              modules = [
                ./.
                (
                  { name, ... }:
                  {
                    config = getUserConfig name;
                  }
                )
              ];
            }
          );
          default = { };
          description = ''
            Stash configuration per user.

            Each attribute name should be a username, and the value is the
            Stash configuration for that user (files, stashes, etc.).
          '';
        };
      };

      config = {
        assertions = lib.flatten (
          lib.flip lib.mapAttrsToList cfg.users (
            user: userCfg:
            lib.flip lib.map userCfg.assertions (assertion: {
              inherit (assertion) assertion;
              message = "${user} stash config: ${assertion.message}";
            })
          )
        );

        lib.stash = {
          # Helper to create a source reference from a stash
          fromStash =
            { stash, path }:
            {
              inherit stash path;
              static = false;
            };

          # Expose packages for platform modules to use
          packages = stashPkgs;
        };
      };
    };
}
