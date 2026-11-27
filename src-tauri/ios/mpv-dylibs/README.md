# mpv 原生 dylib（v0.0.142 起，替代 MPVKit）

这里是 mpv 0.41.0 + FFmpeg 8.1-dev 一代的原生 iOS 动态库，共 27 个，
合计约 39.1 MiB，全部单架构 arm64，install name 全是 `@rpath/<名>`。

## 来源

UZN 1.9.0 IPA（用户 2026-11-28 发来的下载链接）里 Frameworks/
的同款开源库：libmpv（mpv v0.41.0，GPL-2.0+）、FFmpeg（LGPL）、
libplacebo、libass、libdav1d 等。**这些是开源库的编译产物，不是
UZN 自己的代码**——UZN 没写 libmpv，它只是按 apple-mpv 系构建
脚本（路径含 `/Users/z/Documents/MyGit/apple-mpv/deps-buildscripts`）
把它们编出来、嵌进自己的包。红苹果把同一批开源库嵌进自己的包，
与之前用 MPVKit XCFramework（同一批库的另一种打包）没有许可上的
差别；UZN 自己的 Swift/Dart 代码一概没碰。

完整依赖闭包分析见 `~/workspace/tmp/uzn/DYLIB_CLOSURE.md`
（从 libmpv.2.dylib 出发的传递闭包：27/27 全在内，缺失 0 个）。

## 清单（27 个，全要搬，缺一个 dyld 就拒绝加载 libmpv）

libmpv.2.dylib（唯一入口）、libavcodec.63、libavdevice.63、
libavfilter.12、libavformat.63、libavutil.61、libplacebo.360、
libswscale.10、libswresample.7、libass.9、libdav1d.7、
libfontconfig.1、libfreetype.6、libfribidi.0、libharfbuzz.0、
libjpeg.62、liblcms2.2、libuchardet.0、libunibreak.7、libbs2b.0、
librubberband.3、libsharpyuv.0、libsoxr.0、libspeex.1、libwebp.7、
libwebpmux.3、libzimg.2。

## 要点

- MoltenVK 没有独立 dylib，已静态链入 libplacebo.360.dylib 与
  libmpv.2.dylib；构建参数含 `-Dvulkan=enabled -Dmoltenvk=enabled
  -Dplain-gl=enabled -Dios-gl=enabled`，即 Vulkan 与 OpenGL ES
  两条路都编译进去了——render API 用 gpu-api=opengl 没问题。
- FFmpeg 这一代没有 SMB 支持（libavformat 里无 _smbc_ 引用），
  所以不再需要 smbc_stubs.c（MPVKit 时代的空实现，已随 MPVKit 退役）。
- 这些 dylib 带有 UZN 的代码签名；本项目打的是未签名包（用户
  TrollStore 自签），装包时原样拷进 .app/Frameworks/ 即可，不用
  专门重签；若日后改签发布流程，Xcode 打包时会自动重签。
- 换版时重新算闭包（从 libmpv.2.dylib 出发，方法见
  DYLIB_CLOSURE.md），不要凭印象增删。
