{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    nix-unit.url = "github:nix-community/nix-unit";
    nix-unit.inputs.nixpkgs.follows = "nixpkgs";
    nix-unit.inputs.flake-parts.follows = "flake-parts";
  };

  outputs =
    inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.nix-unit.modules.flake.default
      ];

      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      flake = {
        nixosConfigurations.test = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            ./modules/nixos.nix
            ./tests/test-machine.nix
          ];
        };
      };

      perSystem =
        {
          pkgs,
          inputs',
          system,
          ...
        }:
        let
          activationTester = import ./tests/activation { inherit pkgs; };
          vmTests = import ./tests/vm { inherit pkgs; };
        in
        {
          nix-unit.inputs = {
            inherit (inputs) nixpkgs nix-unit flake-parts;
          };

          checks = activationTester.tests;

          legacyPackages = { inherit activationTester vmTests; };

          nix-unit.tests =
            let
              moduleTests = import ./tests/module-eval {
                inherit pkgs;
                module = ./modules;
              };
            in
            moduleTests;

          devShells.default = pkgs.mkShellNoCC {
            packages = [
              pkgs.deno
              inputs'.nix-unit.packages.nix-unit
              (pkgs.writeShellScriptBin "run-module-tests" ''
                ${inputs'.nix-unit.packages.nix-unit}/bin/nix-unit --flake .#tests.systems.${system}
              '')
            ];
          };
        };
    };
}
