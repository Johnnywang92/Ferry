#!/bin/bash
# Ferry DMG 打包与发布产物装配脚本（v2.3 §524, ADR-0000 §5）。
#
# 输出：
#   App/build/dist/Ferry-1.0.0-beta.1.dmg
#   App/build/dist/Ferry-1.0.0-beta.1.zip
#   App/build/dist/appcast.xml
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$HERE/build"
APP="$BUILD_DIR/Ferry.app"
DIST_DIR="$BUILD_DIR/dist"
VERSION="1.0.0-beta.1"
DMG_NAME="Ferry-${VERSION}.dmg"
ZIP_NAME="Ferry-${VERSION}.zip"
DMG_PATH="$DIST_DIR/$DMG_NAME"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"

echo "== 1. 组装与签名 Ferry.app"
"$HERE/build-and-sign.sh" --skip-keychain

echo "== 2. 准备发布目录"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

echo "== 3. 创建 ZIP 发布包"
ditto -c -k --keepParent "$APP" "$ZIP_PATH"
ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
ZIP_SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
echo "  ZIP 产物：$ZIP_PATH ($ZIP_SIZE 字节, SHA-256: $ZIP_SHA256)"

echo "== 4. 创建 DMG 镜像（配置挂载自动弹窗与拖拽安装布局）"
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP" "$STAGING_DIR/"

if command -v create-dmg >/dev/null 2>&1; then
    rm -f "$DMG_PATH"
    set +e
    create-dmg \
        --volname "Ferry" \
        --window-pos 260 160 \
        --window-size 540 380 \
        --icon-size 96 \
        --icon "Ferry.app" 140 180 \
        --app-drop-link 400 180 \
        --hide-extension "Ferry.app" \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING_DIR/"
    CREATE_DMG_RC=$?
    set -e
    if [[ $CREATE_DMG_RC -ne 0 && ! -f "$DMG_PATH" ]]; then
        echo "  create-dmg 退出码 $CREATE_DMG_RC，回退到基础 hdiutil"
        ln -s /Applications "$STAGING_DIR/Applications"
        hdiutil create -volname "Ferry" \
            -srcfolder "$STAGING_DIR" \
            -ov -format UDZO \
            "$DMG_PATH" >/dev/null
    fi
else
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create -volname "Ferry" \
        -srcfolder "$STAGING_DIR" \
        -ov -format UDZO \
        "$DMG_PATH" >/dev/null
fi

rm -rf "$STAGING_DIR"
DMG_SIZE=$(stat -f%z "$DMG_PATH")
DMG_SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
echo "  DMG 产物：$DMG_PATH ($DMG_SIZE 字节, SHA-256: $DMG_SHA256)"

echo "== 5. 生成 Sparkle appcast.xml"
PUB_DATE=$(date -R)
cat <<EOF > "$DIST_DIR/appcast.xml"
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Ferry Changelog</title>
        <link>https://github.com/yifanwang/Ferry</link>
        <description>Most recent changes with links to updates.</description>
        <language>zh-CN</language>
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:releaseNotesLink>https://github.com/yifanwang/Ferry/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
            <enclosure
                url="https://github.com/yifanwang/Ferry/releases/download/v${VERSION}/${ZIP_NAME}"
                sparkle:version="100"
                sparkle:shortVersionString="${VERSION}"
                length="${ZIP_SIZE}"
                type="application/octet-stream" />
        </item>
    </channel>
</rss>
EOF

echo "  Appcast：$DIST_DIR/appcast.xml"
echo "== 打包完成！发布产物就绪："
ls -lh "$DIST_DIR"
