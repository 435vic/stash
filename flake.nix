{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }: let
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      # "aarch64-darwin"
    ];

    pkgsForSystem = system: nixpkgs.legacyPackages.${system};

    eachSystem = f: nixpkgs.lib.genAttrs supportedSystems (system: f { pkgs = pkgsForSystem system; });
  in {
    lib = {
      inherit supportedSystems eachSystem;
    };

    nixosConfigurations.test = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./tests/test-machine.nix
      ];
    };

    devShells = eachSystem ({ pkgs, ...}: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.nix-unit
        ];
      };
    });
  };
}
