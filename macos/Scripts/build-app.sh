#!/usr/bin/env bash
# 组装可双击运行的 Melo.app（开发期 ad-hoc 签名）。
#
# 用法:
#   Scripts/build-app.sh             # debug 构建（默认，快）
#   Scripts/build-app.sh release     # release 构建
#   Scripts/build-app.sh debug --run # 构建后直接启动
set -euo pipefail

cd "$(dirname "$0")/.."   # -> macos/
CONFIG="${1:-debug}"
RUN="${2:-}"

APP_NAME="Melo"
BUILD_DIR="$PWD/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Melo"
[[ -x "$BIN" ]] || { echo "未找到可执行文件: $BIN"; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R Resources/. "$APP/Contents/Resources/"
# 许可证/致谢
if [[ -f ../LICENSE ]]; then cp ../LICENSE "$APP/Contents/Resources/LICENSE"; fi
if [[ -f LICENSE ]]; then cp LICENSE "$APP/Contents/Resources/LICENSE"; fi

# ad-hoc 签名（开发期；正式分发需 Developer ID + notarytool）
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "警告: ad-hoc 签名失败（可直接从命令行运行）"
codesign -dv "$APP" 2>&1 | head -3 || true

echo "==> 完成: $APP"
if [[ "$RUN" == "--run" ]]; then
    open "$APP"
fi
