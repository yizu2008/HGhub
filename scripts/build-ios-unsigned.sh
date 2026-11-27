#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?Usage: build-ios-unsigned.sh VERSION}"
ROOT="$(pwd)"
LOG="$ROOT/ios-build-session.log"
ADDR_FILE="$(node -p "require('os').tmpdir() + '/' + require('./src-tauri/tauri.conf.json').identifier + '-server-addr'")"
mkdir -p artifacts
rm -f "$ADDR_FILE"

# Tauri 2.10.1 has no ios --no-sign flag. Keep its release options server
# alive for the generated Xcode 'Build Rust Code' phase instead.
pnpm tauri ios build --open --ci --features custom-protocol >"$LOG" 2>&1 &
SESSION_PID=$!
cleanup() {
  kill "$SESSION_PID" 2>/dev/null || true
  cat "$LOG"
}
trap cleanup EXIT
for ((attempt = 0; attempt < 180; attempt++)); do
  if ! kill -0 "$SESSION_PID" 2>/dev/null; then
    echo 'Tauri build session exited before becoming ready' >&2
    exit 1
  fi
  if [[ -s "$ADDR_FILE" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -s "$ADDR_FILE" ]]; then
  echo 'Timed out waiting for the Tauri build options server' >&2
  exit 1
fi

# 前端与图标必须在 xcodebuild 之前就位，不能指望 beforeBuildCommand：
# 后台的 `tauri ios build --open` 只起 options server，beforeBuildCommand
# （pnpm build）要等到 Xcode 的 "Build Rust Code" 脚本阶段才跑，而那个阶段
# 在 "Copy Bundle Resources" 之后 —— 资源拷贝发生时 gen/apple/assets 还是
# 空的，包里的前端就是空的；图标编译（actool）同样在脚本阶段之前。
# v0.0.11 就是这么打出空前端 + 模板默认图标的。
pnpm build
rm -rf src-tauri/gen/apple/assets
cp -R dist src-tauri/gen/apple/assets
node scripts/sync-ios-icons.mjs
node scripts/sync-ios-launch-screen.mjs
node scripts/sync-ios-status-bar.mjs
node scripts/sync-ios-background-audio.mjs
node scripts/sync-ios-file-sharing.mjs
node scripts/sync-ios-senplayer.mjs
node scripts/sync-ios-photo-library.mjs
# Python 运行时：下载 BeeWare xcframework 并暂存边车源码（gen/apple 里），
# 链接与装包分别在下面的 xcodebuild 参数与 --install-app 里。
node scripts/sync-ios-python.mjs

# Node 引擎：下载 nodejs-mobile xcframework 并暂存边车源码（gen/apple 里），
# 链接与装包分别在下面的 xcodebuild 参数与 --install-app 里。
node scripts/sync-ios-node.mjs

# mpv 原生 dylib（v0.0.142 起，替代 MPVKit）：已 vendor 在
# src-tauri/ios/mpv-dylibs/（mpv 0.41.0 + FFmpeg 8.1-dev 一代，
# 27 个，见该目录 README.md），xcodebuild 之后直接拷进
# .app/Frameworks/，选 mpv 播放时才 dlopen。主程序启动时完全不
# 碰 mpv（v0.0.124/125 静态链入后启动黑屏，126 摘掉就启动，
# 已证实是它），所以 OTHER_LDFLAGS 里不加 mpv 的库；Swift 代码
# 也不 `import Libmpv`（改 dlopen + dlsym）。OpenGLES 要链进主
# 程序：MPVEngine.swift 里 EAGLContext 与 GL 函数是直接调用的，
# 不是 dlsym（见上面 OTHER_LDFLAGS 的 -framework OpenGLES）。
# FFmpeg 这一代没有 SMB 支持，不再需要 smbc_stubs.c。
XCODE_TOOLCHAIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
test -d "$XCODE_TOOLCHAIN/usr/lib/swift/iphoneos"
xcodebuild build \
  -toolchain com.apple.dt.toolchain.XcodeDefault \
  -project src-tauri/gen/apple/huangguo-client.xcodeproj \
  -scheme huangguo-client_iOS \
  -configuration release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT/build_output" \
  TOOLCHAIN_DIR="$XCODE_TOOLCHAIN" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  FRAMEWORK_SEARCH_PATHS='$(inherited) $(PROJECT_DIR) $(PROJECT_DIR)/Python.xcframework/ios-arm64' \
  OTHER_LDFLAGS='$(inherited) -framework Python -framework SystemConfiguration -framework OpenGLES'

