#!/usr/bin/env bash
# 拉取上游 LX Music Desktop 源码（仅用于重新生成内置元数据 bundle）
# 上游源码不提交，输出到 tools/musicSdk-bundle/upstream/
set -euo pipefail

cd "$(dirname "$0")/.."
TAG="${LX_UPSTREAM_TAG:-v2.12.6}"
DEST="tools/musicSdk-bundle/upstream"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载 lyswhut/lx-music-desktop $TAG"
curl -fL "https://github.com/lyswhut/lx-music-desktop/archive/refs/tags/${TAG}.tar.gz" -o "$TMP/lx.tar.gz"
tar -xzf "$TMP/lx.tar.gz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 3 -type d -path '*/lx-music-desktop-*/src' | head -1)"
[ -n "$SRC" ] || { echo "未找到上游 src 目录"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$SRC" "$DEST/src"
echo "==> 上游源码已就位: $DEST/src"
echo "    接下来: cd tools/musicSdk-bundle && npm install && npm run build"
