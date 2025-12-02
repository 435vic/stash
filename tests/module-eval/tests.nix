{
  validStashRefs-fail = {
    config = {
      homeDirectory = "/home/test";
      files."a" = {
        source = {
          static = false;
          stash = "non-existent-stash";
          path = "/foo";
        };
      };
    };
    "test should fail when stash does not exist" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion) cfg.assertions);
      expected = [
        {
          type = "stash.undefined";
          stash = "non-existent-stash";
          target = "a";
        }
      ];
    };
  };

  validStashRefs-pass = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/my-stash";
      files."a" = {
        source = {
          static = false;
          stash = "my-stash";
          path = "/foo";
        };
      };
    };
    "test should pass when stash exists" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  duplicateTargets-fail = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "a" = {
          source = "/dev/null";
          target = "path/to/file";
        };
        "b" = {
          source = "/dev/null";
          target = "path/to/file";
        };
      };
    };
    "test should fail on duplicate targets" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion) cfg.assertions);
      expected = [
        {
          type = "target.duplicate";
          target = "path/to/file";
        }
      ];
    };
  };

  duplicateTargets-pass = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "a" = {
          source = "/dev/null";
          target = "path/to/file-a";
        };
        "b" = {
          source = "/dev/null";
          target = "path/to/file-b";
        };
      };
    };
    "test should pass with unique targets" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  recursiveFile-fail = {
    config = {
      homeDirectory = "/home/test";
      files."a" = {
        recursive = true;
        source = "/dev/null"; # a file, not a directory
      };
    };
    "test should fail when recursive is true for a file" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
            "source"
          ]
        ) (builtins.filter (a: !a.assertion) cfg.assertions);
      expected = [
        {
          type = "entry.invalid-recursive";
          entry = "a";
        }
      ];
    };
  };

  recursiveFile-pass = {
    config = {
      homeDirectory = "/home/test";
      files."a" = {
        recursive = true;
        source = ./.; # a directory
      };
    };
    "test should pass when recursive is true for a directory" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  targetPathSafety-fail = {
    config = {
      homeDirectory = "/home/test";
      files."a" = {
        source = "/dev/null";
        target = "../outside/home";
      };
    };
    "test should fail when target contains .." = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion) cfg.assertions);
      expected = [
        {
          type = "target.forbidden";
          entry = "a";
          target = "../outside/home";
        }
      ];
    };
  };

  targetPathSafety-pass = {
    config = {
      homeDirectory = "/home/test";
      files."a" = {
        source = "/dev/null";
        target = "inside/home";
      };
    };
    "test should pass when target does not contain .." = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  stashSourcePathSafety-fail = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/my-stash";
      files."a" = {
        source = {
          static = false;
          stash = "my-stash";
          path = "../some-other-path";
        };
      };
    };
    "test should fail when stash source path contains .." = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
            "source"
          ]
        ) (builtins.filter (a: !a.assertion) cfg.assertions);
      expected = [
        {
          type = "source.forbidden";
          entry = "a";
        }
      ];
    };
  };

  stashSourcePathSafety-pass = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/my-stash";
      files."a" = {
        source = {
          static = false;
          stash = "my-stash";
          path = "/some/path";
        };
      };
    };
    "test should pass when stash source path does not contain .." = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  # New tests for expected behavior
  target-override = {
    config = {
      homeDirectory = "/home/test";
      files."hyprland" = {
        source = "/dev/null";
        target = ".config/hypr";
      };
    };
    "test should use specified target instead of entry name" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  target-default = {
    config = {
      homeDirectory = "/home/test";
      files."hyprland" = {
        source = "/dev/null";
      };
    };
    "test should use entry name as target by default" = {
      expr = cfg: builtins.hasAttr "hyprland" cfg.files && cfg.files.hyprland.target == "hyprland";
      expected = true;
    };
  };

  # Source coercion tests
  sourceCoercion-string-to-static = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = "/dev/null";
    };
    "test should coerce string source to static source definition" = {
      expr = cfg: cfg.files.my-file.source.static && cfg.files.my-file.source.path == "/dev/null";
      expected = true;
    };
  };

  sourceCoercion-path-to-static = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = ./.;
    };
    "test should coerce path source to static source definition" = {
      expr = cfg: cfg.files.my-file.source.static;
      expected = true;
    };
  };

  # Text option tests
  textSource-creates-static-source = {
    config = {
      homeDirectory = "/home/test";
      files."my-config".text = "some config content";
    };
    "test should create static source from text" = {
      expr = cfg: cfg.files.my-config.source.static;
      expected = true;
    };
  };

  textSource-path-is-derivation = {
    config = {
      homeDirectory = "/home/test";
      files."my-config".text = "content";
    };
    "test should create derivation path for text" = {
      expr = cfg: builtins.isString (toString cfg.files.my-config.source.path);
      expected = true;
    };
  };

  # Force option tests
  forceOption-default-false = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = "/dev/null";
    };
    "test should default force to false" = {
      expr = cfg: cfg.files.my-file.forced;
      expected = false;
    };
  };

  forceOption-can-be-set-true = {
    config = {
      homeDirectory = "/home/test";
      files."my-file" = {
        source = "/dev/null";
        forced = true;
      };
    };
    "test should allow setting force to true" = {
      expr = cfg: cfg.files.my-file.forced;
      expected = true;
    };
  };

  # Recursive option tests
  recursiveOption-default-false = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = "/dev/null";
    };
    "test should default recursive to false" = {
      expr = cfg: cfg.files.my-file.recursive;
      expected = false;
    };
  };

  recursiveOption-can-be-set-true = {
    config = {
      homeDirectory = "/home/test";
      files."my-dir" = {
        source = ./.;
        recursive = true;
      };
    };
    "test should allow setting recursive to true for directories" = {
      expr = cfg: cfg.files.my-dir.recursive;
      expected = true;
    };
  };

  # Stash path resolution tests
  stashPath-relative-resolution = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
    };
    "test should resolve relative stash path against homeDirectory" = {
      expr = cfg: cfg.stashes.my-stash.path;
      expected = "/home/test/dotfiles";
    };
  };

  stashPath-absolute-preserved = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/opt/configs";
    };
    "test should preserve absolute stash paths" = {
      expr = cfg: cfg.stashes.my-stash.path;
      expected = "/opt/configs";
    };
  };

  stashPath-nested-relative = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = ".config/stash";
    };
    "test should resolve nested relative stash path" = {
      expr = cfg: cfg.stashes.my-stash.path;
      expected = "/home/test/.config/stash";
    };
  };

  # Multiple stashes tests
  multipleStashes-different-files = {
    config = {
      homeDirectory = "/home/test";
      stashes = {
        "stash-a".path = "/home/test/stash-a";
        "stash-b".path = "/home/test/stash-b";
      };
      files = {
        "file-a".source = {
          static = false;
          stash = "stash-a";
          path = "/config";
        };
        "file-b".source = {
          static = false;
          stash = "stash-b";
          path = "/config";
        };
      };
    };
    "test should allow multiple stashes with different files" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  multipleStashes-same-stash = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/stash";
      files = {
        "file-a".source = {
          static = false;
          stash = "my-stash";
          path = "/config-a";
        };
        "file-b".source = {
          static = false;
          stash = "my-stash";
          path = "/config-b";
        };
      };
    };
    "test should allow multiple files from same stash" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  # Derivation generation tests
  staticFileDerivation-created-when-static-files = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = "/dev/null";
    };
    "test should create staticFileDerivation when static files exist" = {
      expr = cfg: cfg.staticFileDerivation != null;
      expected = true;
    };
  };

  staticFileDerivation-null-when-only-stash-files = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/stash";
      files."my-file".source = {
        static = false;
        stash = "my-stash";
        path = "/config";
      };
    };
    "test should not create staticFileDerivation for stash-only config" = {
      expr = cfg: cfg.staticFileDerivation == null;
      expected = true;
    };
  };

  stashStateDerivation-always-created = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".text = "content";
    };
    "test should always create stashStateDerivation" = {
      expr = cfg: cfg.stashStateDerivation != null;
      expected = true;
    };
  };

  generationPackage-always-created = {
    config = {
      homeDirectory = "/home/test";
      files."my-file".source = "/dev/null";
    };
    "test should always create generationPackage" = {
      expr = cfg: cfg.generationPackage != null;
      expected = true;
    };
  };

  # Mixed static and stash files
  mixedFiles-static-and-stash = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/stash";
      files = {
        "static-file".text = "static content";
        "stash-file".source = {
          static = false;
          stash = "my-stash";
          path = "/config";
        };
      };
    };
    "test should handle mix of static and stash files" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  mixedFiles-both-derivations-created = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/stash";
      files = {
        "static-file".text = "static content";
        "stash-file".source = {
          static = false;
          stash = "my-stash";
          path = "/config";
        };
      };
    };
    "test should create both derivations for mixed files" = {
      expr = cfg: cfg.staticFileDerivation != null && cfg.stashStateDerivation != null;
      expected = true;
    };
  };

  # Edge cases
  emptyFiles-no-errors = {
    config = {
      homeDirectory = "/home/test";
      files = { };
    };
    "test should handle empty files config without errors" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  emptyFiles-no-static-derivation = {
    config = {
      homeDirectory = "/home/test";
      files = { };
    };
    "test should not create staticFileDerivation for empty files" = {
      expr = cfg: cfg.staticFileDerivation == null;
      expected = true;
    };
  };

  emptyStashes-no-errors = {
    config = {
      homeDirectory = "/home/test";
      stashes = { };
      files."my-file".source = "/dev/null";
    };
    "test should handle empty stashes config" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  deeplyNestedTarget-allowed = {
    config = {
      homeDirectory = "/home/test";
      files."deep" = {
        source = "/dev/null";
        target = "a/b/c/d/e/f/file.txt";
      };
    };
    "test should allow deeply nested target paths" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  # Stash name as attribute key
  stashName-set-from-attrname = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/some/path";
    };
    "test should set stash name from attribute name" = {
      expr = cfg: cfg.stashes.my-stash.name;
      expected = "my-stash";
    };
  };

  # Source structure for stash files
  stashSource-has-correct-structure = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/home/test/stash";
      files."my-file".source = {
        static = false;
        stash = "my-stash";
        path = "/config";
      };
    };
    "test should have correct source structure for stash files" = {
      expr =
        cfg:
        let
          f = cfg.files.my-file.source;
        in
        !f.static && f.stash == "my-stash" && f.path == "/config";
      expected = true;
    };
  };

  # Multiple files with same source
  multipleFiles-same-static-source = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "file-a" = {
          source = "/dev/null";
          target = "target-a";
        };
        "file-b" = {
          source = "/dev/null";
          target = "target-b";
        };
      };
    };
    "test should allow multiple files from same static source" = {
      expr = cfg: builtins.filter (a: !a.assertion) cfg.assertions;
      expected = [ ];
    };
  };

  # Target inside stash tests
  targetInsideStash-fail-exact-match = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
      files."bad-file" = {
        source = "/dev/null";
        target = "dotfiles";
      };
    };
    "test should fail when target equals stash path" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion && a.type == "target.inside-stash") cfg.assertions);
      expected = [
        {
          type = "target.inside-stash";
          entry = "bad-file";
          target = "dotfiles";
          stash = "dotfiles";
        }
      ];
    };
  };

  targetInsideStash-fail-inside = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
      files."bad-file" = {
        source = "/dev/null";
        target = "dotfiles/config/file.txt";
      };
    };
    "test should fail when target is inside stash folder" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion && a.type == "target.inside-stash") cfg.assertions);
      expected = [
        {
          type = "target.inside-stash";
          entry = "bad-file";
          target = "dotfiles/config/file.txt";
          stash = "dotfiles";
        }
      ];
    };
  };

  targetInsideStash-pass-similar-prefix = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
      files."ok-file" = {
        source = "/dev/null";
        target = "dotfilesother/file.txt";
      };
    };
    "test should pass when target has similar prefix but is not inside stash" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-stash") cfg.assertions;
      expected = [ ];
    };
  };

  targetInsideStash-pass-outside = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
      files."ok-file" = {
        source = "/dev/null";
        target = ".config/something";
      };
    };
    "test should pass when target is outside stash folder" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-stash") cfg.assertions;
      expected = [ ];
    };
  };

  targetInsideStash-absolute-stash-outside-home = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "/opt/dotfiles";
      files."ok-file" = {
        source = "/dev/null";
        target = "opt/dotfiles/file.txt";
      };
    };
    "test should pass when stash is absolute path outside home" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-stash") cfg.assertions;
      expected = [ ];
    };
  };

  # Target inside recursive folder tests
  targetInsideRecursive-fail = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "nvim-config" = {
          source = ./.;
          target = ".config/nvim";
          recursive = true;
        };
        "bad-file" = {
          source = "/dev/null";
          target = ".config/nvim/lua/plugins.lua";
        };
      };
    };
    "test should fail when target is inside recursive folder target" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion && a.type == "target.inside-recursive") cfg.assertions);
      expected = [
        {
          type = "target.inside-recursive";
          entry = "bad-file";
          target = ".config/nvim/lua/plugins.lua";
          recursiveTarget = ".config/nvim";
        }
      ];
    };
  };

  targetInsideRecursive-pass-same-target = {
    config = {
      homeDirectory = "/home/test";
      files."nvim-config" = {
        source = ./.;
        target = ".config/nvim";
        recursive = true;
      };
    };
    "test should pass for the recursive entry itself" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-recursive") cfg.assertions;
      expected = [ ];
    };
  };

  targetInsideRecursive-pass-sibling = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "nvim-config" = {
          source = ./.;
          target = ".config/nvim";
          recursive = true;
        };
        "ok-file" = {
          source = "/dev/null";
          target = ".config/other/file.txt";
        };
      };
    };
    "test should pass when target is sibling of recursive folder" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-recursive") cfg.assertions;
      expected = [ ];
    };
  };

  targetInsideRecursive-pass-similar-prefix = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "nvim-config" = {
          source = ./.;
          target = ".config/nvim";
          recursive = true;
        };
        "ok-file" = {
          source = "/dev/null";
          target = ".config/nvim-extra/file.txt";
        };
      };
    };
    "test should pass when target has similar prefix but is not inside" = {
      expr = cfg: builtins.filter (a: !a.assertion && a.type == "target.inside-recursive") cfg.assertions;
      expected = [ ];
    };
  };

  targetInsideRecursive-multiple-recursive = {
    config = {
      homeDirectory = "/home/test";
      files = {
        "nvim-config" = {
          source = ./.;
          target = ".config/nvim";
          recursive = true;
        };
        "tmux-config" = {
          source = ./.;
          target = ".config/tmux";
          recursive = true;
        };
        "bad-file" = {
          source = "/dev/null";
          target = ".config/tmux/plugins/tpm.conf";
        };
      };
    };
    "test should fail when target is inside any recursive folder" = {
      expr =
        cfg:
        builtins.map (
          a:
          builtins.removeAttrs a [
            "assertion"
            "message"
          ]
        ) (builtins.filter (a: !a.assertion && a.type == "target.inside-recursive") cfg.assertions);
      expected = [
        {
          type = "target.inside-recursive";
          entry = "bad-file";
          target = ".config/tmux/plugins/tpm.conf";
          recursiveTarget = ".config/tmux";
        }
      ];
    };
  };

  # Combined stash and recursive checks
  targetInsideStashAndRecursive-both-pass = {
    config = {
      homeDirectory = "/home/test";
      stashes."my-stash".path = "dotfiles";
      files = {
        "nvim-config" = {
          source = ./.;
          target = ".config/nvim";
          recursive = true;
        };
        "ok-file" = {
          source = "/dev/null";
          target = ".local/share/something";
        };
      };
    };
    "test should pass when target is outside both stash and recursive folders" = {
      expr =
        cfg:
        builtins.filter (
          a: !a.assertion && (a.type == "target.inside-stash" || a.type == "target.inside-recursive")
        ) cfg.assertions;
      expected = [ ];
    };
  };
}
