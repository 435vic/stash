#!/usr/bin/env bash
set -euo pipefail

stash_state="${1:-}"
if [ -z "$stash_state" ]; then
  echo "usage: make-manifest.sh <stash-state.json>" >&2
  exit 1
fi

# Reads stash-state.json (stash.json) and produces a manifest.json matching
# what activate.ts expects for an "old generation":
# - keys are relative targets (same strings as in stash.json)
# - values are ManifestEntry objects:
#   { source, target, parent, static, forced }
#
# HOME is *not* baked in here; targets remain relative. activate.ts will
# later compute full paths as path.join(HOME, target).

jq -c 'to_entries[]' "$stash_state" | while read -r entry; do
  target=$(echo "$entry" | jq -r '.value.target')
  raw_source=$(echo "$entry" | jq -r '.value.source')
  # Normalize source path to avoid trailing slashes so it matches realpath
  source="${raw_source%/}"
  recursive=$(echo "$entry" | jq -r '.value.recursive')
  static=$(echo "$entry" | jq -r '.value.static')
  forced=$(echo "$entry" | jq -r '.value.forced // false')

  if [ "$recursive" = "true" ]; then
    if [ -d "$source" ]; then
      # Walk all files under the source directory, mirroring expandEntry()
      while IFS= read -r -d '' file; do
        # file is absolute path under normalized $source
        rel_path="${file#"${source}/"}"

        file_source="$file"
        file_target="$target/$rel_path"

        jq -n -c \
          --arg key "$file_target" \
          --arg src "$file_source" \
          --arg tgt "$file_target" \
          --arg parent "$target" \
          --argjson static "$static" \
          --argjson forced "$forced" \
          '{
            key: $key,
            value: {
              source: $src,
              target: $tgt,
              parent: $parent,
              static: $static,
              forced: $forced
            }
          }'
      done < <(find "$source" -type f -print0)
    else
      echo "Warning: Source directory '$source' not found for recursive entry (target '$target')." >&2
    fi
  else
    jq -n -c \
      --arg key "$target" \
      --arg src "$source" \
      --arg tgt "$target" \
      --argjson static "$static" \
      --argjson forced "$forced" \
      '{
        key: $key,
        value: {
          source: $src,
          target: $tgt,
          parent: null,
          static: $static,
          forced: $forced
        }
      }'
  fi
done | jq -s 'from_entries'
