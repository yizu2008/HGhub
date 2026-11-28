# iOS 原生播放器

WebView / HTML5 `<video>` + hls.js 仍是默认播放路径（`src/components/VideoSurface.tsx`
一动不动）。本文档只讲新增的四条原生路：AVPlayer、MDK、mpv、KSPlayer。
它们只在用户选了非 WebView 引擎且平台是 iOS 时启用，失败自动回落 WebView。

> 状态：桥已搭好，未在设备验证。**本机是 Linux，没有 Xcode / Swift 工具链，
> iOS 原生代码一行都没编译过**，也没有跑过真机。下面“Mac 验证”一节是必须
> 走完的清单，不要跳过。

## 架构

```text
React（Feed.tsx：详情页点选集自动打开 + 更多播放选项菜单里的“原生播放”入口）
  → src/plugins/nativePlayer.ts（invoke 封装 + addPluginListener 事件）
  → Rust 命令 src-tauri/src/native_player.rs
      native_player_open / close / play / pause / seek / set_rate / set_volume / state
  → Tauri 移动插件 "native-player"（lib.rs 注册）
  → Swift src-tauri/ios/Sources/NativePlayerPlugin.swift（统一 NativePlayerEngine 协议）
  → src-tauri/ios/Sources/engines/ 下四个引擎适配（原生全屏 present，退出时发回事件）
  → 前端收到 native-player-time / -ended / -error / -closed 后回写进度、回落 WebView
```

取流：四个引擎都直接播 Rust `media.rs` 给的本地回环地址
`http://127.0.0.1:{port}/hpp/{id}/{index}?v={version}`，上游头、Range、
密钥都由 Rust 代理处理，原生侧不拼头、不改地址、不碰 HPP 会话逻辑。
`PreparedMedia` 的形状、会话 / 刷新 / 资源归属一律没改（协议 09 章不动）。

编译方式（SPM + SwiftLinker，官方插件同款）：`src-tauri/ios/` 是
一个 SPM 包（`Package.swift`，包名 `NativePlugins`，含
`NativePlayerPlugin` 与 `OrientationPlugin` 两个插件、同一个 Swift
模块）。`src-tauri/build.rs` 在 macOS 上为 iOS target 构建时，先把
tauri 的 iOS Swift API（`DEP_TAURI_IOS_LIBRARY_PATH`）拷到
`src-tauri/.tauri/tauri-api`（构建产物，不进版本控制），再调
`tauri_utils::build::link_apple_library("NativePlugins", ios-dir)`，
由 swift-rs 以 `swift build` 编成静态库链进 Rust。**Xcode 不编译
这些文件**——不要再把它们拷进 `gen/apple/Sources`，那样会与静态
库重复定义 `init_plugin_*` 符号。v0.0.8 之前走的就是拷进 Xcode 的
路线，死在 `import Tauri`：Tauri 的 iOS Xcode 模板里根本没有 Tauri
Swift 模块，无论是否重跑 xcodegen 都编不过（v0.0.5–v0.0.8 的教训：
Rust 编不过 → 同步脚本 → xcodegen 重生成 → cdylib 链接缺符号 →
Xcode 下 `import Tauri` 找不到模块）。

链接说明：`src-tauri/Cargo.toml` 的 `[lib] crate-type` 含 `cdylib`，
而 Swift 插件符号只由 SwiftLinker 编 Swift 包时才产生，cargo 在
Xcode 的 Build Rust Code 阶段链接 cdylib 时它们还不存在。仓库根目
录的 `.cargo/config.toml` 给两个 iOS target 加了
`-C link-args=-Wl,-undefined,dynamic_lookup`，让这次链接允许未定义
符号（最终 App 链接的是 staticlib + SwiftLinker 编出的 Swift 对象，
符号在那里解析；cdylib 在 iOS 上只是构建副产物）。Android / 桌面
构建不受影响。Swift 包里两个插件的 Swift 入口函数名必须不同
（`initNativePlayerPlugin` / `initOrientationPlugin`），`@_cdecl` 的
C 符号名（`init_plugin_native_player` / `init_plugin_orientation`）
保持不动——同一模块内同名同签名是非法重声明。

## 引擎选择

存在 store 的 `playbackEngine`（localStorage `hpp.playbackEngine`），
默认 `"webview"`。可选：`webview`、`avplayer`、`mpv`、
`auto`。v0.0.146 起 MDK / KSPlayer 不再出现在选择里：依赖没装，
点了只会报“未接入”；引擎替身代码还在，装好依赖再加回来。
设置页已接：`src/plugins/ApplicationSettings.tsx` 的“播放”区有
“播放内核”选择器，只在 iOS 显示，非 iOS 平台不显示（原生引擎只支持 iOS）。

`auto` 的 fallback 链（`src/plugins/playbackEngine.ts`，纯函数）：
AVPlayer → mpv → 回落 WebView。
指定某个引擎时只试它，失败也回落 WebView。

选引擎有两个入口，共用同一个 store（`playbackEngine` /
`setPlaybackEngine`，与设置页选择器同一套）：设置页“播放”区的
“播放内核”选择器，和播放页“更多播放选项”菜单里的“播放内核”
选择行。菜单只在 iOS 显示。v0.0.147 起：详情页上所选内核不是
WebView 时，点选集直接按所选内核开原生（`Feed.tsx` 的自动打开，
只在详情页生效，首页预览卡片仍内嵌 WebView）；选了新引擎不切
当前播放，下次选集或点菜单里的“原生播放”时才按新引擎打开。
播放画面右上角不再放“原生播放”pill（v0.0.22 删掉），手动入口
只在更多菜单里。

## 四个引擎

| 引擎 | 格式 | 许可证（发行前必读） | 接入方式 | 已知限制 |
| --- | --- | --- | --- | --- |
| AVPlayer | H.264/HEVC + MP4/HLS | 系统自带，无许可证问题 | 零依赖，`AVPlayerViewController` 全屏 | 不吃 MKV/FLV/WebM/VP9/AV1，不支持 DASH，ASS 只能走 HLS 内嵌字幕 |
| MDK | FFmpeg 底，格式宽，ASS 需可选 `ass.framework` | key 制：开源 / 非商业免费，找作者申请 key；无 key 且 SDK 过期时最后一帧可能出现二维码水印 | CocoaPods `pod 'mdk'` 或 SPM `swift-mdk` | key 要另外申请；`setDecoders` 目前配 `VT / FFmpeg / dav1d` |
| KSPlayer | AVPlayer + FFmpeg，HDR / Dolby Vision / Atmos 好 | **默认 GPL-3.0，要求开源自家代码**；HGhub 是 PolyForm Noncommercial，**不能直接按 GPL 发行**；完整格式 / 全量 ASS / AV1 硬解 / FFmpeg 8.1 在付费 LGPL 版（联系 kingslay@icloud.com），免费 GPL 版是 FFmpeg 6.1.0 且功能受限 | SPM `kingslay/KSPlayer`，`KSOptions.secondPlayerType = KSMEPlayer.self` 切 FFmpeg 路 | 没拿到付费 LGPL 之前不要用它发正式包 |
| mpv（libmpv） | 格式 / ASS 最强 | libmpv 是 GPL-2.0+、FFmpeg 是 LGPL——与 MPVKit 时代同一批库的另一种打包，发行口径不变（见下）；不要用含 Samba 的 GPL 全量版 | 已接：原生 dylib（`src-tauri/ios/mpv-dylibs/`，mpv 0.41.0 + FFmpeg 8.1-dev 一代，27 个），v0.0.142 起替代 MPVKit。渲染走 libmpv render API + EAGLContext（OpenGL ES），vo=libmpv（必须是 libmpv：render API 的 VO 驱动名就是它，写 gpu-next 会让播放核另建独立 gpu-next VO、去探 vulkan/MoltenVK 要 WinID 而建不起来，143 真机就是这么死的）+ hwdec=videotoolbox-copy（v0.0.145 起：直接 videotoolbox 会发绿，见下；硬解/软解由硬件加速开关控制，v0.0.146）。0.41.0 起最低 iOS 14.0（应用保持 iOS 14.0 底线，macOS 11） | 最难编，包体最大；render API 在 iOS 上要自己管 GL 上下文与 FBO |

当前实现状态：

- **AVPlayer 已完整实现**：`engines/AVPlayerEngine.swift`，起播、续播、进度观察、
  结束 / 失败回调、Done 关闭回传都有。
- **MDK / KSPlayer 是 `canImport` 守卫**：依赖装了走 `#if` 分支的真实调用，
  没装走 `#else` 分支——`open` 直接失败，报错里写清缺哪个依赖、怎么装，
  不留“能打开但播不了”的空实现。`#if` 分支里的方法名是按各家 README 所写，
  第一次在 Mac 上编时以接入的依赖版本为准在构建时校验（见下）。
