#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
app_dir="$project_dir/dist/RelayMate.app"
contents_dir="$app_dir/Contents"

env \
  SWIFTPM_CACHE_PATH="$build_dir/cache" \
  CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" \
  swift build --package-path "$project_dir" --configuration release --disable-sandbox \
    --arch arm64 --arch x86_64

binary_dir="$(env \
  SWIFTPM_CACHE_PATH="$build_dir/cache" \
  CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache" \
  swift build --package-path "$project_dir" --configuration release --disable-sandbox \
    --arch arm64 --arch x86_64 --show-bin-path)"

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
install -m 755 "$binary_dir/RelaySetup" "$contents_dir/MacOS/RelaySetup"
install -m 644 "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
install -m 644 "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$app_dir"

echo "$app_dir"
