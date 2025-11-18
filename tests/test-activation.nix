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
      outputHash = "sha256-KTwM7vtTDl2hw+CjlYVu4o7w319DASzXIt6shIh77a4=";

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
      export STASH_TEST_MODE=1
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
      "--allow-env=HOME,XDG_STATE_HOME,'STASH_*'"
      "--allow-run=cmp"
      "-RW"
  ];};

  mkGeneration = config: let
    stashModule = import ../modules/stash.nix;
    evaluated = evalModules {
      modules = [ config stashModule ]; 
      specialArgs = { inherit pkgs lib; name = "tester"; };
    };
  in evaluated.config.generationPackage;

  # Helper to create a manifest file
  mkManifest = entries: pkgs.writeText "manifest.json" (builtins.toJSON entries);

  # Helper to create file tree in HOME
  setupHomeFiles = homeFiles: lib.concatStringsSep "\n" (
    lib.mapAttrsToList (path: attrs: let
      content = attrs.content or "";
      isSymlink = attrs.symlink or null;
      executable = attrs.executable or false;
    in
      if isSymlink != null then ''
        targetDir="$HOME/$(dirname "${path}")"
        mkdir -p "$targetDir"
        ln -s "${isSymlink}" "$HOME/${path}"
      '' else ''
        targetDir="$HOME/$(dirname "${path}")"
        mkdir -p "$targetDir"
        cat > "$HOME/${path}" << 'FILE_EOF'
        ${content}
        FILE_EOF
        ${lib.optionalString executable "chmod +x \"$HOME/${path}\""}
      ''
    ) homeFiles
  );

  mkActivationTest = {
    name,
    oldGen ? null,
    oldManifest ? null,
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
      # pkgs.writableTmpDirAsHomeHook
    ];
  } ''
    # Make HOME the output of the derivation so it can be inspected manually
    export HOME=$out
    export XDG_STATE_HOME="$HOME/.local/state"
    mkdir -p "$XDG_STATE_HOME/stash/gcroots"
    gcRootsDir="$XDG_STATE_HOME/stash/gcroots"

    ${setupHomeFiles homeFiles}

    ${lib.optionalString (oldGen != null) ''
      oldGenPath="${mkGeneration oldGen}"
      echo "Old generation: $oldGenPath"
      
      # Create gcroot for old generation
      ln -sf "$oldGenPath" "$gcRootsDir/current-home"
      
      ${if oldManifest != null then ''
        # Use explicit manifest
        cat > "$manifestPath" << 'MANIFEST_EOF'
        ${builtins.toJSON oldManifest}
        MANIFEST_EOF
        echo "Using custom manifest"
      '' else ''
        # Auto-generate manifest from oldGen's stash.json
        if [ -f "$oldGenPath/stash.json" ]; then
          # Create a basic manifest from the stash.json
          # This simulates what a proper activation would have created
          jq 'to_entries | map({
            key: .key,
            value: {
              source: .value.source,
              target: .value.target,
              parent: null,
              static: .value.static,
              forced: (.value.forced // false)
            }
          }) | from_entries' "$oldGenPath/stash.json" > "$manifestPath"
          echo "Auto-generated manifest from old generation"
        fi
      ''}
    ''}

    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (path: content: ''
      targetDir="$HOME/$(dirname "${path}")"
      mkdir -p "$targetDir"
      cat > "$HOME/${path}" << 'FILE_EOF'
      ${content}
      FILE_EOF
    '') homeFiles)}

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