- **mpv 已接线（懒加载，真机已测：v0.0.145 画面正常、有声、双扬声器；
  v0.0.146 起有原生控制层）**：
  原生 dylib（v0.0.142 起，`src-tauri/ios/mpv-dylibs/`，mpv 0.41.0 +
  FFmpeg 8.1-dev 一代，27 个，替代 MPVKit），
  `engines/MPVEngine.swift` 不 `import Libmpv`，改在用户选 mpv 点播放
  时 `dlopen` libmpv.2.dylib + `dlsym`（见下）。调用的还是同一套
  libmpv C API（`mpv_create` / `mpv_initialize` / `loadfile` /
  `seek` / `pause` / `speed` / `volume` / `time-pos` / `duration` /
  `dwidth` / `dheight`，事件走 `mpv_set_wakeup_callback` +
  `mpv_wait_event` 排空），渲染改走 libmpv render API
  （`mpv_render_context_*`）+ EAGLContext（OpenGL ES 3.0，不行就
  2.0）：App 自己建 FBO/颜色 renderbuffer，mpv 发新帧通知时在渲染
  线程上 `mpv_render_context_update()` + `mpv_render_context_render()`
  画进 FBO 再上屏。注意这套库里没有 `MPVPlayer` / `MPVGLView`
  （那是另一个 libmpv-ios 项目的包），旧代码里按它们写的分支已经删掉。
  懒加载（v0.0.127 起，v0.0.142 换 dylib）：v0.0.124/125 把 MPVKit
  28 个 LGPL 产物静态链进主程序后启动黑屏（无 .ips、无 JetsamEvent），
  v0.0.126 摘掉就启动，证实是它；机制未明（无静态初始化器、符号与
  链接库都查过无问题），但实证已足够。所以 mpv 的库不再进主程序：
  27 个 dylib 只拷进 `.app/Frameworks/`（`scripts/build-ios-unsigned.sh`
  在 xcodebuild 之后拷，校验见下），`MPVEngine.swift` 在 open 入口
  才 dlopen（全路径 `Frameworks/libmpv.2.dylib`，`RTLD_LAZY |
  RTLD_GLOBAL`，必须用懒绑定——libbs2b.0.dylib 有个未定义符号
  `_rpl_malloc`（gnulib 的 malloc 替代），27 个 dylib、UZN、系统
  库里都没人提供它，正常播放也不会调到 bs2b（只在 FFmpeg 的
  bs2b 音频滤镜里）；RTLD_NOW 会立即绑定全部符号，v0.0.142 真
  机 dlopen 直接失败，而 UZN 主程序启动直链 libmpv、dyld 默认懒
  绑定所以没事）并 dlsym 出 18 个 libmpv 函数（12 个核心 + 6 个
  render API，缺一个就整体失败，报 unavailable、播放链回落
  AVPlayer/WebView）；不 dlclose，进程生命周期内常驻。主程序里没
  有任何 mpv 符号，启动与 126 完全一致。dylib 的 install_name 全是
  `@rpath/<名>`，靠主程序 rpath（`@executable_path/Frameworks`）
  解析，不用改。libmpv 的常量与结构体布局按 mpv 0.41.0 的
  `client.h` / `render.h` / `render_gl.h` 在 Swift 里手写
  （`MPV_FORMAT_*` / `MPV_EVENT_*` / `MPV_END_FILE_REASON_*` /
  `mpv_event` / `mpv_event_property` / `mpv_event_end_file` /
  `mpv_render_param` / `mpv_opengl_init_params` / `mpv_opengl_fbo`），
  改版先核对头文件——0.41.0 与 0.40.0 的常量与核心结构体已逐项比
  对过（API 2.5），完全一致；0.41.0 的头文件在上游改了位置
  （`libmpv/client.h` → `include/mpv/client.h`），装好的路径仍是
  `mpv/client.h`。`MPV_END_FILE_REASON_ERROR = 4`（不是 3），
  `mpv_event_end_file` 的 `playlist_entry_id` 是 int64_t（旧版是
  const char*）。render API 的参数数组以 type==0（INVALID）结尾；
  `mpv_render_context_create` 必须在 GL 上下文是当前时、在渲染线程
  上调；`mpv_render_context_free` 必须在 `mpv_terminate_destroy`
  之前调。`FLIP_Y=1`（iOS 上画进 FBO 要翻一次，见 render_gl.h 的
  说明与真机画面方向）。
  例外是 MoltenVK：UZN 这套库里没有独立的 MoltenVK dylib，它已静态
  链入 libplacebo.360.dylib 与 libmpv.2.dylib；构建参数含
  `-Dvulkan=enabled -Dmoltenvk=enabled -Dplain-gl=enabled
  -Dios-gl=enabled`，即 Vulkan 与 OpenGL ES 两条路都编译进去了，
  render API 用 gpu-api=opengl 没问题（142 的选择；vulkan 路留给
  wid，不再用）。
  系统库：dylib 依赖的系统 Framework 与系统库（AVFoundation、
  CoreAudio、AudioToolbox、CoreVideo、CoreFoundation、CoreMedia、
  Metal、VideoToolbox、AVFAudio、Accelerate、Security、IOSurface、
  UIKit；bz2、iconv、expat、z、c++）由主程序链接——MPVEngine.swift
  直接调 EAGLContext 与 GL 函数，所以主程序必须链 OpenGLES
  （`build-ios-unsigned.sh` 的 xcodebuild OTHER_LDFLAGS 里已加
  `-framework OpenGLES`）。
  smb：这一代 FFmpeg 没有 SMB 支持（libavformat 里无 `smbc_*`
  引用），不再需要空实现；`src-tauri/ios/smbc_stubs.c` 已随 MPVKit
  退役删掉。smb:// 播放不支持。
  维护注意：`MPVEngine.swift` 若新增 dlsym 的 mpv_* 函数，直接加进
  `MPVAPI` 的 dlsym 表即可（不再有 `-u` 列表——dylib 是现成的，不用
  链接器拉符号）。换版时从 libmpv.2.dylib 出发重算 27 个的闭包
  （方法见 `src-tauri/ios/mpv-dylibs/README.md`），不要凭印象增删。
  打包时校验：目录里是 27 个 dylib；每个都是 arm64 Mach-O dylib；
  install_name 是 `@rpath/<名>`；libmpv.2.dylib 导出 `_mpv_create`
  与 6 个 render API 符号。
  硬解用 videotoolbox-copy（v0.0.145）：直接 videotoolbox 时，iOS 的
  VideoToolbox→OpenGL 互操作（mpv `hwdec_ios_gl.m`）把 UV 平面建成
  GL_LUMINANCE_ALPHA（ES3 下 texture cache 拒 GL_RG、报 -6683），
  libplacebo 按 RG 采样，V 读成了 U，144 真机画面整体发绿；copy 版
  把帧拷回系统内存再上传，绕过这条互操作，仍是硬件解码。硬解/软解
  只由硬件加速开关控制（v0.0.146，见下）：开 = videotoolbox-copy，
  关 = hwdec=no；8 秒自动切软解回退（v0.0.142 起，UZN 的做法）已取消。
  DV 那条没搬：mpv 0.41.0 源码里没有 `--dolby-vision-profile` 这个选项，
  UZN 的 MPVForceDolbyVisionProfile5 是它自己的逻辑、静态看不出
  它到底改了 mpv 哪个设置，没法照搬；DV 片硬解播不了时，把硬件加速
  开关关掉走软解。
  真机播放（v0.0.133/134 的结论已收回，2026-11-27）：那几次点的
  都是选集、走 WebView 内嵌播放，mpv 一次都没跑起来——“有声、进度
  走、画面全黑”是 WebView 硬解失败的老问题，不是 mpv 的表现；134
  的先 present 后 initialize 改动本身保留，但“初始化顺序不是原因”
  这个结论没有真机证据支撑。mpv 第一次真正跑起来是 138 的重测，
  见下。
  诊断（v0.0.135 起，v0.0.137 起改走 state 命令）：`MPVEngine` 常开
  mpv 日志 info 级（`mpv_request_log_messages(handle, "info")`）。
  135/136 曾把 `MPV_EVENT_LOG_MESSAGE` 经 `native-player-log` 事件发
  回前端、写进运行日志（`[mpv] 前缀: 内容`），但 136 真机证实这条
  事件到不了前端；137 起改走 `native_player_state` 回包里的
  `mpvLogCount` / `mpvLogLines` / `mpvEventLoopAlive`，前端轮询读出
  来写进运行日志（见下）。mpv 自己的 VO/swapchain 报错只有这里能看到；
  黑画面先看运行日志里的这几行，再定下一步。
  135 真机（2026-11-27）：播了 12 秒，`[mpv]` 行一行都没出来——但
  那次测试同样走的 WebView（同上），“日志链路在注册之后断了”这个
  结论收回；138 真机重测第一次真正跑起 mpv，日志行数仍是 0——日志
  通道本身是哑的，原因还没查清，见 139。`addPluginListener`
  注册时有 camelCase fallback（先试下划线 `register_listener`，被
  拒改试驼峰 `registerListener`，权限文件里写的正是驼峰），所以注
  册成功；`unregister()` 没有 fallback，只调下划线，所以注销被拒。
  ACL 修法（v0.0.136）：两处 toml 的 `commands.allow` 改下划线
  （`["register_listener"]` / `["remove_listener"]`），`default.json`
  不用动；`scripts/check-acl.mjs` 也改成下划线期望串——它以前硬编
  码驼峰去比对 toml，查的是自洽，不是运行时真正调的名字，所以脚本
  PASS、真机拒。以后新增 dlsym 的 mpv_* 函数、新增监听权限，都按
  运行时名（下划线）写。
  136 真机（2026-11-27，pid 11449）：播了 24 秒，三行 `[diag]` 一行都没
  出来、`[mpv]` 行也没有，但退出时 5 连 `[reject] remove_listener`
  消失了——ACL 修法生效。open 标记是同步发的、不经过事件循环，它都没
  来，所以不是事件循环的问题：**`.log` 事件本身到不了前端**，事件循环
  假说收回（`.time` 的进度条是 Swift 侧 UI，不能证明事件到了前端）。
  诊断改走 state 命令（v0.0.137 起）：`MPVEngine` 把 mpv 日志留最近
  30 行 + 总行数 + 事件循环是否跑起来过，放进 `NativePlayerState`
  的 `mpvLogCount` / `mpvLogLines` / `mpvEventLoopAlive`；前端
  （`Feed.tsx` 的 `startMpvDiagPoll`）只在 mpv 播放时每秒轮询
  `native_player_state`，把新增行写进运行日志（`[mpv] 前缀: 内容`），
  事件循环活了写一行 `[mpv] [diag] event loop alive`，关闭时写一行
  `[mpv] [diag] mpv closed, N log lines received`。读法：轮询到
  `mpvEventLoopAlive` 为真 → 事件循环在跑；`[mpv]` 行里找 VO 报错；
  若一行 `[mpv]` 都没有且计数恒为 0 → mpv 没发日志或 state 通道本身有问题。
  137 真机（2026-11-27，pid 11698，版本号已确认 0.0.137）：getDetail +
  resolvePlayback 完成，随后 23 秒零行——`[mpv]`、`[diag]` 一行都没出，
  轮询静默失败，分不清是轮询没跑、state 被拒还是循环真死。另：同次测试
  播完闪退一次（无 `[panic]` 行，pid 11710 重启），与 18:56:53 的 tao
  AppState 崩溃（第 6 次）是两回事。教训：轮询把失败静默吞了（`.catch(() => {})`），
  state 命令全 App 只有轮询在调，真机上从没走通过。
  诊断可见性（v0.0.138 起）：轮询第一次成功写一行
  `[mpv] [diag] state poll ok, count=N, loopAlive=<bool>`，第一次失败写一行
  `[mpv] [diag] state invoke failed: <err>`；`openNative` 成功时写一行
  `[diag] native player opened, engine=<engine>`，先分清 mpv 到底打开没有。
  138 真机重测（2026-11-27，pid 12401，版本号已确认 0.0.138）：详情页 →
  更多播放选项 → 原生播放，mpv 第一次真正跑起来：`[diag] native player
  opened, engine=mpv`，随后 `state poll ok, count=0, loopAlive=true` +
  `event loop alive`。但约 19 秒黑屏、无声、进度条不动，mpv 日志行数
  一直是 0，也没有播错/播完回落；同会话 12:15:00 第 7 次 tao AppState
  崩溃。结论：mpv 初始化成功、loadfile 已排队，但播放没启动；日志
  通道本身是哑的，靠日志行定位到此为止。
  诊断（v0.0.139 起）：不再只靠 mpv 日志行。`NativePlayerState` 增加
  `mpvIdleActive`（idle-active）、`mpvVoConfigured`（vo-configured）、
  `mpvPausedForCache`（paused-for-cache）、`mpvEventsDrained`（事件循环
  累计排空的事件数）、`mpvOpenDiag`（`init=<rc> loadfile=<rc>
  url=<scheme>://<host>`，只记 scheme/host，不记 path/query）；Rust 侧
  同名 camelCase 字段透传（`native_player.rs`，`#[serde(default)]`）；
  前端轮询每秒写一行 `[mpv] [diag] state pos=… dur=… playing=…
  idle=… vo=… cachePaused=… w=… h=… drained=… count=…`。读法：`vo=false`
  → VO 没配起来（看 gpu-next/MoltenVK）；`idle=true` 且 `drained` 在涨
  → mpv 空闲、事件在走，loadfile 没起播；`drained` 不涨 → wakeup 之后
  事件不再来；`cachePaused=true` → 在等缓冲；`pos` 走但画面黑 → 解码/
  渲染问题，不是没起播。vo 配置 139 没改，先看清卡在哪一步再定。
  139 真机结论（2026-11-27 20:52，pid 12625）：init/loadfile 均返回 0，
  mpv 拿到回环代理地址，随后 17 秒状态行全同（`pos=0.00 dur=0.00
  playing=true idle=false vo=false w=0 h=0 drained=4 count=0`）——解复用
  器一直没打开文件，视频轨从没到渲染层；黑屏卡在流打开/解复用一步，不
  是渲染/解码问题。同会话 12:52:19 第 8 次 tao AppState 崩溃。
  AVPlayer 对照（2026-11-27 21:13–21:14，pid 12798，设置确认内核为
  AVPlayer）：`native player opened, engine=avplayer` 三次，均黑屏、无声、
  00:00——AVPlayer 原生也打不开同一集，不是 mpv 专属问题。
  同一集对照（2026-11-27 21:23–21:31）：21:23 同一集点选集走 WebView 内嵌
  也加载不了（“视频暂时无法加载”）；21:27 换《庄园保姆》第 1 集（夸克
  原画）内嵌有画面、进度走——App、代理、猫源正常；21:29 玩偶 4K 短剧又
  可以播；21:31 同一部片跳转 SenPlayer（软解）又可以播。结论：这条夸克
  原画线当时断了（21:05–21:23），21:27 后恢复；线通后硬解（WebView/
  AVPlayer）始终无画面、软解能播，原画很可能是 AV1 或杜比 P7。所以 139
  的“解复用器没打开”首先是线死了，未必是 mpv 解不了。
  mpv 验过（2026-11-27 21:49–22:00）：短剧《前尘尽，许我快意恩仇》第 1
  集、其它非短剧影视，mpv 原生播放都有画面——mpv 引擎本身可用。但好线
  上重测《疯狂魔幻西哥》原画#01（2026-11-27 22:05）仍播不了，而 UZN
  v1.8.0（另一猫源壳）同一猫源同一文件（[2.2GB]Loco.Mexico.Magico.2026.
  1080p，1920×800，1:44:49）用 mpv 内核播出画面、进度走。文件、线、mpv
  本身都没问题，问题在我们 mpv 的配置。
  诊断（v0.0.140 起）：mpv 改纯软解试播——`hwdec` 由 `videotoolbox` 改
  `no`，正式版日志级由 `info` 改 `debug`（139 真机测时 info 级 0 行，解
  复用器探流、选解码器那几行只在 debug 级才有）。不是最终产品形态：若
  纯软解能播，就是硬解接手卡住不回落的问题，再定修法（自动回落或加硬
  件加速开关）；若仍播不了，看 debug 日志卡在哪一步。vo 配置（gpu-next/
  vulkan/moltenvk）140 没改。
  升版（v0.0.141 起）：MPVKit 0.40.0-xcode → 0.41.0 exact。0.41.0 没
  有 -xcode 变体；38 个产物与 0.40.0-xcode 同名同数，LGPL 闭包仍是
  28 个，`build.rs` 的清单与 `build-ios-unsigned.sh` 的链接表不用改，
  只改框架 Info.plist 里的版本号（0.40.0 → 0.41.0）。iOS 底线 13 →
  14、macOS 底线 10.15 → 11（0.41.0 的要求）；mpv 官方最新是 0.42.0
  （2026-11-05），但 MPVKit 最新版（1.1.0-n9.0.2）里仍是 mpv 0.41.0，
  0.41.0 是目前能升到的最新。141 只升版本：hwdec 恢复 videotoolbox，
  日志保持 debug 级——140（0.40.0 纯软解）与 141（0.41.0 硬解）对照：
  141 能播就是版本修好了硬解，141 不行而 140 行就是硬解配置的问题，
  与版本无关。client.h 已核对：常量与四个结构体与 0.40.0 完全一致
  （API 2.5），Swift 代码不用改。

