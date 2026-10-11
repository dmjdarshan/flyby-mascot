#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname -- "$script_dir")
cd "$repo_root"

echo "==> Parsing Swift sources"
swiftc -frontend -parse \
    Sources/FlyByCore/*.swift \
    Sources/FlyByApp/*.swift \
    Sources/FlyByCoreChecks/*.swift \
    Tests/FlyByCoreTests/*.swift

mkdir -p .build/module-cache

if xcodebuild -version >/dev/null 2>&1; then
    echo "==> Building FlyBy with Xcode toolchain"
    swift build --product FlyBy
    echo "==> Running core checks"
    swift run FlyByCoreChecks
    echo "==> Running XCTest suite"
    swift test
else
    compatibility_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
    if [ ! -d "$compatibility_sdk" ]; then
        echo "Full Xcode is unavailable and the known compatible Command Line Tools SDK was not found." >&2
        echo "Install/select Xcode, or update .codex/verify.sh for the installed matching SDK." >&2
        exit 1
    fi

    export SDKROOT="$compatibility_sdk"
    export CLANG_MODULE_CACHE_PATH="$repo_root/.build/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/module-cache"

    echo "==> Building FlyBy with the compatible Command Line Tools SDK"
    swift build --disable-sandbox --sdk "$SDKROOT" --product FlyBy
    echo "==> Running framework-independent core checks"
    swift run --disable-sandbox --sdk "$SDKROOT" FlyByCoreChecks
    echo "==> XCTest skipped: this Command Line Tools installation does not include XCTest"
fi

echo "==> FlyBy verification complete"

