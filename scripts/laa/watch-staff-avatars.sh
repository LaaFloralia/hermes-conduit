#!/bin/bash
set -euo pipefail
source_dir="$SRCROOT/docs/laa/assets/staff"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/staff"
mkdir -p "$destination"
for directory in "$source_dir"/*/; do
  [ -d "$directory" ] || continue
  id="$(basename "$directory")"
  image="$directory$id-avatar-512.png"
  [ -f "$image" ] || continue
  /usr/bin/sips -Z 160 "$image" --out "$destination/$id.png" >/dev/null
done
