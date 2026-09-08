#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dist_dir="$project_dir/dist"
app_path="$dist_dir/RelayMate.app"
read_write_image="$dist_dir/.RelayMate-rw.dmg"
output_image="$dist_dir/RelayMate.dmg"
checksum_file="$dist_dir/RelayMate.dmg.sha256"
volume_name="RelayMate"
mount_point=""

cleanup() {
  if [[ -n "$mount_point" && -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet || true
  fi
  [[ -f "$read_write_image" ]] && unlink "$read_write_image"
}
trap cleanup EXIT

"$project_dir/scripts/package-app.sh"

[[ -f "$read_write_image" ]] && unlink "$read_write_image"
[[ -f "$output_image" ]] && unlink "$output_image"
[[ -f "$checksum_file" ]] && unlink "$checksum_file"

hdiutil create \
  -size 64m \
  -fs HFS+ \
  -volname "$volume_name" \
  -ov \
  "$read_write_image" >/dev/null

attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$read_write_image")"
mount_point="$(print -r -- "$attach_output" | awk '/\/Volumes\// {sub(/^.*\/Volumes\//, "/Volumes/"); print; exit}')"
[[ -n "$mount_point" && -d "$mount_point" ]]

ditto "$app_path" "$mount_point/RelayMate.app"
ln -s /Applications "$mount_point/Applications"

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set bounds of container window to {120, 120, 720, 490}
    set arrangement of icon view options of container window to not arranged
    set icon size of icon view options of container window to 104
    set text size of icon view options of container window to 14
    set position of item "RelayMate.app" of container window to {165, 180}
    set position of item "Applications" of container window to {435, 180}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$mount_point" -quiet
mount_point=""
hdiutil convert "$read_write_image" -format UDZO -imagekey zlib-level=9 -o "$output_image" >/dev/null
unlink "$read_write_image"

(
  cd "$dist_dir"
  shasum -a 256 "${output_image:t}" > "${checksum_file:t}"
)

echo "$output_image"
echo "$checksum_file"
