#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd "$repo_root"

if xcodebuild -version >/dev/null 2>&1; then
    swift build --product FlyBy
else
    compatibility_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    if [ ! -d "$compatibility_sdk" ]; then
        echo "A compatible macOS SDK is required to build FlyBy." >&2
        exit 1
    fi
    mkdir -p .build/module-cache
    export SDKROOT="$compatibility_sdk"
    export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/module-cache"
    swift build --disable-sandbox --sdk "$SDKROOT" --product FlyBy
fi

app_path="$repo_root/.build/FlyBy.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$script_dir/FlyBy-Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/.build/debug/FlyBy" "$app_path/Contents/MacOS/FlyBy"
codesign --force --sign - --identifier com.dmj.flyby.mascot.dev "$app_path"
open -n "$app_path"