APP_DIR="$ROOT/build_output/Build/Products/release-iphoneos"
# 产品名改名后 .app 文件名会跟着变（改名前是 HGhub.app），不写死名字，
# 直接取构建产物里唯一的 .app，避免改名后找不到包。
APP_COUNT=$(find "$APP_DIR" -maxdepth 1 -name "*.app" -type d | wc -l)
if [ "$APP_COUNT" -ne 1 ]; then
  echo "Expected exactly one .app in $APP_DIR, found $APP_COUNT" >&2
  ls -la "$APP_DIR" >&2 || true
  exit 1
fi
APP=$(find "$APP_DIR" -maxdepth 1 -name "*.app" -type d)
EXECUTABLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")
test -s "$APP/$EXECUTABLE"
file "$APP/$EXECUTABLE" | grep 'Mach-O.*arm64'
# Avoid grep -q with pipefail: early pipe closure can hide a match.
strings "$APP/$EXECUTABLE" > "$ROOT/ios-binary-strings.txt"
if grep -F 'localhost:1420' "$ROOT/ios-binary-strings.txt"; then
  echo 'Refusing to package a development build' >&2
  exit 1
fi

# Python 运行时装包：标准库 + Python.framework + 边车源码进 .app，
# 再打 IPA 之前完成（.app 是每次现编的，装包步骤不可省略）。
node scripts/sync-ios-python.mjs --install-app "$APP"

# Node 引擎装包：NodeMobile.framework + 边车源码进 .app，
# 再打 IPA 之前完成。
node scripts/sync-ios-node.mjs --install-app "$APP"

# mpv 原生 dylib 装包：把 src-tauri/ios/mpv-dylibs/ 里的 27 个 dylib
# 原样拷进 .app/Frameworks/。启动时不加载，选 mpv 播放时 Swift 才
# dlopen libmpv.2.dylib（见 engines/MPVEngine.swift），其余 26 个
# 由 dyld 按 @rpath 依赖拉起。
# 校验：目录非空；每个都是 arm64 Mach-O dylib；install_name 是
# @rpath/<名>；libmpv.2.dylib 导出 _mpv_create 与 6 个 render API
# 符号（缺一个 Swift 那边 dlsym 就失败）。
MPV_DYLIBS="src-tauri/ios/mpv-dylibs"
DYLIB_COUNT=$(find "$MPV_DYLIBS" -maxdepth 1 -name "*.dylib" -type f | wc -l)
if [ "$DYLIB_COUNT" -ne 27 ]; then
  echo "mpv-dylibs 里应有 27 个 dylib，实际 $DYLIB_COUNT（清单见该目录 README.md）" >&2
  exit 1
fi
mkdir -p "$APP/Frameworks"
for dylib in "$MPV_DYLIBS"/*.dylib; do
  file "$dylib" | grep 'Mach-O.*arm64.*dynamically linked shared library' > /dev/null || {
    echo "mpv dylib 不是 arm64 Mach-O dylib：$dylib" >&2
    exit 1
  }
  name=$(basename "$dylib")
  if [ "$(xcrun -sdk iphoneos otool -D "$dylib" | tail -1)" != "@rpath/$name" ]; then
    echo "mpv dylib install_name 不是 @rpath/$name：$dylib" >&2
    exit 1
  fi
  cp -p "$dylib" "$APP/Frameworks/"
done
if ! xcrun -sdk iphoneos nm -g "$APP/Frameworks/libmpv.2.dylib" | grep ' T _mpv_create$' > /dev/null; then
  echo 'libmpv.2.dylib 未导出 _mpv_create' >&2
  exit 1
fi
for sym in _mpv_render_context_create _mpv_render_context_free _mpv_render_context_render _mpv_render_context_set_update_callback _mpv_render_context_update _mpv_render_context_report_swap; do
  if ! xcrun -sdk iphoneos nm -g "$APP/Frameworks/libmpv.2.dylib" | grep " T $sym\$" > /dev/null; then
    echo "libmpv.2.dylib 未导出 $sym" >&2
    exit 1
  fi
done
ls -lh "$APP/Frameworks/" | head -30

PACKAGE_DIR=$(mktemp -d)
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"
IPA="$ROOT/artifacts/HGhub_${VERSION}_ios.ipa"
(cd "$PACKAGE_DIR" && zip -qr "$IPA" Payload)
unzip -tq "$IPA"
ls -lh "$IPA"
