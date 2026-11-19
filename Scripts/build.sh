#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist .build/ModuleCache
stage=$(mktemp -d dist/.folio-package.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Folio.app"
iconset="$stage/FolioMono.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O -whole-module-optimization \
    -module-cache-path .build/ModuleCache -parse-as-library Sources/*.swift -o .build/Folio
install -m 755 .build/Folio "$app/Contents/MacOS/Folio"
xcrun strip -x "$app/Contents/MacOS/Folio"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp -R Resources/Math "$app/Contents/Resources/"
for size in 16 32 128 256 512; do
    for density in 1 2; do
        pixels=$((size * density))
        suffix=""
        if [[ $density == 2 ]]; then suffix="@2x"; fi
        sips -s format png -z "$pixels" "$pixels" Resources/06_mono.svg \
            --out "$iconset/icon_${size}x${size}${suffix}.png" >/dev/null
    done
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/FolioMono.icns"
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/PageTools"
install -m 755 Resources/PageTools/qpdf "$app/Contents/Helpers/qpdf"
cp -R Resources/PageTools/Notices/. "$app/Contents/Resources/PageTools/"
codesign --force --sign "${FOLIO_SIGN_IDENTITY:--}" --identifier app.folio.reader.qpdf "$app/Contents/Helpers/qpdf"
codesign --force --sign "${FOLIO_SIGN_IDENTITY:--}" --identifier app.folio.reader "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/Folio-arm64.zip"
# Publish a complete bundle with fresh directory metadata so Finder refreshes its icon.
if [[ -e dist/Folio.app ]]; then
    xcrun swift -module-cache-path .build/ModuleCache -e '
        import Darwin
        if renamex_np(CommandLine.arguments[1], CommandLine.arguments[2], UInt32(RENAME_SWAP)) != 0 {
            perror("publish Folio.app")
            exit(1)
        }' "$app" dist/Folio.app
else
    mv "$app" dist/Folio.app
fi
mv "$stage/Folio-arm64.zip" dist/Folio-arm64.zip
