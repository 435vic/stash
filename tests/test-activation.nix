{ pkgs, ... }: let
  inherit (pkgs) lib stdenv;
  inherit (lib) evalModules mapAttrs removeAttrs filterAttrs;

  mkDenoScript = script: {
    denoArgs ? [],
  }: let
    deps = stdenv.mkDerivation {
      name = "deno-script-deps";
      src = script;
      nativeBuildInputs = [ pkgs.deno ];
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = "sha256-WWN2HfBrr/ENhiNJrXLNF57ov+D6t6xI8pjlET79ICs=";

      phases = [ "buildPhase" "installPhase" ];

      buildPhase = ''
        deno install --vendor --entrypoint $src
      '';

      installPhase = "
        cp -r vendor/ $out
      ";
    };

    extraArgs = lib.concatStringsSep " " denoArgs;
    wrapperScript = ''
      #!${pkgs.runtimeShell}
      cd $out/lib
      deno run --vendor=true ${extraArgs} $filename \$@
    '';
  in pkgs.runCommandNoCC "deno-script" { passthru = { inherit deps; }; } ''
    mkdir -p $out/lib
    mkdir -p $out/bin
    ln -s ${deps} $out/lib/vendor

    fullpath="${script}"
    filename="''${fullpath##*/}"
    cp "${script}" $out/lib/$filename
    cat <<EOF >> $out/bin/run
      ${wrapperScript}
    EOF
    chmod +x $out/bin/run
  '';

  activateScript = mkDenoScript ../modules/activate.ts { denoArgs = [
      "--allow-env=HOME,XDG_STATE_HOME"
      "-R"
  ];};

  mkGeneration = config: let
    stashModule = import ../modules/stash.nix;
    evaluated = evalModules {
      modules = [ config stashModule ]; 
      specialArgs = { inherit pkgs lib; name = "tester"; };
    };
  in evaluated.config.generationPackage;

  mkActivationTest = {
    name,
    oldGen ? null,
    newGen,
    homeFiles ? {},
    env ? {},
    expectFailure ? false,
    preActivation ? "",
    postActivation ? "",
  }: pkgs.runCommand name {
    nativeBuildInputs = [
      pkgs.deno
      pkgs.diffutils
      pkgs.coreutils
      pkgs.writableTmpDirAsHomeHook
    ];
  } ''
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$XDG_STATE_HOME/stash/gcroots"
    gcRootsDir="$XDG_STATE_HOME/stash/gcroots"

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: content: ''
      targetDir="$HOME/$(dirname "${path}")"
      mkdir -p "$targetDir"
      cat > "$HOME/${path}" << 'FILE_EOF'
      ${content}
      FILE_EOF
    '') homeFiles)}

    # Setup old generation if specified
    ${lib.optionalString (oldGen != null) ''
      oldGenPath="${mkGeneration oldGen}"
      ln -s "$oldGenPath" "$gcRootsDir/current-home"
      echo "Old generation set up at: $oldGenPath"
    ''}

    newGenPath="${mkGeneration newGen}"
    echo "New generation path: $newGenPath"

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: ''
      export ${name}="${value}"
    '') env)}

    echo "=== Running before-activation checks ==="
    ${preActivation}

    echo "=== Running activation script ==="
    ${lib.optionalString expectFailure "set +e"}
    ${activateScript}/bin/run "$newGenPath"
    ${lib.optionalString expectFailure "set -e"}

    ${lib.optionalString (!expectFailure) ''
      echo "=== Running after-activation checks ==="
      ${postActivation}
    ''}

    echo "Test passed: ${name}"
    touch $out
  '';
in {
  inherit mkActivationTest mkGeneration activateScript;
  tests = {
    test-empty = mkActivationTest {
      name = "empty-test";
      newGen = {};
    };

    test-collision = mkActivationTest {
      name = "collision-test";

      homeFiles = {
        "collides" = "asfadjglkdsjew";
      };

      newGen = {
        files."collides".text = "ooo look at meee i collide";
      };
    };
  };
}
