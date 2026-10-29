#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "${1:-}" in
    ""|--install) ;;
    *) printf 'Usage: %s [--install]\n' "$0" >&2; exit 2 ;;
esac

case "$(uname -m)" in
    arm64) arch=arm64 ;;
    x86_64) arch=x64 ;;
    *) printf 'Unsupported Mac architecture\n' >&2; exit 1 ;;
esac

# Installation happens only during the build, never during a menu-bar refresh.
bun install --cwd "$root/Tools" --ignore-scripts
native="$root/Tools/node_modules/@ccusage/ccusage-darwin-$arch/bin/ccusage"
test -f "$native"
chmod +x "$native"
"$native" --version

swift build --package-path "$root" -c release --product AIUsageMenuBar
bin_dir=$(swift build --package-path "$root" -c release --show-bin-path)
app="$root/build/AI Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/AIUsageMenuBar" "$app/Contents/MacOS/AIUsageMenuBar"
cp "$native" "$app/Contents/Resources/ccusage"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Resources/ccusage"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

if [ "${1:-}" = --install ]; then
    destination="$HOME/Applications/AI Usage.app"
    if [ -e "$destination" ]; then
        identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist")
        if [ "$identifier" != com.bsamek.ai-usage-menubar ]; then
            printf 'Refusing to overwrite an unrelated app: %s\n' "$destination" >&2
            exit 1
        fi
    fi
    mkdir -p "$HOME/Applications"
    ditto "$app" "$destination"
    printf 'Installed %s\n' "$destination"
else
    printf 'Built %s\n' "$app"
fi
