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
            ./tests/test-machine.nix
          ];
        };
      };

      perSystem = { pkgs, inputs', ... }: {
        nix-unit.inputs = {
          inherit (inputs) nixpkgs nix-unit flake-parts;
        };

        nix-unit.tests = let
          moduleTester = import ./tests/unit/module-tester.nix { inherit pkgs; } (import ./modules/stash.nix);
          moduleTests = moduleTester (import ./tests/unit/module-tests.nix);
        in moduleTests;

        devShells.default = pkgs.mkShellNoCC {
          packages = [ pkgs.deno inputs'.nix-unit.packages.nix-unit ];
        };
      };
    };
}
