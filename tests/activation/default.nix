args:
let
  inherit (import ./helpers.nix args)
    mkActivationTest
    ;
in
{
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
        "dotfiles/config-app/removed.toml".content = "removed=true";
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
        ln -sf "$HOME/dotfiles/config-app/removed.toml" "$HOME/config/app/removed.toml"
      '';

      postManifestGeneration = ''
        # After manifest is generated, remove the file from stash to simulate rollback scenario
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

    # Priority 1: Critical Path Coverage Tests

    test-root-cleanup-file-collision = mkActivationTest {
      name = "test-root-cleanup-file-collision";

      # Old generation tracked a single file (non-recursive)
      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = false;
        };
      };

      homeFiles = {
        "dotfiles/app-config".content = "original-symlink-target";
      };

      # New generation removes management
      newGen = {
        stashes.myStash.path = "dotfiles";
        files = { };
      };

      preActivation = ''
        # Simulate first activation with directory symlink
        mkdir -p "$HOME/config"
        ln -sf "$HOME/dotfiles/app-config" "$HOME/config/app"

        # User replaces the symlink with a regular file
        rm "$HOME/config/app"
        echo "user created file" > "$HOME/config/app"
      '';

      postActivation = ''
        # File should be preserved (warning issued, not removed)
        if [ ! -f "config/app" ]; then
          echo "Expected user file to be preserved"
          exit 1
        fi

        if [ -L "config/app" ]; then
          echo "File should not be a symlink"
          exit 1
        fi

        content=$(cat "config/app")
        if [ "$content" != "user created file" ]; then
          echo "User file content was modified"
          exit 1
        fi
      '';
    };

    test-root-cleanup-dangling-symlink = mkActivationTest {
      name = "test-root-cleanup-dangling-symlink";

      # Old generation had non-recursive link to entire directory
      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = false;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
      };

      # New generation removes management completely
      newGen = {
        stashes.myStash.path = "dotfiles";
        files = { };
      };

      preActivation = ''
        # Create the non-recursive symlink
        mkdir -p "$HOME/config"
        ln -sf "$HOME/dotfiles/app-config" "$HOME/config/app"

        # Remove the source directory to make it dangle
        rm -rf "$HOME/dotfiles/app-config"
      '';

      postActivation = ''
        # Dangling symlink should be cleaned up
        if [ -e "config/app" ] || [ -L "config/app" ]; then
          echo "Expected dangling symlink to be removed"
          exit 1
        fi
      '';
    };

    test-new-root-symlink-collision = mkActivationTest {
      name = "test-new-root-symlink-collision";

      # No old generation
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
        "other-location/settings.toml".content = "other=1";
      };

      preActivation = ''
        # User already has a symlink at the root location
        mkdir -p "$HOME/config"
        ln -sf "$HOME/other-location" "$HOME/config/app"
      '';

      expectFailure = true;
      expectedExitCode = 1;
      expectedErrorRegex = "fatal_collision|incompatible with a recursive tree";
    };

    test-new-root-file-collision = mkActivationTest {
      name = "test-new-root-file-collision";

      # No old generation
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
      };

      preActivation = ''
        # User has a regular file where recursive root should be
        mkdir -p "$HOME/config"
        echo "user file content" > "$HOME/config/app"
      '';

      expectFailure = true;
      expectedExitCode = 1;
      expectedErrorRegex = "type_mismatch|not a directory";
    };

    test-leaf-cleanup-file-replaced-symlink = mkActivationTest {
      name = "test-leaf-cleanup-file-replaced-symlink";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/app-config/keep.toml".content = "keep=1";
        "dotfiles/app-config/replaced.toml".content = "original=1";
      };

      # New generation still manages the directory
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      preActivation = ''
        # Set up initial symlinks
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/app-config/keep.toml" "$HOME/config/app/keep.toml"
        ln -sf "$HOME/dotfiles/app-config/replaced.toml" "$HOME/config/app/replaced.toml"

        # User replaces one symlink with a regular file
        rm "$HOME/config/app/replaced.toml"
        echo "user-modified=1" > "$HOME/config/app/replaced.toml"
      '';

      postActivation = ''
        # keep.toml should still be a symlink
        if [ ! -L "config/app/keep.toml" ]; then
          echo "Expected keep.toml to remain a symlink"
          exit 1
        fi

        # replaced.toml should be restored to a symlink (with backup)
        if [ ! -L "config/app/replaced.toml" ]; then
          echo "Expected replaced.toml to be restored as symlink"
          exit 1
        fi

        # Backup should exist
        if [ ! -f "config/app/replaced.toml.stash.bak" ]; then
          echo "Expected backup file to exist"
          exit 1
        fi

        # Backup should have user content
        content=$(cat "config/app/replaced.toml.stash.bak")
        if [ "$content" != "user-modified=1" ]; then
          echo "Backup doesn't have user content"
          exit 1
        fi
      '';
    };

    test-new-leaf-forced-over-symlink = mkActivationTest {
      name = "test-new-leaf-forced-over-symlink";

      # No old generation
      newGen = {
        files."config/app/settings.toml" = {
          text = "managed-content";
          forced = true;
        };
      };

      homeFiles = {
        "other-location/old-settings.toml".content = "old-unmanaged=1";
      };

      preActivation = ''
        # User has an existing unmanaged symlink
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/other-location/old-settings.toml" "$HOME/config/app/settings.toml"
      '';

      postActivation = ''
        # Should be replaced with managed symlink
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        # No backup should exist (forced=true)
        if [ -e "config/app/settings.toml.stash.bak" ]; then
          echo "Did not expect backup with forced=true"
          exit 1
        fi

        # Should point to store path, not old location
        resolved=$(readlink "config/app/settings.toml")
        if [[ "$resolved" == *"other-location"* ]]; then
          echo "Symlink still points to old location"
          exit 1
        fi
      '';
    };

    test-managed-leaf-recreate-missing = mkActivationTest {
      name = "test-managed-leaf-recreate-missing";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
        "dotfiles/app-config/deleted.toml".content = "deleted=1";
      };

      # Same generation (simulating user deletion between activations)
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      preActivation = ''
        # Set up initial state
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/app-config/settings.toml" "$HOME/config/app/settings.toml"
        ln -sf "$HOME/dotfiles/app-config/deleted.toml" "$HOME/config/app/deleted.toml"

        # User accidentally deletes one symlink
        rm "$HOME/config/app/deleted.toml"
      '';

      postActivation = ''
        # Both should be symlinks (deleted one recreated)
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/deleted.toml" ]; then
          echo "Expected deleted.toml to be recreated as symlink"
          exit 1
        fi

        # Verify recreated link points to correct source
        resolved=$(readlink -f "config/app/deleted.toml")
        expected=$(readlink -f "dotfiles/app-config/deleted.toml")
        if [ "$resolved" != "$expected" ]; then
          echo "Recreated symlink points to wrong location"
          exit 1
        fi
      '';
    };

    test-managed-leaf-user-modified-symlink-not-forced = mkActivationTest {
      name = "test-managed-leaf-user-modified-symlink-not-forced";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app/settings.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config/settings.toml";
          };
          recursive = false;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
        "other-location/different.toml".content = "different=1";
      };

      # Same generation
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app/settings.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config/settings.toml";
          };
          recursive = false;
        };
      };

      preActivation = ''
        # Set up initial managed symlink
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/app-config/settings.toml" "$HOME/config/app/settings.toml"

        # User modifies the symlink to point elsewhere
        rm "$HOME/config/app/settings.toml"
        ln -sf "$HOME/other-location/different.toml" "$HOME/config/app/settings.toml"
      '';

      expectFailure = true;
      expectedExitCode = 1;
      expectedErrorRegex = "fatal_collision|different symlink";
    };

    test-managed-leaf-user-modified-symlink-forced = mkActivationTest {
      name = "test-managed-leaf-user-modified-symlink-forced";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app/settings.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config/settings.toml";
          };
          recursive = false;
          forced = true;
        };
      };

      homeFiles = {
        "dotfiles/app-config/settings.toml".content = "settings=1";
        "other-location/different.toml".content = "different=1";
      };

      # Same generation with forced
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app/settings.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config/settings.toml";
          };
          recursive = false;
          forced = true;
        };
      };

      preActivation = ''
        # Set up initial managed symlink
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/app-config/settings.toml" "$HOME/config/app/settings.toml"

        # User modifies the symlink to point elsewhere
        rm "$HOME/config/app/settings.toml"
        ln -sf "$HOME/other-location/different.toml" "$HOME/config/app/settings.toml"
      '';

      postActivation = ''
        # Should be replaced with correct symlink (forced=true)
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        # Should point back to managed source
        resolved=$(readlink -f "config/app/settings.toml")
        expected=$(readlink -f "dotfiles/app-config/settings.toml")
        if [ "$resolved" != "$expected" ]; then
          echo "Symlink doesn't point to managed source"
          echo "Expected: $expected"
          echo "Got: $resolved"
          exit 1
        fi

        # No backup (forced overwrites)
        if [ -e "config/app/settings.toml.stash.bak" ]; then
          echo "Did not expect backup with forced=true"
          exit 1
        fi
      '';
    };

    # =========================================================================
    # Phase 2: Real-World Scenario Tests
    # =========================================================================

    # Test 1: Static files comprehensive testing
    # Real-world: User has Nix-templated configs that come from the Nix store
    # Tests static file creation, rollback, and transitions
    test-static-files-comprehensive = mkActivationTest {
      name = "test-static-files-comprehensive";

      # Previous generation had static files
      oldGen = {
        files."config/app/hardware.toml" = {
          text = ''
            gpu = "nvidia"
            driver = "proprietary"
          '';
        };
        files."config/app/network.toml" = {
          text = ''
            interface = "eth0"
          '';
        };
      };

      # New generation: hardware.toml updated, network.toml removed, theme.toml added
      newGen = {
        files."config/app/hardware.toml" = {
          text = ''
            gpu = "amd"
            driver = "open-source"
          '';
        };
        files."config/app/theme.toml" = {
          text = ''
            colorscheme = "dark"
          '';
        };
      };

      preActivation = ''
        # Simulate old generation's symlinks
        mkdir -p "$HOME/config/app"

        # We need to get the old generation path for setting up symlinks
        oldGenPath="$gcRootsDir/current-home"
        if [ -L "$oldGenPath" ]; then
          realOldGen=$(readlink -f "$oldGenPath")
          ln -sf "$realOldGen/static-files/config/app/hardware.toml" "$HOME/config/app/hardware.toml"
          ln -sf "$realOldGen/static-files/config/app/network.toml" "$HOME/config/app/network.toml"
        fi
      '';

      postActivation = ''
        # hardware.toml should be updated (new symlink target)
        if [ ! -L "config/app/hardware.toml" ]; then
          echo "Expected hardware.toml to be a symlink"
          exit 1
        fi

        # Verify content is from new generation
        if ! grep -q "amd" "config/app/hardware.toml"; then
          echo "hardware.toml should contain new content (amd)"
          cat "config/app/hardware.toml"
          exit 1
        fi

        # network.toml should be removed (no longer in new gen)
        if [ -e "config/app/network.toml" ]; then
          echo "network.toml should have been removed"
          exit 1
        fi

        # theme.toml should be created (new in this gen)
        if [ ! -L "config/app/theme.toml" ]; then
          echo "Expected theme.toml to be a symlink"
          exit 1
        fi

        if ! grep -q "colorscheme" "config/app/theme.toml"; then
          echo "theme.toml should contain expected content"
          exit 1
        fi
      '';
    };

    # Test 2: Mixed recursive and non-recursive entries in same tree
    # Real-world: `.config/app` is recursive (user edits), `.config/other-app` is a single symlink
    test-mixed-recursive-non-recursive = mkActivationTest {
      name = "test-mixed-recursive-non-recursive";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        # Recursive entry
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app";
          };
          recursive = true;
        };
        # Non-recursive entry in same parent
        files."config/other-app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/other-app";
          };
          recursive = false;
        };
      };

      homeFiles = {
        # Stash contents for recursive
        "dotfiles/app/settings.toml".content = "setting = 1";
        "dotfiles/app/keybinds.toml".content = "key = ctrl";
        # Stash contents for non-recursive (directory)
        "dotfiles/other-app/config.toml".content = "other = true";
      };

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app";
          };
          recursive = true;
        };
        files."config/other-app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/other-app";
          };
          recursive = false;
        };
      };

      preActivation = ''
        # Set up existing state: recursive has individual file symlinks
        mkdir -p "$HOME/config/app"
        ln -sf "$HOME/dotfiles/app/settings.toml" "$HOME/config/app/settings.toml"
        ln -sf "$HOME/dotfiles/app/keybinds.toml" "$HOME/config/app/keybinds.toml"

        # Non-recursive is a single symlink to directory
        ln -sf "$HOME/dotfiles/other-app" "$HOME/config/other-app"

        echo "=== Before activation ==="
        ls -la "$HOME/config/"
        ls -la "$HOME/config/app/"
      '';

      postActivation = ''
        echo "=== After activation ==="
        ls -la config/
        ls -la config/app/

        # Recursive: individual files should be symlinks
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected config/app/settings.toml to be a symlink"
          exit 1
        fi

        if [ ! -L "config/app/keybinds.toml" ]; then
          echo "Expected config/app/keybinds.toml to be a symlink"
          exit 1
        fi

        # config/app should be a directory, not a symlink
        if [ -L "config/app" ]; then
          echo "config/app should be a directory, not a symlink (recursive mode)"
          exit 1
        fi

        # Non-recursive: should be a single symlink to the directory
        if [ ! -L "config/other-app" ]; then
          echo "Expected config/other-app to be a symlink (non-recursive mode)"
          exit 1
        fi

        # The non-recursive symlink should point to stash directory
        resolved=$(readlink -f "config/other-app")
        expected=$(readlink -f "dotfiles/other-app")
        if [ "$resolved" != "$expected" ]; then
          echo "Non-recursive symlink points to wrong location"
          echo "Expected: $expected"
          echo "Got: $resolved"
          exit 1
        fi
      '';
    };

    # Test 3: Empty recursive directory
    # Real-world: User creates stash structure but hasn't added files yet
    test-empty-recursive-directory = mkActivationTest {
      name = "test-empty-recursive-directory";

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app";
          };
          recursive = true;
        };
      };

      homeFiles = {
        # Empty directory - we'll create it in preActivation
      };

      preActivation = ''
        # Create empty stash directory
        mkdir -p "$HOME/dotfiles/app"
        echo "Created empty stash directory"
        ls -la "$HOME/dotfiles/"
      '';

      postActivation = ''
        # With empty stash, no symlinks should be created
        # But the target directory might be created (depends on implementation)

        # The key thing is activation should succeed without errors
        echo "Activation succeeded with empty recursive directory"

        # If config/app exists, it should be a directory (not symlink)
        if [ -e "config/app" ]; then
          if [ -L "config/app" ]; then
            echo "config/app should not be a symlink for recursive entry"
            exit 1
          fi
        fi

        # No files should be inside
        if [ -d "config/app" ]; then
          count=$(find "config/app" -type l 2>/dev/null | wc -l)
          if [ "$count" -gt 0 ]; then
            echo "Expected no symlinks in empty recursive dir, found $count"
            find "config/app" -type l
            exit 1
          fi
        fi
      '';
    };

    # Test 4: Deep nesting (7+ levels)
    # Real-world: Some apps use deep config structures (e.g., .config/JetBrains/IntelliJ/options/...)
    test-deep-nesting = mkActivationTest {
      name = "test-deep-nesting";

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/level1" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/deeply-nested";
          };
          recursive = true;
        };
      };

      homeFiles = {
        # 7 levels deep: config/level1/level2/level3/level4/level5/level6/level7/file.txt
        "dotfiles/deeply-nested/level2/level3/level4/level5/level6/level7/deep-file.toml".content =
          "deep = true";
        # Also a file at intermediate level
        "dotfiles/deeply-nested/level2/mid-file.toml".content = "mid = true";
        # And a file at the root of the recursive tree
        "dotfiles/deeply-nested/root-file.toml".content = "root = true";
      };

      postActivation = ''
        echo "=== Checking deep nesting ==="

        # Check root level file
        if [ ! -L "config/level1/root-file.toml" ]; then
          echo "Expected root-file.toml symlink"
          exit 1
        fi

        # Check mid-level file
        if [ ! -L "config/level1/level2/mid-file.toml" ]; then
          echo "Expected mid-file.toml symlink at level2"
          exit 1
        fi

        # Check deepest file (7 levels)
        deepPath="config/level1/level2/level3/level4/level5/level6/level7/deep-file.toml"
        if [ ! -L "$deepPath" ]; then
          echo "Expected deep-file.toml symlink at level 7"
          echo "Checking what exists:"
          ls -la "config/level1/" || true
          ls -la "config/level1/level2/" || true
          ls -la "config/level1/level2/level3/" || true
          exit 1
        fi

        # Verify content is accessible through symlink
        if ! grep -q "deep = true" "$deepPath"; then
          echo "Deep file content not accessible"
          exit 1
        fi

        # All intermediate directories should be real directories, not symlinks
        for dir in "config/level1" "config/level1/level2" "config/level1/level2/level3" \
                   "config/level1/level2/level3/level4" "config/level1/level2/level3/level4/level5" \
                   "config/level1/level2/level3/level4/level5/level6" \
                   "config/level1/level2/level3/level4/level5/level6/level7"; do
          if [ -L "$dir" ]; then
            echo "$dir should be a directory, not a symlink"
            exit 1
          fi
          if [ ! -d "$dir" ]; then
            echo "$dir should exist as a directory"
            exit 1
          fi
        done

        echo "Deep nesting test passed!"
      '';
    };

    # Test 5: Symlinks inside stash source
    # Real-world: User has symlinks in their dotfiles repo (e.g., shared configs)
    test-symlinks-in-stash = mkActivationTest {
      name = "test-symlinks-in-stash";

      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app-config";
          };
          recursive = true;
        };
      };

      homeFiles = {
        # Regular file in stash
        "dotfiles/app-config/settings.toml".content = "settings = 1";
        # Shared config that will be symlinked to
        "dotfiles/shared/common.toml".content = "shared = true";
      };

      preActivation = ''
        # Create a symlink inside the stash pointing to shared config
        ln -sf "$HOME/dotfiles/shared/common.toml" "$HOME/dotfiles/app-config/common.toml"

        echo "=== Stash structure ==="
        ls -la "$HOME/dotfiles/app-config/"
      '';

      postActivation = ''
        echo "=== After activation ==="
        ls -la "config/app/"

        # Regular file should be a symlink
        if [ ! -L "config/app/settings.toml" ]; then
          echo "Expected settings.toml to be a symlink"
          exit 1
        fi

        # The symlink-in-stash should also result in a symlink in target
        # (symlink to a symlink, or symlink to final target - either is acceptable)
        if [ ! -L "config/app/common.toml" ]; then
          echo "Expected common.toml to be a symlink"
          exit 1
        fi

        # Most importantly, the content should be accessible
        if ! grep -q "shared = true" "config/app/common.toml"; then
          echo "Could not read content through symlink chain"
          echo "Content:"
          cat "config/app/common.toml" || echo "(failed to read)"
          exit 1
        fi

        # Check that settings.toml still works
        if ! grep -q "settings = 1" "config/app/settings.toml"; then
          echo "Could not read settings.toml content"
          exit 1
        fi
      '';
    };

    # Test 6: Static file with recursive directory
    # Real-world: Entire config directory comes from Nix store (e.g., generated from Nix expressions)
    # Note: This test uses ./module directly, which works because we fixed the bug where
    # stash.json was storing local paths instead of store paths for static files.
    test-static-recursive-directory = mkActivationTest {
      name = "test-static-recursive-directory";

      newGen = {
        files."config/generated" = {
          source = ../module-eval; # This directory contains default.nix and tests.nix
          recursive = true;
        };
      };

      postActivation = ''
        echo "=== Checking static recursive directory ==="
        ls -la "config/generated/"

        # Should have files from the source directory (tests/module-eval contains .nix files)
        if [ ! -L "config/generated/default.nix" ]; then
          echo "Expected default.nix symlink in recursive static dir"
          ls -la "config/generated/"
          exit 1
        fi

        if [ ! -L "config/generated/tests.nix" ]; then
          echo "Expected tests.nix symlink in recursive static dir"
          exit 1
        fi

        # Parent should be a directory, not symlink (recursive mode)
        if [ -L "config/generated" ]; then
          echo "config/generated should be a directory, not symlink (recursive)"
          exit 1
        fi

        # Verify content is accessible (check for Nix syntax)
        if ! grep -q "config" "config/generated/tests.nix"; then
          echo "Could not read tests.nix content"
          exit 1
        fi
      '';
    };

    # Test 7: Mixed static and stash files in same directory tree
    # Real-world: Hardware config (static from Nix) + theme config (dynamic from stash)
    test-mixed-static-and-stash = mkActivationTest {
      name = "test-mixed-static-and-stash";

      newGen = {
        stashes.myStash.path = "dotfiles";

        # Static file - generated from Nix, immutable
        files."config/app/hardware.toml" = {
          text = ''
            gpu = "nvidia"
            memory = "16GB"
          '';
        };

        # Stash file - user-editable
        files."config/app/theme.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app/theme.toml";
          };
        };

        # Another static file
        files."config/app/defaults.toml" = {
          text = ''
            default_option = true
          '';
        };
      };

      homeFiles = {
        "dotfiles/app/theme.toml".content = "colorscheme = dark";
      };

      postActivation = ''
        echo "=== Mixed static/stash test ==="
        ls -la "config/app/"

        # Static files should be symlinks to Nix store
        if [ ! -L "config/app/hardware.toml" ]; then
          echo "Expected hardware.toml to be a symlink"
          exit 1
        fi

        # Verify static content
        if ! grep -q "nvidia" "config/app/hardware.toml"; then
          echo "hardware.toml should contain Nix-generated content"
          exit 1
        fi

        # Stash file should be symlink to stash
        if [ ! -L "config/app/theme.toml" ]; then
          echo "Expected theme.toml to be a symlink"
          exit 1
        fi

        # Verify stash content
        if ! grep -q "colorscheme" "config/app/theme.toml"; then
          echo "theme.toml should contain stash content"
          exit 1
        fi

        # Verify the stash symlink points to dotfiles, not Nix store
        themeTarget=$(readlink "config/app/theme.toml")
        if echo "$themeTarget" | grep -q "/nix/store"; then
          echo "theme.toml should NOT point to Nix store (it's a stash file)"
          echo "Points to: $themeTarget"
          exit 1
        fi

        # Static file should point to Nix store
        hardwareTarget=$(readlink "config/app/hardware.toml")
        if ! echo "$hardwareTarget" | grep -q "/nix/store"; then
          echo "hardware.toml SHOULD point to Nix store (it's a static file)"
          echo "Points to: $hardwareTarget"
          exit 1
        fi

        # defaults.toml should also work
        if ! grep -q "default_option" "config/app/defaults.toml"; then
          echo "defaults.toml should contain expected content"
          exit 1
        fi
      '';
    };

    # Test 8: Rollback with mixed static/stash - static file removed, stash file added
    # Real-world: Generation transition where config structure changes
    test-rollback-mixed-static-stash = mkActivationTest {
      name = "test-rollback-mixed-static-stash";

      oldGen = {
        stashes.myStash.path = "dotfiles";
        # Old gen has static hardware config
        files."config/app/hardware.toml" = {
          text = "gpu = old";
        };
        # And a stash theme
        files."config/app/theme.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app/theme.toml";
          };
        };
      };

      homeFiles = {
        "dotfiles/app/theme.toml".content = "theme = dark";
        "dotfiles/app/keybinds.toml".content = "key = ctrl+c";
      };

      # New gen: hardware removed, keybinds added (stash)
      newGen = {
        stashes.myStash.path = "dotfiles";
        files."config/app/theme.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app/theme.toml";
          };
        };
        files."config/app/keybinds.toml" = {
          source = {
            static = false;
            stash = "myStash";
            path = "/app/keybinds.toml";
          };
        };
      };

      preActivation = ''
        # Set up old generation state
        mkdir -p "$HOME/config/app"

        oldGenPath="$gcRootsDir/current-home"
        if [ -L "$oldGenPath" ]; then
          realOldGen=$(readlink -f "$oldGenPath")
          ln -sf "$realOldGen/static-files/config/app/hardware.toml" "$HOME/config/app/hardware.toml"
        fi
        ln -sf "$HOME/dotfiles/app/theme.toml" "$HOME/config/app/theme.toml"

        echo "=== Before transition ==="
        ls -la "$HOME/config/app/"
      '';

      postActivation = ''
        echo "=== After transition ==="
        ls -la "config/app/"

        # hardware.toml should be removed (not in new gen)
        if [ -e "config/app/hardware.toml" ]; then
          echo "hardware.toml should have been removed"
          exit 1
        fi

        # theme.toml should still exist
        if [ ! -L "config/app/theme.toml" ]; then
          echo "theme.toml should still be a symlink"
          exit 1
        fi

        # keybinds.toml should be added
        if [ ! -L "config/app/keybinds.toml" ]; then
          echo "keybinds.toml should be created"
          exit 1
        fi

        if ! grep -q "key = ctrl" "config/app/keybinds.toml"; then
          echo "keybinds.toml should have correct content"
          exit 1
        fi
      '';
    };
  };
}
