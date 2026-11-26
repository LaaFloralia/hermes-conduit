#!/bin/bash
# Copies each staff member's adopted avatar into the bundle being built as
# staff/<id>.png, longest side $1 pixels (160 for the Watch app, which is the
# default; the notification extension asks for 512, its attachment size).
set -euo pipefail
size="${1:-160}"
source_dir="$SRCROOT/docs/laa/assets/staff"
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/staff"
mkdir -p "$destination"
for directory in "$source_dir"/*/; do
  [ -d "$directory" ] || continue
  id="$(basename "$directory")"
  image="$directory$id-avatar-512.png"
  [ -f "$image" ] || continue
  /usr/bin/sips -Z "$size" "$image" --out "$destination/$id.png" >/dev/null
done
