#!/usr/bin/env bash
set -euo pipefail

stash_state="${1:-}"
if [ -z "$stash_state" ]; then
  echo "usage: make-manifest.sh <stash-state.json>" >&2
  exit 1
fi

# Reads stash-state.json (stash.json) and produces a manifest.json matching
# what activate.ts expects for an "old generation" with the *new* ManifestEntry
# format:
# - keys are relative targets (same strings as in the manifest)
# - values are ManifestEntry objects:
#   {
#     source,          # absolute source path
#     target,          # target path relative to HOME
#     recursiveRoot,   # top-level recursive root target or null
#     forced,          # bool
#     static,          # bool
#     stash,           # stash name or null
#     sourceRelPath    # path relative to stash root (or static root)
#   }
#
# NOTE: This helper currently reconstructs the manifest only from static files
# and stash-backed files described in stash.json. If the schema of stash.json
# changes again, this script must be kept in sync.

# Extract files and stashes sub-objects from the new-format stash.json
files_json=$(jq -c '.files // {}' "$stash_state")
stashes_json=$(jq -c '.stashes // {}' "$stash_state")

# Build a lookup for stash roots: name -> path
stash_root() {
  local stash_name="$1"
  echo "$stashes_json" | jq -r --arg name "$stash_name" '.[$name].path'
}

# Iterate over file entries
echo "$files_json" \
  | jq -c 'to_entries[]' \
  | while read -r entry; do
      name=$(echo "$entry" | jq -r '.key')
      target=$(echo "$entry" | jq -r '.value.target')
      recursive=$(echo "$entry" | jq -r '.value.recursive')
      forced=$(echo "$entry" | jq -r '.value.forced // false')
      executable=$(echo "$entry" | jq -r '.value.executable')
      static=$(echo "$entry" | jq -r '.value.source.static')
      stash=$(echo "$entry" | jq -r '.value.source.stash')
      src_path=$(echo "$entry" | jq -r '.value.source.path')

      # Resolve absolute source path:
      # - For static sources, stash.json already stores an absolute path.
      # - For stash-backed sources, resolve relative to the stash root.
      if [ "$static" = "true" ]; then
        abs_source="$src_path"
        source_rel_path="$src_path"
        stash_name="null"
      else
        stash_name="$stash"
        if [ "$stash_name" = "null" ] || [ -z "$stash_name" ]; then
          # Malformed entry; skip but keep behavior explicit.
          echo "Warning: Non-static entry '$name' has no stash; skipping" >&2
          continue
        fi
        root="$(stash_root "$stash_name")"
        if [ -z "$root" ] || [ "$root" = "null" ]; then
          echo "Warning: Stash '$stash_name' for entry '$name' has no path; skipping" >&2
          continue
        fi
        # src_path is interpreted as relative to the stash root
        # (matches expandEntry behavior). Ensure it is treated as
        # a relative path when joining with the stash root.
        src_rel_path="${src_path#/}"
        abs_source="${root%/}/${src_rel_path}"
        # For sourceRelPath, keep the leading slash to match expandEntry's
        # behavior for stash-backed entries (e.g. "/config-app/keep.toml").
        source_rel_path="/${src_rel_path}"
      fi

      # Normalize source path (avoid trailing slash)
      abs_source="${abs_source%/}"

      if [ "$recursive" = "true" ]; then
        # Recursive: walk the directory tree under abs_source and emit an entry
        # for each file, mirroring expandEntry() in activate.ts.
        if [ -d "$abs_source" ]; then
          while IFS= read -r -d '' file; do
            rel_path="${file#"${abs_source}/"}"
            file_target="$target/$rel_path"
            rel_inside_source_tree="${source_rel_path%/}/$rel_path"

            jq -n -c \
              --arg key "$file_target" \
              --arg src "$file" \
              --arg tgt "$file_target" \
              --arg recRoot "$target" \
              --argjson forced "$forced" \
              --argjson static "$static" \
              --arg stashName "$stash_name" \
              --arg srcRel "$rel_inside_source_tree" \
              '{
                key: $key,
                value: {
                  source: $src,
                  target: $tgt,
                  recursiveRoot: $recRoot,
                  forced: $forced,
                  static: $static,
                  stash: ($stashName | if . == "null" then null else . end),
                  sourceRelPath: $srcRel
                }
              }'
          done < <(find "$abs_source" -type f -print0)
        else
          echo "Warning: Source directory '$abs_source' not found for recursive entry (target '$target')." >&2
        fi
      else
        # Non-recursive: single manifest entry
        jq -n -c \
          --arg key "$target" \
          --arg src "$abs_source" \
          --arg tgt "$target" \
          --argjson forced "$forced" \
          --argjson static "$static" \
          --arg stashName "$stash_name" \
          --arg srcRel "$source_rel_path" \
          '{
            key: $key,
            value: {
              source: $src,
              target: $tgt,
              recursiveRoot: null,
              forced: $forced,
              static: $static,
              stash: ($stashName | if . == "null" then null else . end),
              sourceRelPath: $srcRel
            }
          }'
      fi
    done | jq -s 'from_entries'
