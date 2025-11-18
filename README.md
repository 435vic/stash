# Stash

A NixOS module for declaratively managing user configuration files through symlinks.

## Purpose

Home Manager already provides dotfiles management through `home.files`. At build time, a derivation is created with the contents of all of these files, which is then copied to the Nix store. At activation, the content of this derivation is symlinked to $HOME. This means all files declared through Home Manager are immutable, and any changes done to the source files will not be reflected in $HOME until the next rebuild. This might be fine for some files and setups, but if your config is more than a couple files (or is integrated into NixOS), trivial config changes, like changing some Hyprland window rules or adding new keywords, takes around 30 seconds or more of build time.

GNU Stow, and similar symlink managers, simply link source folders to destination folders. This allows tracking dotfiles with Git, and is ideal for rapidly changing dotfiles. However, it needs setup beforehand and on a NixOS ecosystem means a separate element to manage other than the NixOS configuration.

Stash is my proposal for a hybrid approach, supporting static/immutable symlinks like Home Manager, as well as declaring 'stashes' as a source - mutable files in the user's $HOME. This allows users to use static files for configs that depend on Nix expressions, like hardware configuration or other nix options, as well as dynamic config files that are frequently experimented on or changing, like for desktop programs or editors.

Like Home Manager, Stash leverages Nix generations to track state as much as possible. Immutable files are always tracked, both in content and location. For mutable files, the exact symlinks created are tracked, but not the content of these files.

## Architecture Overview

### Core Components

**NixOS Module System** (`modules/`)
- Defines the configuration schema for users, stashes, and files
- Integrates with the NixOS module system as a top-level `stash.users.<user>` option
- Validates configuration and generates activation packages

**Stashes**
- Named filesystem locations that serve as sources for configuration files
- Typically point to directories containing dotfiles (e.g., a Git repository)
- Resolved at activation time, allowing them to be mutable

**File Management**
- Each file entry specifies a source (static or from a stash) and a target location
- Supports both individual files and recursive directory linking
- Includes options for forcing overwrites and handling conflicts

**Activation Script** (`modules/activate.ts`)
- TypeScript/Deno-based runtime that performs the actual symlinking
- Handles collision detection with existing files
- Creates backups of user files when appropriate
- Maintains a manifest of managed symlinks for proper cleanup
- Cleans up symlinks from previous generations

### Data Flow

1. **Configuration**: User defines stashes and files in their NixOS configuration
2. **Build**: Nix evaluates the configuration and produces a generation package containing:
   - Static files in the Nix store
   - A JSON manifest describing all file management operations
3. **Activation**: The activation script runs at system activation time:
   - Checks for collisions with existing files
   - Backs up or removes old generation's symlinks
   - Creates new symlinks pointing to sources (store paths or stash locations)
   - Updates the manifest for future generations

### Testing

The project includes both unit tests (using nix-unit) and integration tests (using NixOS VM tests) to ensure correct behavior across various scenarios including collision handling, generation transitions, and edge cases.

## Design Philosophy

- **Generation-aware**: Properly integrates with NixOS's generation model for rollbacks and cleanup
- **Safe by default**: Detects conflicts and creates backups to avoid data loss
- **Flexible sourcing**: Supports both immutable (Nix store) and mutable (filesystem) sources
- **Atomic operations**: Uses atomic symlink replacement to avoid partial states
