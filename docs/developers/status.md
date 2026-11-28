# 当前支持状态

本页记录 `main` 分支对 HPP `1.0.0-dev` 的支持情况。2026-11-18 已更新 Windows 与 Android 的网页登录验收结果。

| 范围 | 当前状态 | 验证边界 |
| --- | --- | --- |
| 单文件/列表/URL 导入 | 已实现 | Rust 与 Windows UI；Android 单文件实测 |
| 订阅与自动更新 | 已实现 | 冷却、手动旁路、播放延后回归 |
| 独立运行时与取消 | 核心已实现 | 并发/中断/共享 Promise；模块顶层检查与工厂各自 5 秒总预算、1 秒同步片段及取消初始化有真实 QuickJS 回归；内部桥不向插件暴露 |
| HTTP/Cookie/存储 | 核心已实现 | 网络策略（含允许的 IPv4 与受限 IPv6 混合 DNS）、缓存、配额和持久化回归；未在实际 Tauri 窗口验证此网络环境。iOS 跟随系统时代理取自系统代理设置（HTTP/SOCKS 固定代理；PAC 不跟随）。插件 net 请求走内嵌 Node 引擎（Node.js 18.20.4，`node_start` + 回环边车；HTTP/1.1、无浏览器头），代理路径按用户设置不动；Node 18 已 EOL、体积 +25–35MB（待实际 IPA 核对）。v0.0.78：跟随系统模式下代理路快速 502/503/504 或代理握手失败时直连重试一次（窄回落，首跳永远先走代理）；Node 路径 5xx 转 `UPSTREAM_ERROR`（带代理描述、解析地址、两次尝试结果、Cookie 名字），wreq 路径仍当数据返回；每次 net.request 的代理决议写进 ext.log。v0.0.79：直连路径 TLS 被断时 Node 按系统顺序换地址重试（不用 pinning、不开 `autoSelectFamily`）；直连 NETWORK 错误带已试地址后缀（`（已试: …）`），Rust 的解析后缀带总数（`（解析: …；共 n 个地址）`） |
| 内容能力与本地片库 | 已接入 UI | 生产界面虚构源完整集成 25 组通过 |
| MP4/HLS/解析器 | 核心已实现 | Range、密钥、资源归属与取消回归 |
| 连播预备与字节预取 | 已实现有限策略 | 下一集准备复用；MP4 范围与静态 HLS 起播资源缓存；取消、过期与版本变化回退测试；用户已反馈 Windows/Android 播放与连播顺畅，非全平台完整验收 |
| RSA | 必需 API 已实现 | SPKI/PKCS#1、三种填充；真实 QuickJS 加密/解密核验、随机性、参数与长度边界、requires 回归；密钥 1024–8192 位 |
| 设备能力探测 | 已接入当前 WebView 能力 API | HLS 实际路径与普通视频分别探测、保守编码交集；加载快照/播放参数一致性回归，不代表所有 profile 或五端解码验收 |
| 字幕 | VTT 接入、SRT 转 UTF-8 VTT | 按轨道格式转换，支持 BOM 或响应 charset；真实宿主覆盖多轨元信息、Range/HEAD、坏字幕隔离；真实来源单轨转换已验证，设备字幕显示/切换待验收，ASS 未声明 |
| 外部播放流 | 已接入确认打开 | 点播、直播、图文/信息流显示目标并由用户确认交给系统；HTTP(S)、magnet、ed2k、rtsp、rtmp；真实宿主校验与无媒体会话回归通过，平台处理程序及设备交互待验收 |
| 宿主共享刷新 | 已接入 | 同一会话/版本共用刷新；成功后原子替换资源、旧版本地址失效；取消单个等待者不影响其他消费者；播放位置保留；设备恢复体验待验收 |
| 调度 | API 与媒体核心已实现 | 匿名 GET 按插件及每跳有效请求合并、独立取消/超时；每插件 API 6、同主机 4，媒体/图片 6/2，许可覆盖响应体；当前播放打断预取并阻止新预取插队。真实 HTTP 并发与媒体优先级回归通过；下载已有播放器侧实现（一次一个，顺序取流，不续传） |
| HTML 内存 | 数量/输入有界 | 尚未合并计入 64 MiB 堆预算 |
| 日志与卸载 | 核心已实现 | 所有日志入口共用速率/字节/环形上限，读取时显示丢弃数量；健康上下文同步 dispose 最多 1 秒，抛错/超时不阻止停用，真实宿主专项通过 |
| 自检/日志导出/占用与清理 | 尚缺 | 日志读取可用，文件导出待接入 |
| Android 相对列表 | 已接入目录授权，设备待验收 | 系统目录选择后按名称解析子路径；路径单测及 Rust 选装、身份、取消回归；单文件授权不扩大到兄弟文件 |
| WebView 登录 | Windows、受支持的 Android 已接入 | 用户已在两端验证真实站点登录。Windows 可在登录后点窗口顶部的“关闭”返回插件，Android 模拟器保留数据重装后仍可显示账号昵称。两端另有原生同源隔离测试，认证表单、取消和预算暂停有离线回归覆盖 |
| WebHome（HTML 源） | v1 已实现，未真机验收 | `meta.webhome` 声明 + 独立窗口 + `window.fm` 桥，直链播放走真实媒体会话；hpp 集成测试通过。iOS 第二个 WebView 窗口需真机验收，见 [WebHome 指南](webhome.md)。v0.0.48 支持直接导入 HTML（远程 homePage / 本地 localPage + 回环提供）与站点 JSON 识别；v0.0.66 窗口内小房子控件（切源/关闭），后改为常显圆形房子按钮、点按直达源面板（面板几秒不用自收）；v0.0.69 插件 net 请求改 Node 式极简画像；v0.0.70 插件 net 请求走内嵌 Node 引擎（假设检验，待真机验收）。`pan.play` 已支持猫源 token 解析（未真机验收）：有猫源 token 时解析成直链进原生播放器，否则回退应用内浏览器；`pan.check` 仍为 ok 占位，`app.openExternal` 同理；iOS WebHome 窗口开 back-forward 手势（右滑返回），待真机验收 |
| Python 蜘蛛（TVBox .py 源） | v1 已实现，仅 iOS，未真机验收 | CPython 3.12.16 边车（BeeWare 3.12-b13）+ `base.spider`；导入按内容识别，`py.<词干>` / 版本恒 1.0.0；映射 `catalog.getCategories` / `home.getSections` / `feed.list` / `catalog.list` / `search.search` / `media.getDetail` / `media.resolvePlayback`（见 [Python 蜘蛛指南](python-spiders.md)）。hpp 集成测试 5 项与边车全模式/v1-only 模式通过。非 iOS 目标初始化报 `UNSUPPORTED`。iOS 构建与设备播放待 CI/真机验收；`lxml` / `pyquery` / `pycryptodome` v1 不带，`liveContent` / `suggest` / `trending` / `transformResource` / `endpoints` 未映射，`meta.settings` 与持久存储未接 |
| 猫源（Node 猫源） | v1 已实现（设计文档已实现），待真机验证 | Node 边车（nodejs-mobile v18.20.4）+ `/cat/load` / `/cat/unload` / `/cat/list`；订阅导入（网络 URL / ZIP）与 `cat-sources.json` 记录，`cat.<订阅>` / 版本恒 1.0.0 / `runtime: "cat"`；方法面与 Python 蜘蛛一致（见 [Node 猫源](cat-source.md)）。hpp 单元测试通过。非 iOS 目标初始化报 `UNSUPPORTED`。iOS 构建、订阅导入、分类/详情/搜索/播放与启停/删除待真机验收 |
| DASH/ASS | 可选未支持 | 不声明这些特性 |
| 原生播放器（iOS） | 桥已搭，部分验证 | AVPlayer 完整实现；mpv 已实现（原生 dylib + render API，v0.0.142 起；138–141 真机已跑通，Mexico 原画待验证）；AetherEngine 已接线（SPM 6.89.1，v0.0.148 起，未真机验证）；MDK / KSPlayer 为 canImport 守卫；默认路是 auto（原生优先，v0.0.148 起），见 [iOS 原生播放器](native-players.md) |
| 跨端/后台 | 未完成 | Windows 浏览器、Android 导入及单部真实 MP4 播放有证据 |

Windows 与 Android 的原生测试均覆盖同源 Cookie 和 localStorage。API 35 / WebView 110 在独立登录进程内使用新数据目录，通过主视图与连续两次登录的隔离测试。客户端按原生能力声明 `webview`。当前适配器要求 Windows WebView2 88 及以上，或 Android 28 及以上并支持 `GET_COOKIE_INFO`。

细节见[实现说明](../plugin-protocol/IMPLEMENTATION.md)。
