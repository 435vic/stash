{
  pkgs,
  lib ? pkgs.lib,
  ...
}:
let
  # Default test user configuration
  testUser = "stash-test";
  testUserHome = "/home/${testUser}";

  # Helper to run a NixOS VM test with stash pre-configured
  #
  # Arguments:
  #   name: Test name (required)
  #   stashConfig: Stash configuration for the test user (required)
  #   testScript: Python test script (required)
  #   extraConfig: Additional NixOS configuration (optional)
  #   preStashSetup: Commands to run before stash activation, e.g., to set up stash directories (optional)
  runStashTest =
    {
      name,
      stashConfig,
      testScript,
      extraConfig ? { },
      preStashSetup ? "",
    }:
    pkgs.testers.runNixOSTest {
      inherit name;

      nodes.machine =
        { config, ... }:
        {
          imports = [ ../../modules/nixos.nix ] ++ (extraConfig.imports or [ ]);

          users.users.${testUser} = {
            isNormalUser = true;
            home = testUserHome;
            createHome = true;
          };

          # Basic VM configuration
          virtualisation = {
            memorySize = 1024;
            diskSize = 2048;
          };

          # Speed up tests by disabling unnecessary services
          documentation.enable = false;
          security.sudo.wheelNeedsPassword = false;

          stash.users.${testUser} = stashConfig;
        }
        // (builtins.removeAttrs extraConfig [ "imports" ]);

      testScript = ''
        machine.start()
        machine.wait_for_unit("multi-user.target")

        ${lib.optionalString (preStashSetup != "") ''
          # Run pre-stash setup as test user
          machine.succeed("sudo -u ${testUser} bash -c '${preStashSetup}'")
        ''}

        # Wait for stash activation service
        machine.wait_for_unit("stash-${testUser}.service")

        ${testScript}
      '';
    };

  # Helper to check if a symlink points to the expected target
  # Usage in testScript: checkSymlink("/home/stash-test/.config/app", "/nix/store/...")
  checkSymlinkScript = ''
    def check_symlink(machine, path, expected_target=None):
        """Check if path is a symlink and optionally verify its target."""
        result = machine.succeed(f"readlink -f {path}").strip()
        if expected_target:
            assert result == expected_target, f"Symlink {path} points to {result}, expected {expected_target}"
        return result

    def check_file_content(machine, path, expected_content):
        """Check if a file contains the expected content."""
        result = machine.succeed(f"cat {path}").strip()
        assert result == expected_content.strip(), f"File {path} contains '{result}', expected '{expected_content.strip()}'"

    def check_file_exists(machine, path):
        """Check if a file or directory exists."""
        machine.succeed(f"test -e {path}")

    def check_file_not_exists(machine, path):
        """Check that a file or directory does not exist."""
        machine.succeed(f"test ! -e {path}")

    def check_is_symlink(machine, path):
        """Check that a path is a symlink."""
        machine.succeed(f"test -L {path}")

    def check_is_directory(machine, path):
        """Check that a path is a directory."""
        machine.succeed(f"test -d {path}")

    def check_is_regular_file(machine, path):
        """Check that a path is a regular file."""
        machine.succeed(f"test -f {path}")

    def as_test_user(cmd):
        """Wrap a command to run as the test user."""
        return f"sudo -u ${testUser} bash -c '{cmd}'"
  '';

