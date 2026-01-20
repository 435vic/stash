{ pkgs, ... }:
let
  mkDenoScript = pkgs.callPackage ./mk-deno-script.nix { };
in
{
  inherit mkDenoScript;

  stash-activate = mkDenoScript {
    name = "stash-activate";
    src = ./activate/activate.ts;
    denoDepsHash = "sha256-qa10CZ3mzsB91kB7Kh+cFtiQbxQtz7h6EFsLAiEAvbc=";
    denoArgs = [ "-A" ];
  };

  stash-cli = mkDenoScript {
    name = "stash";
    src = ./cli/cli.ts;
    denoDepsHash = "sha256-caLoxdC3y1en/uNM5WUmyzUdSA88z7YKhN+3YuRC4Ow=";
    denoArgs = [ "-A" ];
  };
}
