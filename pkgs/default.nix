{ pkgs, ... }:
let
  mkDenoScript = pkgs.callPackage ./mk-deno-script.nix { };
in
{
  inherit mkDenoScript;

  stash-activate = mkDenoScript {
    name = "stash-activate";
    src = ./activate/activate.ts;
    denoDepsHash = "sha256-sg+riBz2X18yvm/iGou1Q3VcFLOt40psvV6sRjGLg8E=";
    denoArgs = [ "-A" ];
  };

  stash-cli = mkDenoScript {
    name = "stash";
    src = ./cli/cli.ts;
    denoDepsHash = "sha256-XJtXHy4691BszFb2S0OpqK0Wajk0+fCvOtiJeAwzB/Q=";
    denoArgs = [ "-A" ];
  };
}
