{ pkgs }: let
  inherit (pkgs) lib;
  inherit (lib) mapAttrs' mapAttrs nameValuePair pipe filterAttrs substring;
  mkTest = 
    suite: config: testName: { expr, expected, ... }: {
      name = "test suite ${suite} - ${testName}";
      value = {
        inherit expected;
        expr = expr config;
      };
    };
in module: mapAttrs (name: value: let
  evaluatedConfig = (lib.evalModules {
    modules = [ value.config module ];
    specialArgs = {
      inherit pkgs lib;
    };
  }).config;
in pipe value [
  (filterAttrs (n: _: (substring 0 4 n == "test"))) 
  (mapAttrs' (mkTest name evaluatedConfig))
])

