# Stash

A NixOS module for declaratively managing user configuration files through symlinks.

## Purpose

Home Manager already provides dotfiles management through `home.files`. At build time, a derivation is created with the contents of all of these files, which is then copied to the Nix store. At activation, the content of this derivation is symlinked to $HOME. This means all files declared through Home Manager are immutable, and any changes done to the source files will not be reflected in $HOME until the next rebuild. This might be fine for some files and setups, but if your config is more than a couple files (or is integrated into NixOS), trivial config changes, like changing some Hyprland window rules or adding new keywords, takes around 30 seconds or more of build time.

GNU Stow, and similar symlink managers, simply link source folders to destination folders. This allows tracking dotfiles with Git, and is ideal for rapidly changing dotfiles. However, it needs setup beforehand and on a NixOS ecosystem means a separate element to manage other than the NixOS configuration.

Stash is my proposal for a hybrid approach, supporting static/immutable symlinks like Home Manager, as well as declaring 'stashes' as a source - mutable files in the user's $HOME. This allows users to use static files for configs that depend on Nix expressions, like hardware configuration or other nix options, as well as dynamic config files that are frequently experimented on or changing, like for desktop programs or editors.

Like Home Manager, Stash leverages Nix generations to track state as much as possible. Immutable files are always tracked, both in content and location. For mutable files, the exact symlinks created are tracked, but not the content of these files.

## Quick Start

Add Stash to your flake inputs:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    stash.url = "github:435vic/stash";
    stash.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, stash, ... }: {
    nixosConfigurations.your-hostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        stash.nixosModules.default  # or ./path/to/stash/modules/nixos.nix
        ./configuration.nix
      ];
    };
  };
}
```

Then configure Stash for your user in your NixOS configuration:

```nix
{ config, ... }:
{
  stash.users.alice = {
    # Define a stash - a mutable directory in your home
    stashes.dotfiles = {
      path = "dotfiles";  # Will resolve to /home/alice/dotfiles
    };

    files = {
      # Static file from inline text (like Home Manager)
      ".bashrc".text = ''
        export PATH="$HOME/.local/bin:$PATH"
      '';

      # Dynamic file from a stash (mutable, no rebuild needed)
      ".config/hyprland" = {
        source = config.lib.stash.fromStash {
          stash = "dotfiles";
          path = "hyprland";
        };
        recursive = true;  # Link all files in the directory
      };
    };
  };
}
```

## Usage

### Static Files

Static files work similarly to Home Manager's `home.file`. They are copied to the Nix store at build time and symlinked to your home directory:

```nix
stash.users.alice.files = {
  # Inline text content
  "scripts/hello.sh" = {
    text = ''
      #!/bin/bash
      echo "Hello, world!"
    '';
    executable = true;
  };

  # From a path (copied to Nix store)
  ".config/someapp/config.toml".source = ./configs/someapp.toml;

  # Recursively link a directory
  ".config/nvim" = {
    source = ./nvim-config;
    recursive = true;
  };
};
```

### Stashes and Dynamic Files

Stashes are directories in your home folder that contain mutable configuration files. You can reference files within stashes to create symlinks that don't require a rebuild when the source files change:

```nix
stash.users.alice = {
  # Define your stashes
  stashes = {
    dotfiles.path = "dotfiles";           # ~/dotfiles
    wallpapers.path = "Pictures/walls";   # ~/Pictures/walls
  };

  files = {
    # Link a single file from a stash
    ".config/kitty/kitty.conf" = {
      source = config.lib.stash.fromStash {
        stash = "dotfiles";
        path = "kitty/kitty.conf";
      };
    };

    # Recursively link a directory from a stash
    # When files are added/removed, run `stash sync` to update symlinks
    ".config/hyprland" = {
      source = config.lib.stash.fromStash {
        stash = "dotfiles";
        path = "hyprland";
      };
      recursive = true;
    };

    # Link an entire stash directory recursively
    ".config/nvim" = {
      source = config.lib.stash.fromStash {
        stash = "dotfiles";
        path = "nvim";
      };
      recursive = true;
    };

    # Link a wallpaper
    "Pictures/current-wallpaper.png" = {
      source = config.lib.stash.fromStash {
        stash = "wallpapers";
        path = "forest.png";
      };
    };
  };
};
```

### Automatic Stash Initialization

For fresh system deployments, you can configure stashes to be automatically initialized from a remote source:

```nix
stash.users.alice.stashes = {
  dotfiles = {
    path = "dotfiles";
    init = {
      enable = true;
      source = {
        type = "git";
        url = "https://github.com/alice/dotfiles.git";
        ref = "main";  # Optional: branch, tag, or commit
      };
    };
  };

  # From a tarball
  wallpapers = {
    path = "Pictures/wallpapers";
    init = {
      enable = true;
      source = {
        type = "tarball";
        url = "https://example.com/wallpapers.tar.gz";
        stripComponents = 1;  # Strip the top-level directory
      };
    };
  };
};
```

The initialization runs as a separate systemd unit after the network is available and doesn't block boot.

### Syncing Changes

When you add or remove files in a recursively-linked stash directory, you can update the symlinks without a full NixOS rebuild:

```bash
stash sync
```

This re-runs the activation script using the current generation's configuration.

## Configuration Reference

### `stash.users.<name>.stashes`

Defines stash directories for a user.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `path` | string | — | Path to the stash, relative to home or absolute |
| `init.enable` | bool | `false` | Enable automatic initialization from remote |
| `init.source.type` | enum | `"git"` | Source type: `"git"`, `"tarball"`, or `"zip"` |
| `init.source.url` | string | `""` | URL to fetch from |
| `init.source.ref` | string | `null` | Git ref to checkout (git only) |
| `init.source.stripComponents` | int | `0` | Path components to strip (tarball/zip only) |

### `stash.users.<name>.files`

Defines files to be symlinked to the user's home directory.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `true` | Whether to create this file |
| `source` | path/string/attrset | — | Source of the file content |
| `text` | string | `null` | Inline text content (alternative to source) |
| `recursive` | bool | `false` | Recursively link directory contents |
| `executable` | bool | `false` | Make the file executable |
| `forced` | bool | `false` | Overwrite existing files |

### `config.lib.stash.fromStash`

Helper function to create a stash source reference:

```nix
config.lib.stash.fromStash {
  stash = "stash-name";  # Name of the stash
  path = "relative/path";  # Path within the stash
}
```

## How It Works

1. **Build time**: Static files are collected into a derivation and stored in the Nix store. Stash file declarations are recorded but their contents aren't stored.

2. **Activation**: A systemd service runs on boot/switch that:
   - Creates symlinks for static files pointing to the Nix store
   - Creates symlinks for stash files pointing to the actual files in your home directory
   - For recursive entries, walks the source directory and creates individual symlinks

3. **Sync**: The `stash sync` command re-runs activation to pick up new files in recursively-linked directories.

4. **Generations**: Each activation creates a new generation, allowing rollbacks. The current generation is tracked via a gcroot symlink at `~/.local/state/stash/gcroots/current-home`.
