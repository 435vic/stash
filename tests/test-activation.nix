{ pkgs, ... }:
let
  inherit (pkgs) lib stdenv;
  inherit (lib)
    evalModules
    mapAttrs
    removeAttrs
    filterAttrs
    ;

  testUser = "tester";
  testHome = "/tmp/testhome";

  mkDenoScript =
    script:
    {
      denoArgs ? [ ],
    }:
    let
      deps = stdenv.mkDerivation {
        name = "deno-script-deps";
        src = script;
        nativeBuildInputs = [ pkgs.deno ];
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = "sha256-KTwM7vtTDl2hw+CjlYVu4o7w319DASzXIt6shIh77a4=";

        phases = [
          "buildPhase"
          "installPhase"
        ];

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
    in
    pkgs.runCommandNoCC "deno-script" { passthru = { inherit deps; }; } ''
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

  activateScript = mkDenoScript ../modules/activate.ts {
    denoArgs = [
      "--allow-env=HOME,XDG_STATE_HOME,'STASH_*',USER"
      "--allow-run=cmp"
      "-RW"
    ];
  };

  mkGeneration =
    config:
    let
      stashModule = import ../modules;
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

  # Helper to create a manifest file
  mkManifest = entries: pkgs.writeText "manifest.json" (builtins.toJSON entries);

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

        echo "=== Running activation script ==="

        ${
          if expectFailure then
            ''
              set +e
              ACTIVATE_STDERR="$TMPDIR/activate-stderr.log"
              ACTIVATE_STDOUT="$TMPDIR/activate-stdout.log"
              ${activateScript}/bin/run "$newGenPath" \
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
              ${activateScript}/bin/run "$newGenPath"
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
in
{
  inherit mkActivationTest mkGeneration activateScript;
  tests = {
    test-empty = mkActivationTest {
      name = "empty-test";
      newGen = { };
    };

    test-collision = mkActivationTest {
      name = "collision-test";

      homeFiles = {
        "collides".content = "asfadjglkdsjew";
      };

      newGen = {
        files."collides" = {
          text = "ooo look at meee i collide";
        };
      };

      postActivation = ''
        if [ ! -e "collides.stash.bak" ]; then
          echo "backup expected at collides.bak but it does not exist"
        fi
      '';
    };

    # Unmanaged symlink at the target should be treated as a fatal collision.
    test-unmanaged-symlink-collision = mkActivationTest {
      name = "unmanaged-symlink-collision";

      homeFiles = {
        # User already has an unmanaged symlink here.
        "config/app/settings".symlink = "/some/unmanaged/target";
      };

      newGen = {
        files."config/app/settings" = {
          text = "managed-settings";
          # target defaults to "config/app/settings"
        };
      };

      preActivation = ''
        ls -la $HOME/config/app
        echo $HOME/config/app/settings
      '';

      expectFailure = true;
      expectedExitCode = 1;
      expectedErrorRegex = "fatal_collision|Fatal collisions found|Cannot continue: file at";
    };

    test-backup-on-regular-file = mkActivationTest {
      name = "backup-regular-file";

      homeFiles = {
        "config/app/settings".content = "original-user-content";
      };

      newGen = {
        files."config/app/settings" = {
          text = "managed-content";
        };
      };

      postActivation = ''
        target="$HOME/config/app/settings"
        backup="$target.stash.bak"

        if ! [ -L "$target" ]; then
          echo "Expected symlink at $target"
          exit 1
        fi

        if ! [ -f "$backup" ]; then
          echo "Expected backup file at $backup"
          exit 1
        fi

        if ! grep -q "original-user-content" "$backup"; then
          echo "Backup file does not contain original content"
          exit 1
        fi
      '';
    };

    test-forced-overwrite-file = mkActivationTest {
      name = "forced-overwrite-file";

      homeFiles = {
        "config/app/settings".content = "user-old";
      };

      preActivation = ''
        ls -al $HOME/config/app/settings
      '';

      newGen = {
        files."config/app/settings" = {
          text = "managed-new";
          forced = true;
        };
      };

      postActivation = ''
        target="$HOME/config/app/settings"
        backup="$target.stash.bak"

        if ! [ -L "$target" ]; then
          echo "Expected symlink at $target"
          exit 1
        fi

        if [ -e "$backup" ]; then
          echo "Did not expect backup file at $backup when forced overwrite is enabled"
          exit 1
        fi
      '';
    };

    test-recursive-stash-new-file = mkActivationTest {
      name = "recursive-stash-new-file";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      oldManifest = null;

      homeFiles = {
        "dotfiles/config-app/settings.toml".content = "foo = 1";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/dotfiles/config-app"
        echo 'bar = 2' > "$HOME/dotfiles/config-app/extra.toml"
        ls -R "$HOME/dotfiles"
      '';

      postActivation = ''
        if ! [ -L "$HOME/config/app/settings.toml" ]; then
          echo "Expected symlink at $HOME/config/app/settings.toml"
          exit 1
        fi

        if ! [ -L "$HOME/config/app/extra.toml" ]; then
          echo "Expected symlink at $HOME/config/app/extra.toml"
          exit 1
        fi

        # Use find to detect any unexpected backup files under config/app
        if find "$HOME/config/app" -maxdepth 1 -type f -name '*.stash.bak' | grep . >/dev/null 2>&1; then
          echo "Did not expect any backups under config/app"
          find "$HOME/config/app" -maxdepth 1 -type f -name '*.stash.bak'
          exit 1
        fi
      '';
    };

    test-recursive-stash-user-file-collision = mkActivationTest {
      name = "recursive-stash-user-file-collision";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/settings.toml".content = "stash-settings = 1";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/dotfiles/config-app"
        echo 'newstash = 1' > "$HOME/dotfiles/config-app/new-from-stash.toml"

        mkdir -p "$HOME/config/app"
        echo 'user-local = 1' > "$HOME/config/app/new-from-stash.toml"
      '';

      postActivation = ''
        target="$HOME/config/app/new-from-stash.toml"
        backup="$target.stash.bak"

        if ! [ -L "$target" ]; then
          echo "Expected symlink for new-from-stash.toml at $target"
          exit 1
        fi

        if ! [ -f "$backup" ]; then
          echo "Expected backup for user-local collision at $backup"
          exit 1
        fi

        if ! grep -q "user-local = 1" "$backup"; then
          echo "Backup did not preserve original user content"
          exit 1
        fi
      '';
    };

    test-recursive-stash-unmanaged-symlink-inside = mkActivationTest {
      name = "recursive-stash-unmanaged-symlink-inside";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/settings.toml".content = "stash-settings = 1";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/dotfiles/config-app"
        echo 'new = 1' > "$HOME/dotfiles/config-app/new-config.toml"

        mkdir -p "$HOME/config/app"
        ln -s "/some/unmanaged/location" "$HOME/config/app/new-config.toml"
      '';

      expectFailure = true;
      expectedExitCode = 1;
      expectedErrorRegex = "fatal_collision|Unmanaged symlink at target location|Fatal collisions found";
    };

    test-recursive-stash-remove-file = mkActivationTest {
      name = "recursive-stash-remove-file";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/keep.toml".content = "keep = 1";
        "dotfiles/config-app/delete-me.toml".content = "delete = 1";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      preActivation = ''
        rm -f "$HOME/dotfiles/config-app/delete-me.toml"

        mkdir -p "$HOME/config/app"
        if [ ! -L "$HOME/config/app/delete-me.toml" ]; then
          ln -s "$HOME/dotfiles/config-app/delete-me.toml" "$HOME/config/app/delete-me.toml" || true
        fi
        if [ ! -L "$HOME/config/app/keep.toml" ]; then
          ln -s "$HOME/dotfiles/config-app/keep.toml" "$HOME/config/app/keep.toml" || true
        fi
      '';

      postActivation = ''
        if ! [ -L "$HOME/config/app/keep.toml" ]; then
          echo "Expected keep.toml to remain as symlink"
          exit 1
        fi

        if [ -e "$HOME/config/app/delete-me.toml" ]; then
          echo "Expected delete-me.toml to be removed from HOME"
          exit 1
        fi

        if ! [ -d "$HOME/config/app" ]; then
          echo "Expected config/app directory to remain"
          exit 1
        fi
      '';
    };

    test-recursive-stash-forced-overwrite = mkActivationTest {
      name = "recursive-stash-forced-overwrite";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/settings.toml".content = "stash = 1";
        "dotfiles/config-app/other.toml".content = "stash-other = 1";

        "config/app/settings.toml".content = "user-settings";
        "config/app/other.toml".content = "user-other";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/config-app";
          };
          recursive = true;
          forced = true;
        };
      };

      postActivation = ''
        for f in settings.toml other.toml; do
          target="$HOME/config/app/$f"
          backup="$target.stash.bak"

          if ! [ -L "$target" ]; then
            echo "Expected forced symlink at $target"
            exit 1
          fi

          if [ -e "$backup" ]; then
            echo "Did not expect backup for forced overwrite at $backup"
            exit 1
          fi
        done
      '';
    };

    # Rollback Tests for Recursive Stashes

    test-rollback-recursive-stash-added-files = mkActivationTest {
      name = "test-rollback-recursive-stash-added-files";

      # Old generation has files in stash
      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/original.toml".content = "original=true";
        "dotfiles/config-app/added.toml".content = "added=true";
      };

      # New generation removes the added file from tracking
      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        # Simulate first activation with both files
        mkdir -p $HOME/config/app
        ln -sf "$HOME/dotfiles/config-app/original.toml" "$HOME/config/app/original.toml"
        ln -sf "$HOME/dotfiles/config-app/added.toml" "$HOME/config/app/added.toml"
      '';

      postActivation = ''
        # Both files should still exist (rollback keeps new stash files)
        if [ ! -L "config/app/original.toml" ]; then
          echo "Expected original.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/added.toml" ]; then
          echo "Expected added.toml to still be a symlink"
          exit 1
        fi

        # Verify they point to the stash
        if [ "$(readlink -f config/app/original.toml)" != "$(readlink -f dotfiles/config-app/original.toml)" ]; then
          echo "original.toml doesn't point to stash"
          exit 1
        fi

        if [ "$(readlink -f config/app/added.toml)" != "$(readlink -f dotfiles/config-app/added.toml)" ]; then
          echo "added.toml doesn't point to stash"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-stash-removed-files = mkActivationTest {
      name = "test-rollback-recursive-stash-removed-files";

      # Old generation tracked two files
      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/keep.toml".content = "keep=true";
      };

      # New generation still tracks the directory (file was removed from stash)
      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        # Simulate old activation where both files existed
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/config-app/keep.toml" "$HOME/config/app/keep.toml"

        # Create a dummy file that was removed from stash
        echo "removed=true" > "$HOME/dotfiles/config-app/removed.toml"
        ln -sf "$HOME/dotfiles/config-app/removed.toml" "$HOME/config/app/removed.toml"

        # Now remove it from stash to simulate rollback scenario
        rm "$HOME/dotfiles/config-app/removed.toml"
      '';

      postActivation = ''
        # keep.toml should exist
        if [ ! -L "config/app/keep.toml" ]; then
          echo "Expected keep.toml to be a symlink"
          exit 1
        fi

        # removed.toml link should be cleaned up (broken symlink removal)
        if [ -e "config/app/removed.toml" ] || [ -L "config/app/removed.toml" ]; then
          echo "Expected removed.toml to be cleaned up"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-stash-path-change = mkActivationTest {
      name = "test-rollback-recursive-stash-path-change";

      # Old generation uses one stash path
      oldGen = {
        stashes.myStash.path = "dotfiles/old-config";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/old-config/settings.toml".content = "version=1";
        "dotfiles/new-config/settings.toml".content = "version=2";
      };

      # New generation changes stash path
      newGen = {
        stashes.myStash.path = "dotfiles/new-config";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/old-config/settings.toml" "$HOME/config/app/settings.toml"
      '';

      postActivation = ''
        # Should now point to new stash location
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        local resolved=$(readlink -f "config/app/settings.toml")
        local expected=$(readlink -f "dotfiles/new-config/settings.toml")

        if [ "$resolved" != "$expected" ]; then
          echo "Expected settings.toml to point to new-config, but got: $resolved"
          exit 1
        fi

        local content=$(cat "config/app/settings.toml")
        if [ "$content" != "version=2" ]; then
          echo "Expected new content, got: $content"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-to-non-recursive = mkActivationTest {
      name = "test-rollback-recursive-to-non-recursive";

      # Old generation has recursive stash
      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/file1.toml".content = "file1=true";
        "dotfiles/config-app/file2.toml".content = "file2=true";
      };

      # New generation makes it non-recursive (links entire directory)
      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = false;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/config-app/file1.toml" "$HOME/config/app/file1.toml"
        ln -sf "$HOME/dotfiles/config-app/file2.toml" "$HOME/config/app/file2.toml"
      '';

      postActivation = ''
        # The directory itself should now be a symlink
        if [ ! -L "config/app" ]; then
          echo "Expected config/app to be a symlink"
          exit 1
        fi

        local resolved=$(readlink -f "config/app")
        local expected=$(readlink -f "dotfiles/config-app")

        if [ "$resolved" != "$expected" ]; then
          echo "Expected config/app to point to dotfiles/config-app"
          exit 1
        fi

        # Files should be accessible through the directory symlink
        if [ ! -f "config/app/file1.toml" ]; then
          echo "file1.toml not accessible"
          exit 1
        fi

        if [ ! -f "config/app/file2.toml" ]; then
          echo "file2.toml not accessible"
          exit 1
        fi
      '';
    };

    test-rollback-non-recursive-to-recursive = mkActivationTest {
      name = "test-rollback-non-recursive-to-recursive";

      # Old generation has non-recursive (entire directory symlinked)
      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = false;
        };
      };

      homeFiles = {
        "dotfiles/config-app/file1.toml".content = "file1=true";
        "dotfiles/config-app/file2.toml".content = "file2=true";
      };

      # New generation makes it recursive
      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p $HOME/config
        ln -sf "$HOME/dotfiles/config-app" "$HOME/config/app"
      '';

      postActivation = ''
        find $HOME/config
        # The directory should no longer be a symlink
        if [ -L "config/app" ]; then
          echo "Expected config/app to not be a symlink"
          exit 1
        fi

        if [ ! -d "config/app" ]; then
          echo "Expected config/app to be a directory"
          exit 1
        fi

        # Individual files should be symlinks
        if [ ! -L "config/app/file1.toml" ]; then
          echo "Expected file1.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/file2.toml" ]; then
          echo "Expected file2.toml to be a symlink"
          exit 1
        fi

        local resolved1=$(readlink -f "config/app/file1.toml")
        local expected1=$(readlink -f "dotfiles/config-app/file1.toml")

        if [ "$resolved1" != "$expected1" ]; then
          echo "file1.toml doesn't point to stash correctly"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-with-user-modifications = mkActivationTest {
      name = "test-rollback-recursive-with-user-modifications";

      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/tracked.toml".content = "tracked=true";
      };

      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/config-app/tracked.toml" "$HOME/config/app/tracked.toml"

        # User adds their own files in the managed directory
        echo "user-file=true" > "$HOME/config/app/user-file.toml"
        mkdir -p "$HOME/config/app/subdir"
        echo "user-subdir=true" > "$HOME/config/app/subdir/file.toml"
      '';

      postActivation = ''
        # Tracked file should still be a symlink
        if [ ! -L "config/app/tracked.toml" ]; then
          echo "Expected tracked.toml to be a symlink"
          exit 1
        fi

        # User files should be preserved
        if [ ! -f "config/app/user-file.toml" ]; then
          echo "Expected user-file.toml to be preserved"
          exit 1
        fi

        if [ -L "config/app/user-file.toml" ]; then
          echo "User file should not be a symlink"
          exit 1
        fi

        if [ ! -f "config/app/subdir/file.toml" ]; then
          echo "Expected user subdir file to be preserved"
          exit 1
        fi

        local content=$(cat "config/app/user-file.toml")
        if [ "$content" != "user-file=true" ]; then
          echo "User file content was modified"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-stash-removed-completely = mkActivationTest {
      name = "test-rollback-recursive-stash-removed-completely";

      oldGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config-app/settings.toml".content = "settings=true";
      };

      # New generation removes the file entry completely
      newGen = {
        stashes.myStash.path = "dotfiles/config-app";
        files = { };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/config-app/settings.toml" "$HOME/config/app/settings.toml"
      '';

      postActivation = ''
        # Managed files should be cleaned up
        if [ -e "config/app/settings.toml" ] || [ -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be removed"
          exit 1
        fi

        # The directory might be removed if empty, or kept if there were user files
        # We just verify the tracked file is gone
      '';
    };

    test-rollback-recursive-stash-nested-directories = mkActivationTest {
      name = "test-rollback-recursive-stash-nested-directories";

      oldGen = {
        stashes.myStash.path = "dotfiles/config";
        files."config" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/config/app/settings.toml".content = "app-settings=true";
        "dotfiles/config/app/deep/nested.toml".content = "nested=true";
        "dotfiles/config/other/file.toml".content = "other=true";
      };

      newGen = {
        stashes.myStash.path = "dotfiles/config";
        files."config" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app/deep"
        mkdir -p "$HOME/config/other"
        ln -sf "$HOME/dotfiles/config/app/settings.toml" "$HOME/config/app/settings.toml"
        ln -sf "$HOME/dotfiles/config/app/deep/nested.toml" "$HOME/config/app/deep/nested.toml"
        ln -sf "$HOME/dotfiles/config/other/file.toml" "$HOME/config/other/file.toml"

        # Add a new nested file to stash
        mkdir -p "$HOME/dotfiles/config/app/another"
        echo "another=true" > "$HOME/dotfiles/config/app/another/new.toml"
      '';

      postActivation = ''
        # All original files should still be linked
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected app/settings.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/deep/nested.toml" ]; then
          echo "Expected app/deep/nested.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/other/file.toml" ]; then
          echo "Expected other/file.toml to be a symlink"
          exit 1
        fi

        # New file should also be linked
        if [ ! -L "config/app/another/new.toml" ]; then
          echo "Expected app/another/new.toml to be a symlink"
          exit 1
        fi

        local content=$(cat "config/app/another/new.toml")
        if [ "$content" != "another=true" ]; then
          echo "New file has wrong content: $content"
          exit 1
        fi
      '';
    };

    test-rollback-recursive-stash-subdirectory = mkActivationTest {
      name = "test-rollback-recursive-stash-subdirectory";

      oldGen = {
        stashes.myStash.path = "dotfiles/all-config";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-specific";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/all-config/app-specific/settings.toml".content = "version=1";
        "dotfiles/all-config/app-specific/theme.toml".content = "theme=dark";
        "dotfiles/all-config/other/ignore.toml".content = "ignore=true";
      };

      newGen = {
        stashes.myStash.path = "dotfiles/all-config";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-specific";
          };
          recursive = true;
        };
      };

      preActivation = ''
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/all-config/app-specific/settings.toml" "$HOME/config/app/settings.toml"
        ln -sf "$HOME/dotfiles/all-config/app-specific/theme.toml" "$HOME/config/app/theme.toml"
      '';

      postActivation = ''
        # Files from the subdirectory should be linked
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/theme.toml" ]; then
          echo "Expected theme.toml to be a symlink"
          exit 1
        fi

        # Files outside the subdirectory should not be linked
        if [ -e "config/app/ignore.toml" ]; then
          echo "Unexpected file from outside subdirectory"
          exit 1
        fi

        local resolved=$(readlink -f "config/app/settings.toml")
        local expected=$(readlink -f "dotfiles/all-config/app-specific/settings.toml")

        if [ "$resolved" != "$expected" ]; then
          echo "settings.toml doesn't point to correct location"
          exit 1
        fi
      '';
    };
  };
}
