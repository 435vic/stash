{ pkgs, ... }:
let
  inherit (pkgs) lib;
  inherit (lib) evalModules;

  stashPkgs = import ../../pkgs { inherit pkgs; };
in
rec {
  testUser = "tester";
  testHome = "/tmp/testhome";

  # Helper to create file tree in HOME
  setupHomeFiles =
    homeFiles:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        path: attrs:
        let
          content = attrs.content or "";
          isSymlink = attrs.symlink or null;
          executable = attrs.executable or false;
        in
        if isSymlink != null then
          ''
            targetDir="$HOME/$(dirname "${path}")"
            mkdir -p "$targetDir"
            ln -s "${isSymlink}" "$HOME/${path}"
          ''
        else
          ''
            targetDir="$HOME/$(dirname "${path}")"
            mkdir -p "$targetDir"
            cat > "$HOME/${path}" << 'FILE_EOF'
            ${content}
            FILE_EOF
            ${lib.optionalString executable "chmod +x \"$HOME/${path}\""}
          ''
      ) homeFiles
    );

  makeManifest = pkgs.writers.writeBash "make-manifest" ./make-manifest.sh;
  mkGeneration =
    config:
    let
      stashModule = import ../../modules;
      evaluated = evalModules {
        modules = [
          config
          stashModule
          {
            homeDirectory = testHome;
            user = testUser;
          }
        ];
        specialArgs = {
          inherit pkgs lib;
          name = "tester";
        };
      };
    in
    evaluated.config.generationPackage;

  activateScript = pkgs.writeShellScriptBin "stash-activate-test" ''
    export STASH_TEST_MODE=1
    exec ${stashPkgs.stash-activate}/bin/stash-activate "$@"
  '';

  mkActivationTest =
    {
      name,
      oldGen ? null,
      oldManifest ? null,
      newGen,
      homeFiles ? { },
      env ? { },
      expectFailure ? false,
      expectedExitCode ? 1,
      expectedErrorRegex ? null,
      preActivation ? "",
      postManifestGeneration ? "",
      postActivation ? "",
    }:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.deno
          pkgs.diffutils
          pkgs.coreutils
          pkgs.findutils
          pkgs.jq
          # pkgs.writableTmpDirAsHomeHook
        ];

        USER = testUser;
        HOME = testHome;
        XDG_STATE_HOME = "${testHome}/.local/state";
      }
      ''
        mkdir -p $HOME
        mkdir -p "$XDG_STATE_HOME/stash/gcroots"
        gcRootsDir="$XDG_STATE_HOME/stash/gcroots"

        ${setupHomeFiles homeFiles}

        ${lib.optionalString (oldGen != null) ''
          oldGenPath="${mkGeneration oldGen}"
          echo "Old generation: $oldGenPath"

          # Create gcroot for old generation
          ln -sf "$oldGenPath" "$gcRootsDir/current-home"

          manifestPath="$XDG_STATE_HOME/stash/manifest.json"
          mkdir -p "$(dirname "$manifestPath")"

          ${
            if oldManifest != null then
              ''
                # Use explicit manifest
                cat > "$manifestPath" << 'MANIFEST_EOF'
                ${builtins.toJSON oldManifest}
                MANIFEST_EOF
                echo "Using custom manifest"
              ''
            else
              ''
                # Auto-generate manifest from oldGen's stash.json using helper script
                if [ -f "$oldGenPath/stash.json" ]; then
                  ${makeManifest} "$oldGenPath/stash.json" > "$manifestPath"
                  echo "Auto-generated manifest from old generation"
                fi
              ''
          }
        ''}

        newGenPath="${mkGeneration newGen}"
        echo "New generation path: $newGenPath"

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: value: ''
            export ${name}="${value}"
          '') env
        )}

        echo "=== Running before-activation checks ==="
        ${preActivation}

        ${lib.optionalString (postManifestGeneration != "") ''
          echo "=== Running post-manifest-generation hook ==="
          ${postManifestGeneration}
        ''}

        echo "=== Running activation script ==="

        ${
          if expectFailure then
            ''
              set +e
              ACTIVATE_STDERR="$TMPDIR/activate-stderr.log"
              ACTIVATE_STDOUT="$TMPDIR/activate-stdout.log"
              ${activateScript}/bin/stash-activate-test "$newGenPath" \
                >"$ACTIVATE_STDOUT" 2>"$ACTIVATE_STDERR"
              ACTIVATE_EXIT=$?
              set -e

              echo "Activation exited with code: $ACTIVATE_EXIT"
              cat "$ACTIVATE_STDOUT"
              cat "$ACTIVATE_STDERR" >&2

              echo "exit code: $ACTIVATE_EXIT"

              if [ "$ACTIVATE_EXIT" -eq 0 ]; then
                echo "Expected activation to fail but it succeeded"
                exit 1
              fi

              ${lib.optionalString (expectedExitCode != null) ''
                if [ "$ACTIVATE_EXIT" -ne ${toString expectedExitCode} ]; then
                  echo "Expected exit code ${toString expectedExitCode}, got $ACTIVATE_EXIT"
                  exit 1
                fi
              ''}

              ${lib.optionalString (expectedErrorRegex != null) ''
                if ! grep -E '${expectedErrorRegex}' "$ACTIVATE_STDERR" >/dev/null 2>&1; then
                  echo "Expected error message matching /${expectedErrorRegex}/ not found in stderr"
                  echo "stderr was:"
                  cat "$ACTIVATE_STDERR" >&2
                  exit 1
                fi
              ''}
            ''
          else
            ''
              ${activateScript}/bin/stash-activate-test "$newGenPath"
              echo "=== Running after-activation checks ==="
              pushd $HOME >/dev/null
              ${postActivation}
              popd >/dev/null
            ''
        }
        cd $HOME
        echo "Test passed: ${name}"
        mkdir -p $out
        cp -r . $out
      '';
}
