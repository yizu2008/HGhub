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

# MPVKit 28 个 LGPL 产物（静态库）：v0.0.127 懒加载——不再静态链进
# 主程序（v0.0.124/125 那样启动黑屏，126 摘掉就启动，已证实是它）。
# build.rs 只把 28 个产物的 ios-arm64 切片暂存到 gen/apple/MPVKit/
#（staging 在 xcodebuild 的 "Build Rust Code" 阶段跑），xcodebuild
# 之后、打 IPA 之前，本脚本用 clang -dynamiclib 把它们打成一个
# MPVKit.framework 动态库（smbc 空实现用 C 版 smbc_stubs.c 一起链
# 进去，自包含），嵌进 .app/Frameworks/，选 mpv 播放时才 dlopen。
# 主程序 OTHER_LDFLAGS 里不再加 MPVKit 的 -framework（启动零引用），
# Swift 代码也不再 import Libmpv（改 dlopen + dlsym）。
# smbc_*：LGPL 的 Libavformat 编译时开了 SMB 支持（libsmbclient.o 在
# 包里），但 Libsmbclient 本身是 GPL，不在 LGPL 产品里，所以这 22 个
# 符号没处链。不要为此链 GPL 的 Libsmbclient，smb:// 播放不支持。
# Tauri generates lowercase debug/release configurations. Using Release
# silently selected debug in the original workflow.
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
  OTHER_LDFLAGS='$(inherited) -framework Python -framework SystemConfiguration'

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

# MPVKit 懒加载：把 build.rs 暂存的 28 个静态库打成一个动态库
# MPVKit.framework，嵌进 .app/Frameworks/。启动时不加载，选 mpv
# 播放时 Swift 才 dlopen（见 engines/MPVEngine.swift）。
# 链接方式是普通静态库链接 + -u 指定 12 个入口符号：12 个
# mpv_* 函数是 dlsym 动态调用的、链接时无引用，-u 让链接器把
# 定义它们的各目标文件拉进来，其余按引用传递拉入。不要用
# -force_load 逐个加（v0.0.131 就是这么挂的）：FFmpeg 的
# vulkan.o 编进了 Libavfilter/Libavcodec/Libavutil 三份（同一批
# ff_vk_* 符号），GnuTLS 也自带了 OpenSSL 的 aes/sha/gcm 汇编
# 例程（与 Libcrypto 重复），force_load 全拉进来报 66 个重复符号；
# 普通链接按先定义者胜出，与 v0.0.124 静态链进主程序的成功方式一致。
# 维护注意：MPVEngine.swift 若新增 dlsym 的 mpv_* 函数，必须同步
# 加进下面的 -u 列表，否则 dylib 里没有它、运行时 dlsym 失败。
# smbc 空实现（src-tauri/ios/smbc_stubs.c）一起链进去：dlopen 那一
# 刻（chained fixups 下全部符号立即绑定）22 个 smbc_* 必须有着落。
# 校验：dylib 是 arm64 Mach-O；install_name 是
# @rpath/MPVKit.framework/MPVKit；无 __mod_init_func（有的话 dlopen
# 时会先跑构造器，挂起/崩溃就卡在选 mpv 那一步）；mpv_create 已定义
# （导出）；smbc_* 无未定义（空实现已链进）。
MPVKIT_STAGE="src-tauri/gen/apple/MPVKit"
MPVKIT_TMP="$(mktemp -d)"
IOS_SDKROOT="$(xcrun -sdk iphoneos --show-sdk-path)"
xcrun -sdk iphoneos clang -arch arm64 -target arm64-apple-ios15.0 \
  -isysroot "$IOS_SDKROOT" -c src-tauri/ios/smbc_stubs.c \
  -o "$MPVKIT_TMP/smbc_stubs.o"