## Mac 验证（按顺序）

```bash
# 1. 在 Mac 上取代码（fork / 分支同底部白条补丁的流程）
git clone <你的 fork> HGhub && cd HGhub
pnpm install --frozen-lockfile

# 2. 生成 iOS 工程（Swift 插件不用同步，build.rs 在构建时自己处理）
pnpm tauri ios init --ci
# Swift 插件是 SPM 包：cargo 构建时 build.rs 把 tauri 的 iOS Swift API
# 拷到 src-tauri/.tauri/tauri-api，再经 SwiftLinker 编成静态库链进
# Rust。不要把 Swift 文件拷进 gen/apple/Sources，也不要重跑 xcodegen
# 收录它们——那样会与静态库重复定义 init_plugin_* 符号。

# 3. 按要测的引擎装依赖（AVPlayer 零依赖，跳过这步就能先测桥）
#    MDK：CocoaPods pod 'mdk' 或 SPM swift-mdk，并向作者申请 key
#    KSPlayer：SPM kingslay/KSPlayer（先确认 LGPL 授权，见上表）
#    mpv：在 Mac 上编 Libmpv.xcframework，或 SPM 加入 MPVKit（LGPL 版）

# 4. 打未签名 IPA（仓库现有脚本，不用改）
bash scripts/build-ios-unsigned.sh 0.0.4

# 5. 真机（TrollStore 或自签名）安装后逐项测：
#    - 设置 playbackEngine 为 avplayer，播 HLS/MP4，确认全屏、进度、Done 后回落 WebView
#    - 播一个 AVPlayer 不支持的格式，确认 auto 链 fallback 到下一个引擎或 WebView
#    - 再逐个测 MDK / KSPlayer / mpv（各依赖装好后）
#    - 方向：播横屏视频（16:9）自动转横屏，播竖屏视频自动回竖屏；
#      点控制条的旋转按钮手动切到反面，本集内不再自动改回；切集后
#      回到按分辨率自动；退出播放页后恢复竖屏。手动旋转成功时应有
#      “已切换到横屏/竖屏”提示，失败时应有“无法切换屏幕方向”提示。
#      若仍不转：先确认 `src-tauri/gen/apple` 里窗口根视图控制器
#      有没有重写 supportedInterfaceOrientations 限制方向（本地
#      查不到，gen 目录是 CI 生成的、不进版本控制），再看 Swift
#      侧 requestGeometryUpdate 是否被 reject。
```

