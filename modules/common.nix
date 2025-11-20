# not yet used, would apply to darwin (?)
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption;
  cfg = config.stash;
in
{
  options.stash.users = mkOption {
    type = lib.types.attrsOf (
      lib.types.submoduleWith {
        specialArgs = { inherit pkgs; };
        modules = [
          ./.
          (
            { name, ... }:
            {
              config.homeDirectory = config.users.users.${name}.home;
            }
          )
        ];
      }
    );
    default = { };
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
      fromStash =
        { stash, path }:
        {
          inherit stash path;
          static = false;
        };
    };
  };
}