mkdir -p "$MPVKIT_TMP/MPVKit.framework"
xcrun -sdk iphoneos clang -dynamiclib \
  -arch arm64 -target arm64-apple-ios15.0 -isysroot "$IOS_SDKROOT" \
  -install_name @rpath/MPVKit.framework/MPVKit \
  -o "$MPVKIT_TMP/MPVKit.framework/MPVKit" \
  -u _mpv_create -u _mpv_initialize -u _mpv_terminate_destroy \
  -u _mpv_set_option -u _mpv_set_option_string -u _mpv_command \
  -u _mpv_set_property -u _mpv_get_property -u _mpv_observe_property \
  -u _mpv_request_log_messages -u _mpv_wait_event -u _mpv_set_wakeup_callback \
  "$MPVKIT_STAGE/Libmpv.framework/Libmpv" \
  "$MPVKIT_STAGE/Libavdevice.framework/Libavdevice" \
  "$MPVKIT_STAGE/Libavfilter.framework/Libavfilter" \
  "$MPVKIT_STAGE/Libavformat.framework/Libavformat" \
  "$MPVKIT_STAGE/Libavcodec.framework/Libavcodec" \
  "$MPVKIT_STAGE/Libass.framework/Libass" \
  "$MPVKIT_STAGE/Libbluray.framework/Libbluray" \
  "$MPVKIT_STAGE/Libssl.framework/Libssl" \
  "$MPVKIT_STAGE/gnutls.framework/gnutls" \
  "$MPVKIT_STAGE/Libswscale.framework/Libswscale" \
  "$MPVKIT_STAGE/Libswresample.framework/Libswresample" \
  "$MPVKIT_STAGE/Libplacebo.framework/Libplacebo" \
  "$MPVKIT_STAGE/Libshaderc_combined.framework/Libshaderc_combined" \
  "$MPVKIT_STAGE/libMoltenVK.a" \
  "$MPVKIT_STAGE/Libdovi.framework/Libdovi" \
  "$MPVKIT_STAGE/Libdav1d.framework/Libdav1d" \
  "$MPVKIT_STAGE/Libuavs3d.framework/Libuavs3d" \
  "$MPVKIT_STAGE/Libharfbuzz.framework/Libharfbuzz" \
  "$MPVKIT_STAGE/Libfreetype.framework/Libfreetype" \
  "$MPVKIT_STAGE/Libfribidi.framework/Libfribidi" \
  "$MPVKIT_STAGE/Libunibreak.framework/Libunibreak" \
  "$MPVKIT_STAGE/lcms2.framework/lcms2" \
  "$MPVKIT_STAGE/Libcrypto.framework/Libcrypto" \
  "$MPVKIT_STAGE/nettle.framework/nettle" \
  "$MPVKIT_STAGE/hogweed.framework/hogweed" \
  "$MPVKIT_STAGE/gmp.framework/gmp" \
  "$MPVKIT_STAGE/Libavutil.framework/Libavutil" \
  "$MPVKIT_STAGE/Libuchardet.framework/Libuchardet" \
  "$MPVKIT_TMP/smbc_stubs.o" \
  -framework AVFoundation -framework CoreAudio -framework AudioToolbox \
  -framework CoreVideo -framework CoreFoundation -framework CoreMedia \
  -framework Metal -framework VideoToolbox \
  -framework QuartzCore -framework CoreGraphics -framework CoreText \
  -framework IOSurface -framework Foundation \
  -framework OpenGLES -framework UIKit \
  -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++
cat > "$MPVKIT_TMP/MPVKit.framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>MPVKit</string>
	<key>CFBundleIdentifier</key>
	<string>com.hghub.player.mpvkit</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MPVKit</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.41.0</string>
	<key>CFBundleVersion</key>
	<string>0.41.0</string>
	<key>MinimumOSVersion</key>
	<string>15.0</string>
</dict>
</plist>
PLIST
MPVKIT_DYLIB="$MPVKIT_TMP/MPVKit.framework/MPVKit"
file "$MPVKIT_DYLIB" | grep 'Mach-O.*dynamically linked shared library.*arm64'
if [ "$(xcrun -sdk iphoneos otool -D "$MPVKIT_DYLIB" | tail -1)" != '@rpath/MPVKit.framework/MPVKit' ]; then
  echo 'MPVKit dylib install_name 不是 @rpath/MPVKit.framework/MPVKit' >&2
  exit 1
fi
if xcrun -sdk iphoneos otool -l "$MPVKIT_DYLIB" | grep '__mod_init_func' > /dev/null; then
  echo 'MPVKit dylib 有 __mod_init_func（dlopen 时会跑构造器）' >&2
  exit 1
fi
if ! xcrun -sdk iphoneos nm -g "$MPVKIT_DYLIB" | grep ' T _mpv_create$' > /dev/null; then
  echo 'MPVKit dylib 未导出 _mpv_create' >&2
  exit 1
fi
if xcrun -sdk iphoneos nm -u "$MPVKIT_DYLIB" | grep '_smbc_' > /dev/null; then
  echo 'MPVKit dylib 还有未定义的 _smbc_（空实现没链进）' >&2
  exit 1
fi
mkdir -p "$APP/Frameworks"
cp -R "$MPVKIT_TMP/MPVKit.framework" "$APP/Frameworks/"
ls -lh "$APP/Frameworks/MPVKit.framework/MPVKit"
rm -rf "$MPVKIT_TMP"

PACKAGE_DIR=$(mktemp -d)
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$APP" "$PACKAGE_DIR/Payload/"
IPA="$ROOT/artifacts/HGhub_${VERSION}_ios.ipa"
(cd "$PACKAGE_DIR" && zip -qr "$IPA" Payload)
unzip -tq "$IPA"
ls -lh "$IPA"