## 本机能验证的

- `pnpm run build`（tsc + vite）通过。
- `cargo check --manifest-path src-tauri/Cargo.toml` 通过（host check；
  `cfg(target_os = "ios")` 的代码只要求语法解析通过）。
- `cargo check --target aarch64-linux-android` 通过（build.rs 里
  macOS 以外的部分、拷贝辅助函数、Cargo.toml 的新 build-dependency
  都能在这步验证；macOS 专属的 SwiftLinker 调用是 `#[cfg]` 门控的，
  Linux 上编不出来）。
- Swift 文件**未编译**（本机无 swiftc / Xcode），上面 Mac 清单跑完之前，
  不要写“iOS 编译通过”或“真机验证通过”。

## 分辨率显示（播放时）

- WebView 路：`VideoSurface` 的 `onSize` 已回传 `videoWidth/videoHeight`，
  `Feed.tsx` 在播放画面标题栏下方叠一个角标（`1920×1080` 这种格式，
  顶边 + 安全区 + 96px），拿到尺寸才显示，未知时隐藏；起播后显示
  3 秒自动消失，切集重开一个 3 秒窗口。首页预览卡片上右上角的
  “原生播放”pill 已删（v0.0.22），角标仍是左上角那一个，3 秒行为不变。
- 详情页（full 模式，仅 iOS，v0.0.25）：同一位置改成左右两个角标，
  竖屏时分辨率在左、当前播放内核在右（store 的 `playbackEngine`，即设置页/
  更多菜单里选的那个），同款式、左右按横向安全区（`--sal`/`--sar`）
  留白；横屏时分辨率改到播放内核上面（右侧上下叠放，v0.0.32，用户
  2026-11-22 09:45 要求，横屏左边的角标还会被左沿裁掉，叠到右边也
  顺带避开了）。显隐跟控制条同显同隐（移动端清屏或锁定即隐藏，桌面闲置
  即隐藏，暂停/面板打开时仍显示），起播/切集后的 3 秒窗口内也短暂
  显示一次。首页预览卡片的 3 秒角标与清屏浮层不受影响。
- 原生路：`NativePlayerState` 与 `native-player-time` 事件都带
  `videoWidth/videoHeight`（0 表示未知）；`AVPlayerEngine` 用
  `AVPlayerItem.presentationSize` 取真实尺寸，在
  `AVPlayerViewController.contentOverlayView` 右上角下方（顶边 +72px）
  叠同款角标，每 0.5s 的进度回调里刷新一次，HLS 切清晰度时能跟上；
  同样起播后显示 3 秒自动消失。
  键名对齐（v0.0.39 修过）：Swift 的 `NativePlayerState` 无
  CodingKeys，编码后键名是 Swift 属性名（`videoWidth` 驼峰）；Rust
  侧 `NativePlayerState` 必须用 `serde rename_all="camelCase"` 对齐。
  v0.0.38 之前 Rust 侧没加，`run_mobile_plugin_async` 解回包时报
  `missing field 'video_width'`——7 个返回 state 的原生播放命令
  （open/play/pause/seek/set_rate/set_volume/state）全都一样坏。
  回包解不到不代表没播：Swift 侧在 open 完成回调里先 present 再
  resolve，播放器已经弹出来了，只是 invoke 的 Promise 被拒，下载
  管理点播时就显示报错横条（v0.0.37 的“播放失败”、v0.0.38 的真实
  报错都是它）；更多菜单的“原生播放”入口同样受影响。修法是一行
  属性 + 一个 serde 往返单元测试（`native_player.rs`）。
  MDK / KSPlayer 的 `videoSize` 目前返回 `.zero`（未接各家
  的尺寸 API），角标按未知隐藏，等 Mac 上接依赖时再按各家 API 补。
  mpv 已接 `dwidth` / `dheight`，报真实尺寸。
- 真机验收时加一项：播 HLS/MP4 看角标是否出现、数值是否与实际
  清晰度一致、3 秒后是否自动消失；切集后角标是否跟着变。

## 首页清屏信息浮层（v0.0.23，仅 iOS 预览卡片）

- 手势：单击切换清屏（隐藏/恢复全部界面控件，只留视频），双击在
  非清屏时切换暂停/播放；**已清屏时双击改为唤醒/关闭信息浮层，
  不暂停播放**。单击的 250ms 延迟计时器在第二下点按时被取消，
  所以一次双击不会触发两次单击的清屏切换。播放详情页（full
  模式）双击仍是暂停/播放，不受影响。
- 浮层内容（`Feed.tsx`，与 3 秒角标同款式，顶边 + 安全区 + 96px）：
  左边是分辨率（与 3 秒角标同一位置），右边对称显示当前播放内核
  （store 的 `playbackEngine`，即设置页/更多菜单里选的那个）；
  下方一行只有“复制播放地址”按钮（v0.0.24：地址文字本身不再显示，
  点按复制当前视频的真实播放地址 `media.url`，成功提示按当前是否
  在播区分——播着时“已复制，播着时切出可用”，暂停时“已复制，须先
  播放再切出”，播着且静音时“已复制，须先取消静音再切出”（v0.0.32，
  见下面“后台音频”一节）；旁边一个旋转按钮，复用 v0.0.22 的方向机制
  与“已切换到横屏/竖屏”提示。竖屏时两行左右按横向安全区（`--sal`/
  `--sar`，`index.css` 定义，竖屏时等于 12px）留白；横屏时左边两行改取
  固定 230px：v0.0.24 以为横屏刘海侧安全区约 44px 是错的——实测本机
  WKWebView 里横屏的 `env(safe-area-inset-left)` 是 0，`--sal` 只剩
  12px，角标仍贴在左边缘（v0.0.28 真机截图测量：分辨率文字左沿约
  25pt，pill 左沿约 13pt）；230px 是用户横屏截图上红框的左沿位置，
  从该位置起落在视频区内。右边内核 pill 不动，仍按 `--sar` 留白。
- 显隐：双击唤醒，再双击关闭；15 秒无操作自动消失（复制地址或
  点旋转会续 15 秒，3 秒不够点到复制）；切集、退出清屏、切模式时
  关闭。浮层打开时 3 秒角标隐藏，避免两者在左上角同一位置重叠。
- 复制：`navigator.clipboard.writeText`（WKWebView 里需用户手势，
  点按即满足），不可用时走 textarea + `execCommand("copy")` 兜底，
  失败提示“复制失败”，不静默。复制的地址是本机回环地址
  （`http://127.0.0.1:<端口>/hpp/<会话>/<资源>?v=<版本>`，`media.rs`
  的 `MediaSessions::start` 在应用内起的本地服务器）。它能不能在
  浏览器里打开，取决于切出时本应用进程还活不活——v0.0.29 曾写成
  “切出就失效”，是错的：用户在蚂蚁影视里的录像证实，视频播着的
  时候切到浏览器、粘贴同样的回环地址（`127.0.0.1:10010/hg.mp4?…`），
  能播；v0.0.28 里 HGhub 复制后打不开，是因为那次录像里视频是暂
  停的——暂停时切出去，iOS 立即挂起进程，服务器停止响应，浏览器
  一直白屏加载。差别在播/停，不在地址格式。v0.0.30 起用后台音频
  保活（见下一节），用法是：播着的时候复制、切出，浏览器里能播；
  暂停时复制、切出，照样打不开。浮层容器本身不接指针事件，只有
  复制行与旋转按钮可点，其余点按仍走视频手势。
- 真机验收：首页卡片单击清屏后双击，浮层出现，左分辨率、右内核、
  “复制播放地址”按钮可点复制（粘贴验证地址与当前播放地址一致，
  不再显示 URL 文字），旋转按钮能切横竖屏；再双击关闭；15 秒后
  自动消失；单击退出清屏时浮层跟着关；切到下一条卡片浮层不残留；
  详情页双击仍是暂停/播放。横屏下浮层左边两行从约 230pt 起（红框
  位置），分辨率 pill 与复制按钮、旋转按钮完整可见，不贴左边缘；
  竖屏下位置与原来一致。

## 影片信息（详情页，v0.0.25）

- 入口：详情页右上角“•••”→“更多播放选项”→“影片信息”，打开
  影片信息面板（复用已有的面板系统：移动端底部弹层、桌面右侧
  停靠面板，返回手势/Esc 关闭；`onPanelChange` 不上报 `info`，
  父级只关心 `detail`/`episodes`）。
- 内容：分辨率（`vsize`，未知时写“分辨率未知”）、格式、资源播放
  地址（`media.url`）+“复制播放地址”按钮（复用 `copyPlayUrl` 的
  clipboard + 兜底，成功提示同浮层一节，按是否在播区分——播着时
  “已复制，播着时切出可用”，暂停时“已复制，须先播放再切出”，播着
  且静音时“已复制，须先取消静音再切出”）。注意：这里
  地址文字是显示出来的（用户明确要求），与首页浮层 v0.0.24“只留
  复制按钮、不显示地址”不同，不要把两处搞混。
- 横屏：面板是全宽弹层，内容贴左沿，v0.0.29 起 info 面板横屏时
  整个面板内容右移 330px（`Feed.tsx` 里弹层 div 上 `panel === "info" &&
  vpLandscape` 才加 `paddingLeft: 330`）；v0.0.32 起所有面板横屏时
  左右都加 `--sal`/`--sar` 留白（见下一节“横屏刘海避让”），info 面板
  左沿仍保持 330px，只补右边；330px 是用户横屏截图上红框的左沿位置。
