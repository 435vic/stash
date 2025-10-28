{ name, config, lib, pkgs, ... }:

let
  inherit (lib) types mkOption mkDefault mkIf mkMerge
    genList
    length
    lowerChars
    replaceStrings
    stringToCharacters
    upperChars
    ;

  storeFileName =
    path:
    let
      # All characters that are considered safe. Note "-" is not
      # included to avoid "-" followed by digit being interpreted as a
      # version.
      safeChars = [
        "+"
        "."
        "_"
        "?"
        "="
      ]
      ++ lowerChars
      ++ upperChars
      ++ stringToCharacters "0123456789";

      empties = l: genList (x: "") (length l);

      unsafeInName = stringToCharacters (replaceStrings safeChars (empties safeChars) path);

      safeName = replaceStrings unsafeInName (empties unsafeInName) path;
    in
    "stash_" + safeName;

  sourceStorePath =
    source:
    let
      sourcePath = toString source;
      sourceName = storeFileName (baseNameOf sourcePath);
    in
    if builtins.hasContext sourcePath then
      source
    else
      builtins.path {
        path = source;
        name = sourceName;
      };

  # TODO: custom path type with apply
  # can be an absolute path starting with the specified base,
  # or a relative path interpreted as starting with the specified base
  pathWithBase = types.pathWith { absolute = false; };
  fileType =
      types.attrsOf (
        types.submodule (
          { name, config, ... }: {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = ''
                  Whether this file should be generated. This option allows specific
                  files to be disabled.
                '';
              };

              recursive = mkOption {
                type = types.bool;
                default = false;
              };

              executable = mkOption {
                type = types.bool;
                default = false;
              };

              target = mkOption {
                type = pathWithBase;
                # apply = p: p;
              };

              text = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Text of the file. Either this option or
                  the source option must be set.
                '';
              };

              source = mkOption {
                type = with types; unique { message = "Only one of `source`, `text` or `stash.source` must be set"; } (nullOr path);
              };

              stash = mkOption {
                type = types.nullOr (types.submodule {
                  options = {
                    enable = mkOption {
                      type = types.bool;
                      default = true;
                    };

                    source = mkOption {
                      type = types.str;
                      description = ''
                        If declared, the file will be symlinked from a non-Nix store location,
                        called a 'stash'. Works similarly to other dotfile managers like Stow.
                        If enabled, will take priority over the `source` and `text` options.
                      '';
                    };
                  };
                });
                default = null;
              };
            };

            config = {
              target = mkDefault name;
              source = mkMerge [
                (mkIf (config.text != null) (
                    pkgs.writeTextFile {
                      inherit (config) text;
                      # executable = config.executable == true;
                      executable = false;
                      name = "stash_" + (builtins.baseNameOf name);
                    }
                ))
                (mkIf (config.stash ? enable && config.stash.enable) null)
              ];
            };
          }
        )
      );

  stashType =
    types.attrsOf (
      types.submodule (
        { name, config, ... }: {
          options = {
            name = mkOption {
              type = types.str;
              description = ''
                The name of the stash.
              '';
            };

            init = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Whether to enable automatic initialization of the stash. When deploying to a new system,
                  the filesystem will be empty. The `init` options allow specifying how and from where an
                  initial source will be fetched from.
                '';
              };

              # WIP: need to add options to specify where to pull the initial files from
              # could be tarball, or an actual git repo
            };

            path = mkOption {
              description = "Path to the location of the stash, resolved in runtime.";
              type = pathWithBase;
            };
          };

          config = {
            name = mkDefault name;
          };
        }
      )
    );
  staticFiles = lib.filterAttrs (_: f: f.source != null && f.enable) config.files;
in {
  imports = [
    (pkgs.path + "/nixos/modules/misc/assertions.nix")
  ];

  options = {
    stashes = mkOption {
      description = "Stashes for this user. Can be used to symlink files from.";
      default = {};
      type = stashType;
    };

    files = mkOption {
      description = "Files to be managed by Stash. Target paths will always be relative to the user's home directory.";
      default = {};
      type = fileType;
    };

    username = mkOption {
      description = ''
        The username that this config applies to. All target paths specified in `files` will be interpreted
        relative to `users.users.$${username}.home`.
      '';
      type = types.str;
    };

    activationScript = mkOption {
      internal = true;
      type = types.str;
      default = "";
    };

    staticFileDerivation = mkOption {
      type = types.nullOr types.package;
      internal = true;
      description = "Derivation will all store-based symlinks";
      default = null;
    };

    stashStateDerivation = mkOption {
      type = types.nullOr types.package;
      internal = true;
      description = "State of stash-managed links";
      default = null;
    };
  };

  config = {
    username = mkDefault name;

    staticFileDerivation = 
      pkgs.runCommandLocal "stash-files" {
        nativeBuildInputs = [ pkgs.xorg.lndir ];
      } (
      ''
        mkdir -p $out

        # Needed in case /nix is a symbolic link.
        realOut="$(realpath -m "$out")"

        function insertFile() {
          local source="$1"
          local relTarget="$2"
          local executable="$3"
          local recursive="$4"
          local ignorelinks="$5"

          if [[ -e "$realOut/$relTarget" ]]; then
            echo "File conflict for file '$relTarget'" >&2
            return
          fi

          # Figure out the real absolute path to the target.
          local target
          target="$(realpath -m "$realOut/$relTarget")"

          # Target path must be within $HOME.
          if [[ ! $target == $realOut* ]] ; then
            echo "Error installing file '$relTarget' outside \$HOME" >&2
            exit 1
          fi

          mkdir -p "$(dirname "$target")"
          if [[ -d $source ]]; then
            if [[ $recursive ]]; then
              mkdir -p "$target"
              # if [[ $ignorelinks ]]; then
              #   lndir -silent -ignorelinks "$source" "$target"
              # else
                lndir -silent "$source" "$target"
              # fi
            else
              ln -s "$source" "$target"
            fi
          else
            [[ -x $source ]] && isExecutable=1 || isExecutable=""

            # Link the file into the home file directory if possible,
            # i.e., if the executable bit of the source is the same we
            # expect for the target. Otherwise, we copy the file and
            # set the executable bit to the expected value.
            if [[ $executable == inherit || $isExecutable == $executable ]]; then
              ln -s "$source" "$target"
            else
              cp "$source" "$target"

              if [[ $executable == inherit ]]; then
                # Don't change file mode if it should match the source.
                :
              elif [[ $executable ]]; then
                chmod +x "$target"
              else
                chmod -x "$target"
              fi
            fi
          fi
        }
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (n: v: ''
          insertFile ${
            lib.escapeShellArgs [
              (sourceStorePath v.source)
              v.target
              (if v.executable == null then "inherit" else toString v.executable)
              (toString v.recursive)
              (toString false)
            ]
          }
        '') staticFiles
      )
    );
  };
}
