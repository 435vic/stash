{ pkgs, module }:
let
  inherit (pkgs) lib;
  inherit (lib)
    mapAttrs'
    mapAttrs
    pipe
    filterAttrs
    substring
    ;
  mkTest =
    suite: config: name:
    { expr, expected, ... }:
    {
      inherit name;
      value = {
        inherit expected;
        expr = expr config;
      };
    };
in
mapAttrs (
  name: value:
  let
    evaluatedConfig =
      (lib.evalModules {
        modules = [
          value.config
          module
        ];
        specialArgs = {
          inherit pkgs lib;
        };
      }).config;
  in
  pipe value [
    (filterAttrs (n: _: (substring 0 4 n == "test")))
    (mapAttrs' (mkTest name evaluatedConfig))
  ]
) (import ./tests.nix { inherit pkgs lib; })