- 格式来源：`media.format` 是 `hls` 标 HLS；是 `progressive` 时从
  播放地址后缀推导（`.m3u8` → HLS、`.mp4` → MP4，另有 mkv/webm/
  mov/m4v/ts 的映射），拿不到后缀只写“未知”，不编造编码信息。
- 真机验收：详情页点 ••• → 影片信息，窗口弹出，含分辨率/格式/
  地址三行；点复制出现“已复制，切出应用后地址会失效”，粘贴核对
  地址与当前在播的一致；横屏下标题、标签、地址、复制按钮从约
  330pt 起（红框位置），不在左沿；首页浮层与旋转无回归。

## 横屏刘海避让（v0.0.32）

- 起因：用户 2026-11-22 09:52 录像（13 Pro Max）：横屏下选集、
  更多播放选项、作品详情、画质与线路几个面板的内容都贴左右沿，
  刘海挡住——选集“1”按钮与更多面板标题在左沿 20px 处，正落在
  刘海区；详情页分辨率 pill 横屏时也在左沿（左沿约 13-25pt）。
- 根因：横屏时本机 WKWebView 里 `env(safe-area-inset-left/right)`
  是 0（v0.0.29 已实测），`--sal`/`--sar` 只剩 12px，贴边内容
  全落在刘海区。刘海在横屏时位于短边中部（竖直约 110-320pt），
  标题栏（顶部）与底部控制条不在刘海带内，不动；中部贴边的
  角标与面板内容才要避让。
- 做法：`--sat`/`--sab`/`--sal`/`--sar` 从 `App.tsx` 行内样式移到
  `index.css` 的 `.plat-ios.win-root, .plat-android.win-root` 上，
  值不变；iOS 横屏时左右按系统横屏安全区 44px 兜底
  （`@media (orientation: landscape)`，随旋转实时生效，不用等
  React 重渲染；44px 是 iOS 横屏安全区的值，之前 v0.0.24 错的是
  “以为 env() 会返回 44px”，不是 44px 这个数本身）。Android
  只搬定义，不改值。详情页角标横屏已叠到右侧（v0.0.32 前一条），
  右沿按 `--sar` 留白，自动跟着到 44px；播放面板横屏时弹层 div
  左右各加 `--sal`/`--sar`，面板自身 20px 内边距还在，内容离边
  约 64pt，左右都避开刘海；info 面板左沿仍保持 330px，只补右边。
- 真机验收：横屏打开选集、更多播放选项、作品详情、影片信息、
  画质与线路，标题、按钮、地址都不贴边、不被刘海挡；详情页
  角标两 pill 完整可见；竖屏位置与原来一致；标题栏与控制条
  无回归。

## 横屏播放时隐藏 iOS 状态栏（v0.0.29）

- 行为：`Feed.tsx` 里当前播放卡激活且屏幕横置（`vpLandscape &&
  active`）时调原生命令隐藏状态栏，时间、电量、网速等系统信息
  不再压在视频上方；回竖屏或离开播放页时恢复（effect 的 cleanup
  里恢复，卸载时也恢复）。只在 iOS 上调用，其他平台没有这条命令。
- 机制：`OrientationPlugin.setStatusBarHidden`（`src-tauri/ios/
  Sources/OrientationPlugin.swift`，与方向切换同一个插件）走
  `UIApplication.shared.isStatusBarHidden`。默认 Info.plist 没有
  `UIViewControllerBasedStatusBarAppearance`（即按视图控制器），
  这时改 UIApplication 会被忽略，所以 `scripts/
  sync-ios-status-bar.mjs` 在 CI 生成工程后把它写成 `<false/>`
  （只改带 `UILaunchStoryboardName` 的主应用 Info.plist；找不到
  时打警告、不报错）；`build-ios-unsigned.sh` 与 `tauri.conf.json`
  的 `beforeBuildCommand` 都调它。Rust 命令是
  `commands::set_status_bar_hidden`（`lib.rs` 已注册），前端包在
  `src/statusBar.ts`，失败静默、不影响播放。
- 真机验收：横屏播视频时顶部时间/电量/网速都不见了；转回竖屏
  立即恢复；退出播放页、切后台再回来，状态栏状态与方向一致；
  竖屏下状态栏始终可见。

## 后台音频：复制的播放地址在浏览器里播（v0.0.30）

- 结论先行：回环地址可以在浏览器里播，但前提是视频播着的时候切
  出——播着时有音频在播，iOS 按音频后台模式让本应用进程继续跑，
  本地服务器不断，浏览器就能从回环地址取流；暂停时没有音频在播，
  后台模式不保活，进程被挂起，地址打不开。v0.0.29 的“切出应用后
  地址会失效”只对暂停时成立，写错了，v0.0.30 改成按是否在播区分
  的提示（`Feed.tsx` 的 `copyPlayUrl`：播着时“已复制，播着时切出
  可用”，暂停时“已复制，须先播放再切出”）。v0.0.32 补上第三种
  状态：静音播着也没声音，同样保活不了——应用默认启动静音
  （`hpp.startMuted` 默认 true，设置页“启动时静音”开关），所以
  复制提示再加一档：播着且静音时“已复制，须先取消静音再切出”。
  用户 2026-11-22 10:05 反馈 v0.0.30 复制后浏览器还是播不了，
  最可能就是默认静音：视频在播、但没声音，切出即被挂起。
- 证据：用户在蚂蚁影视里的录像——视频播着（00:04/01:36，暂停键
  显示在播）时切到浏览器，粘贴它的回环地址
  （`http://127.0.0.1:10010/hg.mp4?vid=…&q=2160&did=…&iid=…`），
  浏览器里播起来了（下载速度 1.9M/s）；而 v0.0.28 里 HGhub 的录
  像，视频是暂停的，切出去一直白屏加载。两边都是回环地址，差别
  只在播/停。固定端口（10010）与随机端口不是差别；MP4 与 HLS
  也不是差别（HLS 只要进程活着、清单与分片能接着取，一样能播）。
- 机制：`scripts/sync-ios-background-audio.mjs` 在 CI 生成工程后
  给主应用 Info.plist 加 `UIBackgroundModes: ["audio"]`（只改带
  `UILaunchStoryboardName` 的主应用 plist；已有该键时只往数组里补
  audio，不重复插；找不到时打警告、不报错）；`build-ios-unsigned.sh`
  与 `tauri.conf.json` 的 `beforeBuildCommand` 都调它。WKWebView
  与原生 AVPlayer 都走系统音频会话，只加这个键就能用，不用改
  Rust/Swift，不动 `media.rs`，不暴露上游地址。协议 09 §7 允许宿
  主“在平台许可范围内保留活跃媒体会话”，不以持续后台执行为前提——
  本改动就是用平台许可的音频后台模式保活，不改协议、不改能力声明，
  `IMPLEMENTATION.md` 与 `status.md` 里“后台恢复仍需验收”的状态
  不变，等真机验收通过再改。
- 副作用（用前先知道）：视频播着时切出应用，声音会继续在后台响，
  这是普通视频应用的标准行为；要停就先暂停，或回应用内关掉。播
  着时切出后如果在应用内点了暂停，音频停了，进程随即挂起，浏览器
  那边的流会在缓冲耗尽后停住——所以浏览器里播的时候，别在应用里
  暂停。
- 保活失效与回来只能重启（v0.0.40，用户 2026-11-22 16:17 报“挂后
  台后过段时间资源不能保活，必须退出重进才能激活”）：两个根因。
  ① `VideoSurface` 的 `visibilitychange` 处理在切后台时 `pause`
  + `stopLoad`——音频一停，iOS 很快挂起进程，回环服务就死了；
  v0.0.30 的测试只切出去几十秒，还在宽限期内，才看着是好的。
  修法：切后台不再暂停（播着继续播，HLS 继续加载；已暂停的不动，
  回来也不续播），`active` 变 false（切到别的卡片/详情页）时才停。
  ②回来不恢复：`active`/`canPlay` 在切后台/回前台时不变，之前只
  靠它们翻转才刷新会话——后台过期后回来根本不触发，只能重启。
  修法：回前台就把刷新检查再跑一遍（失败过、没会话、或地址 5 秒
  内过期，都刷一次，`PluginMediaDetail` 的 `foregroundTick`）。
  仍有限制：地址在后台过期那一刻，刷新出来的新会话在后台不会自
  动开播（`play()` 在 hidden 时拒绝），回来那一下才续播；SenPlayer
  那边如果正好在过期点断流，回来重播后再跳一次。验收：播着切出，
  过几分钟再看 SenPlayer/浏览器还通不通；回来应用内应直接续播，
  不用重启；暂停后切出仍是断的（符合预期）。
- 真机验收：①播着视频时复制地址、切到 Safari、粘贴、前往，视频
  在浏览器里播起来；②暂停后复制、切出、粘贴，白屏打不开（符合预
  期）；②a 静音播着时复制、切出、粘贴，同样打不开（符合预期——
  没声音就不保活；先点音量取消静音再复制切出，应能播）；③播着时切出，应用的声音继续在后台响；④验包时确认打出
  的 Info.plist 含 `UIBackgroundModes` 与 `audio`，CI 日志里有
  `[bgaudio]` 一行；⑤HLS 源与 MP4 源都按 ① 测一遍。

## 详情页左右竖滑调亮度/音量（仅详情页，v0.0.31）

