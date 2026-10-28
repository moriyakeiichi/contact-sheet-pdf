#!/bin/bash
# 画像一覧PDF.app を作る（Apple Silicon と Intel の両方で動くユニバーサル版）
#   使い方: ./build.sh            → ../画像一覧PDF.app を作成
#           ./build.sh 出力先フォルダ
# 必要なもの: Xcode または Command Line Tools（xcode-select --install）
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"
OUTPUT_DIR="${1:-$PROJECT_DIR/..}"
APP_NAME="画像一覧PDF"
EXECUTABLE="ImageSheetPDF"
MIN_MACOS="13.0"

# macOS 27 SDK の SwiftUI は Command Line Tools に含まれないマクロ部品を必要とするため、
# Xcode がない環境では macOS 26 SDK を使う（作ったアプリは macOS 13 以降で動く）
if [[ -z "${SDKROOT:-}" ]]; then
    if xcode-select -p | grep -q "CommandLineTools"; then
        for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk; do
            if [[ -d "$candidate" ]]; then
                export SDKROOT="$candidate"
                break
            fi
        done
    fi
fi
echo "SDK: ${SDKROOT:-（既定）}"

BUILD_ROOT="$PROJECT_DIR/.build"
BINARIES=()
for ARCH in arm64 x86_64; do
    echo "== ${ARCH} 版をビルド =="
    ARGS=(-c release --triple "${ARCH}-apple-macosx${MIN_MACOS}" --scratch-path "$BUILD_ROOT/$ARCH")
    swift build "${ARGS[@]}" --product "$EXECUTABLE"
    BINARIES+=("$(swift build "${ARGS[@]}" --show-bin-path)/$EXECUTABLE")
done

APP="$OUTPUT_DIR/$APP_NAME.app"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/$APP_NAME.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/ja.lproj"

echo "== ユニバーサル版にまとめる =="
lipo -create -output "$STAGED_APP/Contents/MacOS/$EXECUTABLE" "${BINARIES[@]}"
cp Packaging/Info.plist "$STAGED_APP/Contents/Info.plist"
printf 'CFBundleName = "画像一覧PDF";\nCFBundleDisplayName = "画像一覧PDF";\n' > "$STAGED_APP/Contents/Resources/ja.lproj/InfoPlist.strings"

echo "== アイコンを作成 =="
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
swift Packaging/make_icon.swift "$STAGING/icon_1024.png"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE "$STAGING/icon_1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$STAGING/icon_1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"

echo "== 署名（このMac用のアドホック署名） =="
codesign --force --sign - "$STAGED_APP"

rm -rf "$APP"
mkdir -p "$OUTPUT_DIR"
mv "$STAGED_APP" "$APP"
echo "完成: $APP"
