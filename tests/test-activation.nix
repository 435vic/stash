# test activation script without the overhead of a full VM
{ pkgs, ...}: let
  inherit (pkgs) lib;

  mkActivationTest = name: {
    oldGeneration ? null,
    newGeneration,
    preActivation ? "",
    postActivation ? "",
  }: pkgs.runCommand name {
    nativeBuildInputs = [
      "deno"
      pkgs.writableTmpDirAsHomeHook
    ];
  } ''
    gcRoots=$HOME/.local/state/stash/gcroots
    mkdir -p $gcRoots
    ${lib.optionalString (oldGeneration != null) ''
      oldGen=$gcRoots/old-home
      mkdir -p $oldGen
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: ''
        mkdir -p $${basename "${n}"}
        ln -s ${pkgs.writeTextFile "stash-file-test" v.content} $${basename "${n}"}
      '') oldGeneration)}
      
    ''} 
  '';
in {


}