- 行为（用户 2026-11-22 09:23 要求，位置是用户选的“只在详情页
  加”）：详情页（`mode === "full"`）播放时，竖滑左半屏调屏幕亮
  度、右半屏调系统音量，上滑增大、下滑减小，全屏高度拖满 = 100%；
  横屏竖屏都一样（按当前视口的左/右半屏与高度算）。拖动时屏幕中
  央出现指示条（“亮度 65%”/“音量 65%”+ 进度条），停 1 秒后收起。
- 范围：只在详情页。首页卡片（预览）里上下滑照常切视频，不动；
  详情页里上下滑不再切集——切集改用“选集”面板（本来就是切集的主
  入口）。横拖仍是定位（scrub）、单击仍是清屏、双击仍是暂停/播放、
  长按仍是 2x、双指仍是缩放，都不动。非 iOS（桌面、网页版）与
  Android 详情页里竖滑仍是切集（原生亮度/音量命令只在 iOS 上有）。
- 机制：亮度走 `UIScreen.main.brightness`（下限 0.05，避免全黑后
  看不见界面）；音量走系统音量——读 `AVAudioSession.outputVolume`，
  写 `MPVolumeView` 的滑块（iOS 没有公开的设置系统音量 API，这是
  标准做法；`MPVolumeView` 第一次用时以 1x1 隐藏挂进当前窗口，
  找不到滑块时 reject，前端不更新指示条）。Swift 在
  `OrientationPlugin` 里加 `adjustBrightness`/`adjustVolume`，
  Rust 命令 `adjust_brightness`/`adjust_volume`（`lib.rs` 已注册），
  前端包在 `src/screenControl.ts`（只在 iOS 原生应用里调，网页版
  返回 null，手势不启用）。前端按拖动增量调（每次返回调完后的新
  值供指示条显示），调用串行化（上一次调完再调下一次），避免并
  发读到的旧值互相覆盖。不用改 Info.plist，不动 `media.rs`，不改
  播放路径与会话——只是设备亮度/音量两个系统值，与插件传输无关。
- 真机验收：①详情页左半屏上滑，屏幕变亮，指示条“亮度”数字跟着
  变；②右半屏上滑，系统音量变大（与音量键效果一致），指示条
  “音量”数字与系统音量一致；③横屏与竖屏各测一遍；④首页卡片上
  下滑仍切视频；⑤详情页横拖仍定位、单击仍清屏、双击仍暂停；⑥亮
  度滑到最暗不黑屏（下限 0.05）。
- 修手势失灵与反向（v0.0.40，用户 2026-11-22 16:07 报“有时候上下
  滑没反应或者上滑变成减、下滑变成加”）：三个根因。①按住 380ms
  后才竖滑：长按 2x 的 hold 计时器已触发，竖滑被 hold 吃掉——现
  在 hold 中竖滑超 32px 就改走正常竖滑（详情页进亮度/音量，首页
  进切视频）；代价是长按后上滑锁定 2x 的手势没了（长按本身仍是临
  时 2x）。②横滑误判：竖滑起手带一点横向抖动就进了横拖定位
  （scrub），判定比从 1.2 收紧到 2.0（横向须明显大于竖向才算定位）。
  ③音量回读滞后：`AVAudioSession.outputVolume` 在滑块写完后一段
  时间内仍报旧值，连续快滑按读回值加增量会互相抵消、看着像没反
  应甚至反了——Swift 侧改以最近一次写的值为基准（2 秒内有效，超
  过重读，音量键改过的值不会一直盖住）；亮度读回是同步的，也走
  同一份基准。另前端把同一路的增量合并成一次原生调用再发（快滑
  时调用排队会跟不上手指），两路互不干扰。

## 详情页控制条与首页进度时间（v0.0.40）

- 详情页竖屏控制条（移动端 `PlayerControls`，`hg-mobile-controls`）：
  进度条左右各加一个分集按钮（上一集 / 下一集，与桌面控制条同一
  入口 `onPreviousEpisode` / `onNextEpisode`，第一集时上一集禁用、
  最后一集时下一集禁用）；控制条左下角加实时 / 总时间
  （`当前 / 总时长`，与桌面版同一 `clock()` 格式）。布局由一行改
  成两行：上行是上一集 + 进度条 + 下一集，下行是时间 + 锁定/旋转/
  全屏。全屏控制条本来就有时间，不动。
- 首页底部（`hg-preview-footer`）：进度条左右加实时 / 总时间
  （`fmtTime(time)` / `fmtTime(duration)`），清屏时照常隐藏。
- 首页向左快滑进详情页（v0.0.40，用户 2026-11-22 16:11 要求）：
  首页预览卡片上向左快滑（速度 > 0.55 px/ms，与竖滑切视频同一速
  度阈值）进详情页、从第一集开始播；慢拖仍是横拖定位。只认速度不
  认距离——慢拖 100px 也必须还是定位。实现：`Feed` 的横拖释放时
  判速度，`PluginMediaDetail.openDetailFromStart` 开详情页并切第
  一集（列表已在手上时直接 `play` 第一集；还没回来时只进详情页，
  与点“观看完整作品”一样）。注意点“观看完整作品”仍是断点续播
  （有进度时从上次那集起），左滑才是强制第一集；右滑不动，仍是定位。

## 画面设置（更多播放选项 → 画面设置，v0.0.32；首页浮层入口 v0.0.36）

- 入口：播放页右上角“•••”→更多播放选项里的“画面设置”下拉框，
  五档：适应 / 拉伸 / 铺满 / 16:9 / 4:3；选完立即生效，记在
  `hpp.pictureMode` 里，下次打开还是这一档。首页预览卡片上，清屏后
  双击唤出的信息浮层里也有一个画面设置按钮（齿轮图标，复制播放地址
  与下载按钮旁），点按打开更多播放选项、直接看到画面设置下拉框。
  竖屏详情页看横屏视频时的“放大铺满 / 完整适应”胶囊还在，点它在
  适应↔铺满之间切（与下拉框是同一档位）；双指缩放后点它还原缩放并
  回到适应。
- 含义：适应 = 原来的自动逻辑（横屏/全屏完整显示，竖屏看横屏视频
  默认完整显示，竖屏视频竖屏看铺满）；拉伸 = 拉满整个画面
  （`object-fit: fill`，画面会变形）；铺满 = 裁切铺满（cover）；
  16:9 / 4:3 = 画面框定死比例再裁切显示（`aspect-ratio` + cover，
  横屏竖屏都一样）。实现在 `src/store.tsx`（`PictureMode`）、
  `Feed.tsx`（`effectiveFit` + `aspect`）与 `VideoSurface.tsx`
  （`fit` 加 `fill`，`aspect` 框）。不改取流、切集、会话与插件
  调用，只改画面呈现。
- v0.0.32 顺带拿掉了竖屏详情页胶囊里的“横屏全屏”按钮（用户
  2026-11-22 09:38 反馈：竖屏时出现，点了没反应）——控制条右下角
  的全屏按钮与键盘 F 键进全屏还在，不动。
- 真机验收：①五档逐一切换，画面按上表变化；②切到 16:9，横屏视频
  上下留黑边裁成 16:9、竖屏视频左右裁切；③切到 4:3 同理；④拉伸时
  画面拉满变形；⑤退出重进，档位还在；⑥“放大铺满”胶囊与下拉框
  档位一致（点胶囊切到铺满，下拉框同步变铺满）；⑦竖屏详情页胶囊
  里没有“横屏全屏”了。

## 播放方向（横竖屏）

- 自动：`Feed.tsx` 拿到视频尺寸后按分辨率选方向，横屏视频（宽>高）
  调 `set_orientation(true)`，竖屏视频调 `set_orientation(false)`，
  不再只在全屏时才转；切集后回到自动。
- 手动：移动端控制条（锁定、全屏之间）多了一个旋转按钮，点一下切
  到当前方向的反面，并覆盖本集的自动选择；退出播放页时恢复竖屏。
  “当前方向”必须在点按时读实时视口尺寸（`window.innerWidth >
  window.innerHeight`），不能读 `vpLandscape` state——程序触发
  旋转后 resize 事件可能不来、或来时尺寸还是旧的，state 就一直
  停在竖屏，每次点都继续要求横屏、切不回竖屏（v0.0.23 录像里
  每次都提示“已切换到横屏”就是这个症状，v0.0.24 改的就是这个）；
  `vpLandscape` 只留给布局（全屏/画面比例/控制条位置）用。自动
  转方向没生效时屏幕还是竖屏、视频却是横屏，用视频方向算会得出
  “当前已是横屏”，点一下反而要求切回竖屏，看起来就像按钮没反应
  （v0.0.21 修的就是这个）。
- iOS 方向控制是新加的原生插件 `src-tauri/ios/Sources/OrientationPlugin.swift`
  与播放器插件同属 `NativePlugins`
  SPM 包，前端 `src/orientation.ts`
  在 iOS 上也走 Rust 命令 `set_orientation`——iOS 的 WKWebView 不支持
  Screen Orientation API 的 `lock()`，之前 iOS 走浏览器分支会直接失败。
- 机制（v0.0.22）：iOS 16+ 走
  `UIWindowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`，
  等 0.5s 后按场景实际方向验收，方向对上才 resolve，对不上 reject；
  iOS 15 没有这个 API，才走 `UIDevice.setValue(forKey: "orientation")` +
  `attemptRotationToDeviceOrientation()` 的 KVC 老路（`#available`
  守卫，两条路按系统版本二选一，不叠加）。v0.0.21 及之前全量走 KVC，
  两段用户录像里自动与手动切换从没生效过，且旧实现调完无条件
  resolve，前端分不清成功失败——这是 v0.0.22 换机制的原因。
  手动旋转成功时提示“已切换到横屏/竖屏”，失败时提示“无法切换屏幕
  方向，请重试”；自动切换失败仍静默。