in
{
  inherit
    runStashTest
    testUser
    testUserHome
    checkSymlinkScript
    ;

  # Example/template tests - these serve as documentation and basic smoke tests
  tests = {
    # Basic test: static file from text
    static-text-file = runStashTest {
      name = "stash-static-text-file";
      stashConfig = {
        files."test-config.txt".text = ''
          Hello from Stash!
        '';
      };
      testScript = ''
        ${checkSymlinkScript}

        # Verify the file was created
        check_file_exists(machine, "${testUserHome}/test-config.txt")
        check_is_symlink(machine, "${testUserHome}/test-config.txt")

        # Verify content
        content = machine.succeed("cat ${testUserHome}/test-config.txt")
        assert "Hello from Stash!" in content, f"Unexpected content: {content}"
      '';
    };

    # Test: file from stash directory
    stash-file = runStashTest {
      name = "stash-stash-file";
      stashConfig = {
        stashes.dotfiles.path = "dotfiles";

        files.".config/app/settings.toml" = {
          source = {
            static = false;
            stash = "dotfiles";
            path = "app/settings.toml";
          };
        };
      };
      preStashSetup = ''
        mkdir -p ~/dotfiles/app
        echo 'theme = "dark"' > ~/dotfiles/app/settings.toml
      '';
      testScript = ''
        ${checkSymlinkScript}

        # Verify the symlink was created
        check_file_exists(machine, "${testUserHome}/.config/app/settings.toml")
        check_is_symlink(machine, "${testUserHome}/.config/app/settings.toml")

        # Verify it points to the stash
        target = machine.succeed("readlink ${testUserHome}/.config/app/settings.toml").strip()
        assert "dotfiles/app/settings.toml" in target, f"Unexpected symlink target: {target}"

        # Verify content
        check_file_content(machine, "${testUserHome}/.config/app/settings.toml", 'theme = "dark"')
      '';
    };

    # Test: recursive directory from stash
    stash-recursive = runStashTest {
      name = "stash-recursive-directory";
      stashConfig = {
        stashes.dotfiles.path = "dotfiles";

        files.".config/app" = {
          source = {
            static = false;
            stash = "dotfiles";
            path = "app-config";
          };
          recursive = true;
        };
      };
      preStashSetup = ''
        mkdir -p ~/dotfiles/app-config/themes
        echo 'main config' > ~/dotfiles/app-config/config.toml
        echo 'keybindings' > ~/dotfiles/app-config/keys.toml
        echo 'dark theme' > ~/dotfiles/app-config/themes/dark.toml
      '';
      testScript = ''
        ${checkSymlinkScript}

        # Verify the directory structure was created
        check_is_directory(machine, "${testUserHome}/.config/app")
        check_is_directory(machine, "${testUserHome}/.config/app/themes")

        # Verify individual files are symlinks
        check_is_symlink(machine, "${testUserHome}/.config/app/config.toml")
        check_is_symlink(machine, "${testUserHome}/.config/app/keys.toml")
        check_is_symlink(machine, "${testUserHome}/.config/app/themes/dark.toml")

        # Verify content
        check_file_content(machine, "${testUserHome}/.config/app/config.toml", "main config")
        check_file_content(machine, "${testUserHome}/.config/app/themes/dark.toml", "dark theme")
      '';
    };

    # Test: mixed static and stash files
    mixed-static-and-stash = runStashTest {
      name = "stash-mixed-static-and-stash";
      stashConfig = {
        stashes.dotfiles.path = "dotfiles";

        files = {
          # Static file from text
          ".config/app/generated.toml".text = ''
            # Auto-generated by NixOS
            version = 1
          '';

          # File from stash
          ".config/app/user.toml" = {
            source = {
              static = false;
              stash = "dotfiles";
              path = "app/user.toml";
            };
          };
        };
      };
      preStashSetup = ''
        mkdir -p ~/dotfiles/app
        echo 'name = "testuser"' > ~/dotfiles/app/user.toml
      '';
      testScript = ''
        ${checkSymlinkScript}

        # Both files should exist
        check_file_exists(machine, "${testUserHome}/.config/app/generated.toml")
        check_file_exists(machine, "${testUserHome}/.config/app/user.toml")

        # Verify content of static file
        content = machine.succeed("cat ${testUserHome}/.config/app/generated.toml")
        assert "Auto-generated by NixOS" in content
        assert "version = 1" in content

        # Verify content of stash file
        check_file_content(machine, "${testUserHome}/.config/app/user.toml", 'name = "testuser"')
      '';
    };
  };
}
