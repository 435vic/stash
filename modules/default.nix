{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    types
    mkOption
    hasPrefix
    mkDefault
    mkIf
    mkMerge
    genList
    length
    lowerChars
    replaceStrings
    stringToCharacters
    upperChars
    mapAttrsToList
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
  fileType = types.attrsOf (
    types.submodule (
      { name, config, ... }:
      {
        options = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Whether this file should be generated. This option allows specific
              files to be disabled.
            '';
          };

          forced = mkOption {
            type = types.bool;
            default = false;
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

          source =
            let
              sourceDef = {
                static = mkOption {
                  type = types.bool;
                };

                stash = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                };

                path = mkOption {
                  type = types.oneOf [
                    types.path
                    types.str
                  ];
                };
              };

              strOrSourceDef = types.mkOptionType {
                name = "strOrSourceDef";
                description = "string, path, or result of config.lib.stash.fromStash";
                check = v: lib.isAttrs v || lib.isStringLike v;
                merge =
                  loc: defs:
                  let
                    coerceDef =
                      def:
                      if lib.isStringLike def.value then
                        {
                          inherit (def) file;
                          value = {
                            static = true;
                            path = def.value;
                          };
                        }
                      else
                        def;
                    sourceDefType = types.submodule { options = sourceDef; };
                  in
                  sourceDefType.merge loc (lib.map coerceDef defs);
              };
            in
            mkOption {
              type = strOrSourceDef;
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
          ];
        };
      }
    )
  );

  stashType =
    let
      inherit (config) homeDirectory;
    in
    types.attrsOf (
      types.submodule (
        { name, config, ... }:
        {
          options = {
            name = mkOption {
              type = types.str;
              internal = true;
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
              apply = p: if hasPrefix "/" p then p else "${homeDirectory}/${p}";
              type = types.str;
            };
          };

          config = {
            inherit name;
          };
        }
      )
    );
  staticFiles = lib.filterAttrs (_: f: f.source.static) config.files;
  stashFiles = lib.filterAttrs (_: f: !f.source.static) config.files;
in
{
  imports = [
    (pkgs.path + "/nixos/modules/misc/assertions.nix")
  ];

  options = {
    stashes = mkOption {
      description = "Stashes for this user. Can be used to symlink files from.";
      default = { };
      type = stashType;
    };

    files = mkOption {
      description = "Files to be managed by Stash. Target paths will always be relative to the user's home directory.";
      default = { };
      type = fileType;
    };

    homeDirectory = mkOption {
      description = ''
        The user's home directory. All symlinks will be linked relative to
        this location. Stashes with relative paths (not starting with '/') will
        be interpreted as relative to this location.
      '';
      readOnly = true;
      type = types.str;
    };

    user = mkOption {
      description = "The user's username.";
      readOnly = true;
      type = types.str;
    };

    staticFileDerivation = mkOption {
      type = types.nullOr types.package;
      internal = true;
      description = "Derivation with all store-based symlinks";
      default = null;
    };

    stashStateDerivation = mkOption {
      type = types.nullOr types.package;
      internal = true;
      description = "State of stash-managed links";
      default = null;
    };

    generationPackage = mkOption {
      internal = true;
      type = types.package;
      description = "derivation containing all of the information for this generation";
      default = null;
    };
  };

  config = {
    assertions =
      let
        validStashRefs = mapAttrsToList (
          _: f:
          mkIf (!f.source.static) {
            assertion = builtins.hasAttr f.source.stash config.stashes;
            type = "stash.undefined";
            stash = f.source.stash;
            target = f.target;
            message = ''Stash name ${f.source.stash} for `files."${f.target}" has not been defined.'';
          }
        ) config.files;
        # 1. Duplicate targets check
        # We group files by their target path and check if any group has more than one member.
        filesByTarget = lib.groupBy (f: f.target) (lib.attrValues config.files);
        duplicateTargets = lib.filterAttrs (n: v: lib.length v > 1) filesByTarget;
        duplicateTargetAssertions = lib.mapAttrsToList (target: files: {
          assertion = false;
          type = "target.duplicate";
          target = target;
          message = ''
            The target file "${target}" is defined multiple times.
          '';
        }) duplicateTargets;

        # 2. `recursive` only for directories (for static files)
        recursiveFileAssertions = lib.mapAttrsToList (n: f: {
          assertion = !(f.source.static && f.recursive && !lib.pathIsDirectory f.source.path);
          type = "entry.invalid-recursive";
          entry = n;
          source = f.source.path;
          message = ''
            The file entry "${f.target}" has `recursive = true`, but its source is not a directory.
            Source: ${toString f.source.path}
          '';
        }) staticFiles;

        # 3. Target path safety checks
        targetPathSafetyAssertions = lib.mapAttrsToList (n: f: {
          assertion = !lib.hasInfix ".." f.target;
          entry = n;
          target = f.target;
          type = "target.forbidden";
          message = ''
            The target path "${f.target}" for file entry "${n}" contains ".." which is not allowed for security reasons.
          '';
        }) config.files;

        # 4. Stash source path safety checks
        stashSourcePathSafetyAssertions = lib.mapAttrsToList (n: f: {
          assertion = f.source.static || !lib.hasInfix ".." f.source.path;
          type = "source.forbidden";
          entry = n;
          source = f.source.path;
          message = ''
            The stash source path "${f.source.path}" for file entry "${n}" contains ".." which is not allowed.
            Paths inside a stash must be relative to the stash's root.
          '';
        }) stashFiles;

      in
      mkMerge [
        validStashRefs
        duplicateTargetAssertions
        recursiveFileAssertions
        targetPathSafetyAssertions
        stashSourcePathSafetyAssertions
      ];

    staticFileDerivation = mkIf (staticFiles != { }) (
      pkgs.runCommandLocal "stash-files"
        {
          nativeBuildInputs = [ pkgs.xorg.lndir ];
        }
        (
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
                  (sourceStorePath v.source.path)
                  v.target
                  (if v.executable == null then "inherit" else toString v.executable)
                  (toString v.recursive)
                  (toString false)
                ]
              }
            '') staticFiles
          )
        )
    );

    stashStateDerivation =
      let
        files = lib.mapAttrs' (name: cfg: {
          name = name;
          value = {
            target = cfg.target;
            recursive = cfg.recursive;
            forced = cfg.forced;
            executable = cfg.executable;
            source = {
              static = cfg.source.static;
              stash = if cfg.source.static then null else cfg.source.stash;
              # For static files, ensure the path is copied to the store and we record
              # the store path. For stash files, the path is relative to the stash root.
              path = if cfg.source.static then toString (sourceStorePath cfg.source.path) else cfg.source.path;
            };
          };
        }) config.files;

        stashes = lib.mapAttrs' (name: stashCfg: {
          name = name;
          value = {
            name = stashCfg.name;
            path = stashCfg.path;
          };
        }) config.stashes;
      in
      (pkgs.writeText "stash.json" (
        builtins.toJSON {
          inherit files stashes;
        }
      ));

    generationPackage =
      let
        metaDerivation = pkgs.writeText "stash-meta.json" (
          builtins.toJSON {
            inherit (config) user homeDirectory;
          }
        );
      in
      pkgs.runCommandLocal "stash" { } ''
        mkdir -p $out

        ${lib.optionalString (staticFiles != { }) "ln -s ${config.staticFileDerivation} $out/static-files"}
        ln -s ${config.stashStateDerivation} $out/stash.json
        ln -s ${metaDerivation} $out/meta.json

        # possible home manager extra commands?
      '';
  };
}