- 注意：`setOrientation` 是“设置一次方向”，不是“锁定”——调完之后
  用户再转手机，系统仍可按设备方向转回来；AppDelegate 级的方向
  锁定没做。另外 iOS 上 `set_orientation(false)` 是切回竖屏，与
  Android 的“恢复之前方向”语义不同。

## mpv 原生控制层（v0.0.146）

v0.0.145 之前 mpv 原生是裸全屏：只有画面，没有任何控制（连关闭
按钮都没有），亮度/音量手势也只在详情页 WebView 里、原生全屏盖住
后失效。控制层是原生 UIKit 覆盖层
（`src-tauri/ios/Sources/engines/MPVControlOverlay.swift`），由
`MPVEngine.open()` 加进容器、0.5s 的状态轮询刷新，`close()` 时拆
掉；AVPlayer 用系统控制条，不走这里。

- 顶栏：关闭（×）+ 标题（open 时前端传的 `title`，以前被 `_ = title`
  丢掉）+ 分辨率角标（`videoWidth×videoHeight`，与 AVPlayerEngine 的
  同一款式，尺寸未知时隐藏；控制条显隐时跟着走，不另设 3 秒定时器）。
- 底栏：播放/暂停、当前时间 / 总时长、进度条（拖动快进/快退，松手
  才 seek）、静音、倍速（1 → 1.25 → 1.5 → 2 → 0.5 → 0.75 循环）、
  旋转。进度条拖动时 0.5s 刷新不抢滑块位置（量程照常跟）。
- 显隐：单击视频区切换显示/隐藏；播着时 3 秒无操作自动藏，暂停时
  一直显示（与 WebView 的 PlayerControls visible 规则一致）。
- 手势（只认视频区域，控制条上的触摸交给按钮和滑块）：双击播放/
  暂停；左半屏竖滑调亮度（`UIScreen.main.brightness`，下限 0.05）、
  右半屏竖滑调系统音量（藏起来的 `MPVolumeView` 滑块，与
  OrientationPlugin 同一套做法，2 秒内用最近一次写的值当基准，避
  免读回滞后互相抵消）、横滑快进/快退（松手才 seek，拖动中只改指示
  条和进度条）；中央指示条显示亮度/音量百分比或快进目标时间，1 秒
  后收起。
- 方向：首次拿到分辨率就按它自动横竖屏（只做一次）；旋转按钮读实时
  场景方向切到反面（v0.0.23 的教训：不能读缓存），并提示“已切换到
  横屏/竖屏”；横屏时隐藏状态栏、竖屏显示（与 WebView 播放页同规则，
  0.5s 刷新里变了才写）。旋转 API 与 OrientationPlugin.setOrientation
  同一套（iOS 16+ `requestGeometryUpdate`，iOS 15 KVC 老路）。
  - 诊断版 v0.0.149：自动转屏已关（147 电影首帧转横屏后约一两秒闪退，
    疑首帧两句转横屏请求重叠——覆盖层这句 + 前端按视频尺寸调的那句；
    短剧竖屏自动转屏、反复手动横竖屏翻转都不闪）。只关自动这一句，
    手动旋转按钮、手动转手机、前端调方向都不动。同版还修了点 × 闪退
    （`MPVEngine.makeCArgs` 的守卫误杀空参数表，`close()` 发 `stop`
    时每次都 `fatalError`）。
- 关闭：点 × 先拆播放器、再把 `.closed` 发回插件，前端据此把最新
  进度回写并回落 WebView（与 AVPlayer 的 Done 同路）；顺序不能反，
  先发 `.closed` 的话插件会把 engine 置 nil、引擎释放，dismiss 就
  跑不到了。

## mpv 硬件加速开关（v0.0.146）

两处入口，都是同一个开关（store `mpvHardwareAcceleration`，持久化
`hpp.mpvHardwareAcceleration`，默认开）：

- 详情页 → 更多播放选项 → 硬件加速（复选框，紧跟播放内核下面）；
- 我的 → 设置 → 播放 → 硬件加速（开关，紧跟播放内核下面，iOS 才显示）。

开关只影响 mpv 原生播放，改动下次原生播放生效（播着的时候改不影响
当前这一场）：

- 开：`hwdec=videotoolbox-copy`（145 起的默认）——VideoToolbox 硬解，
  帧拷回内存再上传；H.264/HEVC 走硬解，AV1/VP9 走 dav1d 软解。
- 关：`hwdec=no`——全软解（FFmpeg/dav1d）；关闭后使用软解（更兼容但更耗电）。

8 秒自动切软解回退已取消（v0.0.146）：硬解/软解只由这个开关控制，不再
自动切；硬解出不了画面时，手动把开关关掉再播。

透传链：store → `openNativePlayer({…, hardwareAcceleration})` →
Tauri `native_player_open`（camelCase `hardwareAcceleration`）→ Rust
`open_payload`（snake_case `hardware_acceleration`）→ Swift
`NativePlayerOpenArgs.hardwareAcceleration`（可选，缺省 true）→
`NativePlayerEngine.open(…, hardwareAcceleration:)`。AVPlayer / MDK /
KSPlayer 的 open 也接了这个参数但直接忽略：AVPlayer 没有硬解开关，
永远用 VideoToolbox 硬解 H.264/HEVC，不支持的格式直接播不了。

## 资源下载（播放页，v0.0.33；下载管理 v0.0.34；过期刷新重下 v0.0.35；首页浮层下载 v0.0.36；下载管理进更多菜单 + 导出 + 点播 + SenPlayer 跳转 v0.0.37；独立音频轨合轨 + 下载管理分享按钮 v0.0.38；video_width 回包修复 + 下载管理 SenPlayer 按钮 v0.0.39；下载管理 SenPlayer 直跳 v0.0.41）

- 入口：详情页“更多播放选项”菜单与“影片信息”面板里各有一个“下载”
  按钮，播放器上（全屏右上角与非全屏顶栏、更多按钮旁）还有一个下载
  图标按钮（仅 App 内，`isTauri()` 才显示），与“复制播放地址”并列。
  首页预览卡片上，清屏后双击唤出的信息浮层里也有一个下载图标按钮
  （复制播放地址与旋转按钮旁），点按下载当前正在播的那条；浮层 15 秒
  无操作自动消失，点下载会续 15 秒。
  复制的地址是回环地址、只在应用活着时才有效，下载是把同一份资源
  存成本地文件，存好后不依赖应用进程、哪里都能播——这是下载相对
  复制地址的根本区别。
- invoke 参数名：Tauri `#[tauri::command]` 默认按 camelCase 传参
  （tauri-macros 默认 `rename_all="camelCase"`），Rust 形参
  `download_id` 对应 JS 键 `downloadId`。v0.0.33 曾按 snake_case 传
  `download_id`，真机报 `missing required key downloadId`，下载点按
  后直接报错；v0.0.34 改为 camelCase。同根问题也修了原生播放
  `native_player_open` 的 `sessionId`（之前按 snake_case 传
  `session_id` 同样反序列化不到；`native_player.rs` 里那条“按
  snake_case 传”的注释是错的，已改——那条注释说的是发给 Swift 插件
  的载荷键名，不是 Tauri invoke 参数名）。
- 实现：前端 `src/download.ts` 调 Rust 命令 `download_media`
 （`src-tauri/src/download.rs`），只消费已有的回环地址
  （`media.url`），不改媒体服务器、不改插件协议。直链文件
  （MP4 等）流式写盘，不读入内存；HLS 先取清单再按顺序取分片拼成
  一个文件（TS 直接拼，fMP4 先写 MAP 初始化段再拼媒体分片；主清单
  只取带宽最高的一档）。进度经 `download-progress` 事件回传
  （HLS 按分片数，直链按字节），按钮上显示“下载中 45%”。
- 独立音频轨合轨（v0.0.38）：很多 fMP4 HLS 的音频不在视频 variant
  里，而是一条独立的音频 rendition（主清单用 `#EXT-X-MEDIA:
  TYPE=AUDIO` 声明，variant 的 `#EXT-X-STREAM-INF` 用 `AUDIO` 属性
  指到它）。v0.0.33–v0.0.37 只取视频 variant 的分片，拼出的 fMP4 没
  有音轨——本机播没声音，还会偶发“播放失败”（AVPlayer 读到 moov
  声明有音轨却无采样时报错）。v0.0.38 起 `download.rs` 解析
  `#EXT-X-MEDIA` 与 `AUDIO` 属性，取视频 variant 的音频组（优先
  variant 指定的组，其次 `DEFAULT=YES` 的组），两路清单都取
  （分片 URI 按各自清单的地址解析，之前按主清单解析是错的）；
  两路都有 MAP 初始化段且分片非空时走合轨：`src-tauri/src/fmp4.rs`
  的 `merge_inits` 把两路 init 合成一个（ftyp 取视频，moov 里同时
  放视频 trak 与音频 trak，mvex 里两路 trex 都在），再按各分片的
  tfdt 解码时间交错写盘（同时间视频在前），音频分片先下到临时文件、
  内存里一次只留一个分片。TS 清单或音频没 MAP 时仍走老路、只存
  视频（已知限制，不回归）。合轨前必须处理撞号：两路 init 的
  track_ID 常常都从 1 开始，`merge_inits` 会把音频轨换成没被视频
  占用的 ID 并返回换号表，下载时按同一张表把音频分片的 tfhd 与
  sidx 也改掉——不改的话音频分片按视频的 timescale 算时间，交错
  顺序全错、合出的文件播不起来（ffmpeg 夹具已验：合出的文件双轨、
  时长与源一致、两轨完整解码无错）。
- 存到哪：应用文稿目录下的 `Downloads`（iOS 是“文件”App 里
  “我的 iPhone”→ 红苹果影视 → Downloads；`UIFileSharingEnabled` 与
  `LSSupportsOpeningDocumentsInPlace` 由
  `scripts/sync-ios-file-sharing.mjs` 在构建时写进 Info.plist）。
  文件名取视频标题（非法字符换 `_`，超长截断），扩展名按实际内容定
  （HLS 是 `.ts` 或 `.mp4`，直链按 Content-Type）；同名文件不覆盖，
  自动加（1）（2）。
- 完成后：按钮变“已下载 · 分享”，点按弹系统分享面（iOS 是新加的
  原生插件 `src-tauri/ios/Sources/SharePlugin.swift`，
  `UIActivityViewController`，可存到“文件”、发到微信等；其他平台
  用 opener 打开该文件）。切集后下载状态复位。
- 限制（协议 09 §5/§6）：一次只下一个，顺序取流，让位于前台播放；
  不续传，中途失败删掉未完成文件、由用户重新点按（即重启当前文件）。
  直播没有 `#EXT-X-ENDLIST`，只下当前窗口的分片、存成一段片段，
  提示会写明“已保存当前直播片段（约 N 秒）”。加密 HLS
  （`EXT-X-KEY`）与 BYTERANGE 分片暂不支持，明确报错，不拼出损坏文件。
  会话过期（410/401）时不再直接报错：按协议 09 §5，活跃下载会话的
  地址失效是可恢复取流失败，触发一次刷新（`onRetry` →
  `media.refresh`，一轮故障最多自动刷新一次），新地址到后用新地址
  重下一次；重下仍失败才提示用户重新播放后再下载。刷新期间按钮显
  示“刷新地址…”，刷新 20 秒不到则提示超时。切集会取消待重下。
  下载时每次取分片都会取消预取缓存（媒体服务器的既有行为），播放
  可能多缓冲一点，这是 v1 接受的代价。
- 下载管理（v0.0.34）：设置里新增“下载管理”一节（仅 App 内），列出
  文稿/Downloads 里的已完成下载（`list_downloads` 命令，按修改时间
  倒序，跳过 `.part` 未完成文件），每行显示文件名、大小与日期，可分
  享（系统分享面，导出）或删除（点两下确认；`delete_download` 只允许
  删 Downloads 目录里的文件，路径须落在该目录下）。v0.0.38 起每行
  多了一个分享按钮图标（`IShare`，与导出图标并列），点按直接弹系统
  分享面（复用已有的 `shareDownloadedFile`，不用先展开导出菜单）；
  同时播放/导出/分享/删除失败时显示真实的报错原因，不再一律写
  “播放失败”（Tauri invoke 失败时返回的是纯字符串，之前按
  `Error.message` 取不到）。v0.0.39 起每行再多一个 SenPlayer 图标
  按钮（`ITrendUp` ↗，仅 iOS）。v0.0.39–v0.0.40 是弹系统“用…打开”
  菜单（新命令 `open_in_file` → SharePlugin 的 `openIn`），菜单里
  点 SenPlayer 才把文件交给它播；v0.0.41 改成直接跳：点图标先由新
  命令 `serve_download` 把文件挂到回环服务上（`MediaSessions::
  serve_local`，`/local/<随机 id>`，流式回文件、支持 Range，见协议
  09 §3；只接受 Downloads 目录里的文件，与 `delete_download` 同一
  套路径校验），再按在线播放同一条 Scheme（`senplayer://
  x-callback-url/play?url=…&name=…`）跳 SenPlayer，不弹菜单。回环
  取流快，短剧一集几 MB，SenPlayer 几秒内就能取完；文件特别大、取
  到一半进程被挂起时仍会断，那时用分享按钮的系统分享面“用 SenPlayer
  打开”兜底。`open_in_file` / SharePlugin 的 `openIn` 已随之删掉
  （分享按钮的系统分享面仍有“用 SenPlayer 打开”）。
- 下载管理进更多菜单、导出、点播（v0.0.37）：详情页与首页的“更多播放
  选项”菜单里新增“下载管理”入口，打开同一份 `DownloadManager`（新
  面板 `downloads`，不走 `onPanelChange`）；设置里的下载管理不变。
  每行加导出图标，点按展开两个去向：保存到相册（新命令
  `export_to_photos`，iOS 经 SharePlugin 的 `saveToPhotos` 用
  `PHPhotoLibrary` 直接存视频，`NSPhotoLibraryAddUsageDescription`
  由 `scripts/sync-ios-photo-library.mjs` 在构建时写进 Info.plist，
  缺了这个键首次保存会崩溃；其他平台不支持）与保存到文件（走原来的
  系统分享面，选“存储到‘文件’”）。点按文件名（或行首播放图标）直接
  在本机播：`playDownloadedFile` 用原生 AVPlayer（`openNativePlayer`，
  engine `avplayer`，`file://` URL，不走插件会话、不写播放进度），
  关掉后回到下载管理，不回落到在线流（`nativePlayer.ts` 里的本地标记，
  Feed 的关闭/报错回落回调读到就跳过）。HLS 拼合的 `.ts` 本机播不了
  （AVPlayer / WebView 都播不了裸 .ts，只有 `.m3u8` 清单能播），点按
  明确提示改用导出、到 SenPlayer 里打开；能播的是 `.mp4` / `.mov` /
  `.m4v`。
- 下载管理按文件夹归类（v0.0.37，同批）：多集资源下载时按文件夹归类，
  文件夹名取作品标题（`Feed` 里总集数 `episodeCount > 1` 时传 `folder`，
  文件名取分集 `episodeLabel`，如“1”/“第 1 集”；单文件资源不传
  `folder`，直接散放在 Downloads 下）。Rust 侧 `download_media` 多了
  可选参数 `folder`（`Option<String>`，文件夹名走与文件名同一套清理
  规则；不传就是老行为），`list_downloads` 往下走一层、子目录里的文件
  带上 `folder` 字段；`delete_download` 的路径检查本来就只要求落在
  Downloads 目录下，文件夹里的文件照样能删，不用改。下载管理里文件
  夹可折叠（默认展开），按文件夹里最新文件的修改时间倒序；单个资源
  文件直接列在文件夹下面。已下载的老文件不动——以前是散放的“标题”、
  “标题（1）”，分不出是哪集，不回头重分组；只有新下载的才进文件夹。
- SenPlayer 跳转（v0.0.37）：用 SenPlayer 的公开 URL Scheme
  `senplayer://x-callback-url/play?url=<编码后的播放地址>&name=<标题>`
  （goplexcli、OrivioTV、lampa 的外部播放器表都是同一格式，只传
  url + name）。入口四处：首页清屏浮层（下载按钮旁）、详情页顶栏与
  全屏右上角（下载按钮旁）、“更多播放选项”菜单（“SenPlayer 播放”）。
  实现是新命令 `open_senplayer`（`commands.rs`），iOS 经 SharePlugin
  的 `openSenPlayer` 用 `canOpenURL` 先判是否装了，未装明确报错，不
  静默无反应；`LSApplicationQueriesSchemes: senplayer` 由
  `scripts/sync-ios-senplayer.mjs` 在构建时写进 Info.plist，不登记时
  `canOpenURL` 永远返回 false。`open_external_media` 走不了这条路，
  它只放行 http/https 等协议。地址过期先拦下；暂停、加载中或静音时
  不跳转，直接提示先播起来、取消静音——回环地址只在播着（有声音）切
  出时不断流（v0.0.30 复制地址同一结论），这几种状态跳过去流必断。
  跳过去后红苹果还在后台播着（声音与 SenPlayer 重叠），不要在红苹果
  里点暂停，否则流就断了。Swift 文件未编译（本机无 Xcode）。
- 真机验收（待 Mac / 设备）：点“下载”后进度走到 100%，文件在
  “文件”App 里能找到、能播；HLS 点播能完整拼出来；直播存的是当前
  窗口的片段；点“分享”能弹出系统分享面、能存到“文件”；设置里下载
  管理能列出已下载的文件、能分享导出、能删除。v0.0.35：播放地址过期
  时点下载不再直接报错，而是先显示“刷新地址…”再自动重下；播放器上
  （全屏右上角与非全屏顶栏）有下载图标按钮，点按同样开始下载。v0.0.36：
  首页清屏后双击，浮层里出现下载图标，点按能下载当前正在播的视频。
  v0.0.37：更多播放选项里能打开下载管理；下载管理里点按文件名能播
  （.mp4），.ts 点按提示改用导出；导出到相册能在相册里找到视频，导
  出到文件能在“文件”App 里找到；多集资源下载后收进以作品名命名的
  文件夹里（文件名是分集），单个资源直接散放，下载管理里文件夹可折
  叠；首页浮层、详情页顶栏、全屏栏、更多菜单都有 SenPlayer 按钮，装
  了 SenPlayer 时点按能跳过去播，播着切出不断流，没装时提示未安装。Swift 文件未编译（本机无 Xcode），与上面其他插件一样。
