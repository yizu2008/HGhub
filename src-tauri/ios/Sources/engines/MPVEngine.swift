// mpv 引擎（libmpv / MPVKit）：四个里格式和 ASS 字幕最强，但也最难接。
// MPVKit（mpvkit/MPVKit，LGPL 版产品 `MPVKit`）只提供 libmpv/FFmpeg
// 的 XCFramework，没有 Swift 播放器类——MPVPlayer/MPVGLView 是另一个
// libmpv-ios 项目的包，不在 MPVKit 里。所以这里直接调 libmpv 的 C API，
// 渲染走 MPVKit Demo 同款：CAMetalLayer +
// vo=gpu-next + gpu-api=vulkan + gpu-context=moltenvk，
// hwdec=no（v0.0.140 诊断：关硬解纯软解试播，之前是 videotoolbox）。
// 钉的版本见 src-tauri/ios/Package.swift（MPVKit 0.40.0-xcode exact，
// iOS 13.0 底线；0.41.0 起要 iOS 14.0，1.x 起要 iOS 15.0）。
// 详见 docs/developers/native-players.md。
//
// 懒加载（v0.0.127）：MPVKit 不再静态链进主程序（v0.0.124/125 那样
// 启动黑屏，126 摘掉就启动，已证实是它）。28 个静态库打成一个动态库
// MPVKit.framework、嵌进 .app/Frameworks/，启动时完全不碰；这里在
// 用户第一次选 mpv 点播放时才 dlopen + dlsym，加载失败就报
// unavailable、播放链回落 AVPlayer/WebView，绝不 crash。主程序里
// 没有任何 mpv 符号（不 `import Libmpv`），所以启动与 126 完全一致。
// libmpv 的常量与结构体布局按 MPVKit 0.40.0-xcode 的 client.h 手写
// （MPV_FORMAT_* / MPV_EVENT_* / MPV_END_FILE_REASON_* / mpv_event /
// mpv_event_property / mpv_event_end_file），错一个字段就内存错乱，
// 改版先核对 client.h。

import UIKit

/// libmpv 常量（client.h，mpv 0.40.0）：MPV_FORMAT_*。
private let MPV_FORMAT_FLAG: Int32 = 3
private let MPV_FORMAT_INT64: Int32 = 4
private let MPV_FORMAT_DOUBLE: Int32 = 5

/// libmpv 常量（client.h，mpv 0.40.0）：MPV_EVENT_*。
private let MPV_EVENT_NONE: Int32 = 0
private let MPV_EVENT_SHUTDOWN: Int32 = 1
private let MPV_EVENT_LOG_MESSAGE: Int32 = 2
private let MPV_EVENT_END_FILE: Int32 = 7
private let MPV_EVENT_PROPERTY_CHANGE: Int32 = 22

/// libmpv 常量（client.h，mpv 0.40.0）：MPV_END_FILE_REASON_*。
/// 注意 0.40.0 里 ERROR = 4（不是 3），STOP = 2，QUIT = 3，REDIRECT = 5。
private let MPV_END_FILE_REASON_EOF: Int32 = 0
private let MPV_END_FILE_REASON_ERROR: Int32 = 4

/// libmpv 事件结构（client.h，mpv 0.40.0）：mpv_event。
/// 字段顺序与类型必须与 C 完全一致：event_id(int)、error(int)、
/// reply_userdata(uint64_t)、data(void*)。
private struct MPVEvent {
  var event_id: Int32
  var error: Int32
  var reply_userdata: UInt64
  var data: UnsafeMutableRawPointer?
}

/// libmpv 事件结构（client.h，mpv 0.40.0）：mpv_event_property。
/// 字段：name(const char*)、format(mpv_format/int)、data(void*)。
private struct MPVEventProperty {
  var name: UnsafePointer<CChar>!
  var format: Int32
  var data: UnsafeMutableRawPointer?
}

/// libmpv 事件结构（client.h，mpv 0.40.0）：mpv_event_log_message。
/// 字段：prefix(const char*)、level(const char*)、text(const char*)、
/// log_level(mpv_log_level/int)。text 自带一个换行，转发前去掉。
private struct MPVEventLogMessage {
  var prefix: UnsafePointer<CChar>!
  var level: UnsafePointer<CChar>!
  var text: UnsafePointer<CChar>!
  var log_level: Int32
}

/// libmpv 事件结构（client.h，mpv 0.40.0）：mpv_event_end_file。
/// 字段：reason(mpv_end_file_reason/int)、error(int)、
/// playlist_entry_id(int64_t)、playlist_insert_id(int64_t)、
/// playlist_insert_num_entries(int)。注意 playlist_entry_id 在
/// API 1.108 起是 int64_t（旧版是 const char*），不要按旧版写。
private struct MPVEventEndFile {
  var reason: Int32
  var error: Int32
  var playlist_entry_id: Int64
  var playlist_insert_id: Int64
  var playlist_insert_num_entries: Int32
}

/// dlopen 后 dlsym 出来的 libmpv 函数表：每个函数一个 @convention(c)
/// 函数指针。加载时逐个 dlsym、缺一个就整体失败（不调空指针）。
private struct MPVKitAPI {
  let create: @convention(c) () -> OpaquePointer?
  let initialize: @convention(c) (OpaquePointer?) -> Int32
  let terminateDestroy: @convention(c) (OpaquePointer?) -> Void
  let setOption: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
  let setOptionString: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
  let command: @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
  let setProperty: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
  let getProperty: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32
  let observeProperty: @convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32
  let requestLogMessages: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
  let waitEvent: @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
  let setWakeupCallback: @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
}

/// dlopen MPVKit.framework 并 dlsym 出全部 libmpv 函数。
/// 失败返回 nil（附 dlerror 原因，调用方写进 unavailable 错误）。
/// 只在用户选 mpv 播放时调（open 入口），启动时绝不调。
/// 不 dlclose：播完不卸载，进程生命周期内常驻（重复 dlopen 同一路
/// 径本就会返回同一 handle）。
private func loadMPVKitAPI() -> (api: MPVKitAPI?, error: String?) {
  guard let path = Bundle.main.path(
    forResource: "MPVKit", ofType: nil,
    inDirectory: "Frameworks/MPVKit.framework")
  else {
    return (nil, "MPVKit.framework 不在包里")
  }
  guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
    let reason = dlerror().map { String(cString: $0) } ?? "未知原因"
    return (nil, "dlopen 失败：\(reason)")
  }
  func sym<T>(_ name: String, as type: T.Type) -> T? {
    guard let ptr = dlsym(handle, name) else { return nil }
    return unsafeBitCast(ptr, to: type)
  }
  guard let create = sym("mpv_create", as: (@convention(c) () -> OpaquePointer?).self),
        let initialize = sym("mpv_initialize", as: (@convention(c) (OpaquePointer?) -> Int32).self),
        let terminateDestroy = sym("mpv_terminate_destroy", as: (@convention(c) (OpaquePointer?) -> Void).self),
        let setOption = sym("mpv_set_option", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32).self),
        let setOptionString = sym("mpv_set_option_string", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
        let command = sym("mpv_command", as: (@convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
        let setProperty = sym("mpv_set_property", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32).self),
        let getProperty = sym("mpv_get_property", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, UnsafeMutableRawPointer?) -> Int32).self),
        let observeProperty = sym("mpv_observe_property", as: (@convention(c) (OpaquePointer?, UInt64, UnsafePointer<CChar>?, Int32) -> Int32).self),
        let requestLogMessages = sym("mpv_request_log_messages", as: (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32).self),
        let waitEvent = sym("mpv_wait_event", as: (@convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?).self),
        let setWakeupCallback = sym("mpv_set_wakeup_callback", as: (@convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void).self)
  else {
    return (nil, "dlsym 缺函数（MPVKit 版本不对？）")
  }
  return (MPVKitAPI(
    create: create, initialize: initialize, terminateDestroy: terminateDestroy,
    setOption: setOption, setOptionString: setOptionString, command: command,
    setProperty: setProperty, getProperty: getProperty,
    observeProperty: observeProperty, requestLogMessages: requestLogMessages,
    waitEvent: waitEvent, setWakeupCallback: setWakeupCallback), nil)
}

/// mpv 渲染用的 Metal 层（照搬 MPVKit Demo 的 MetalLayer）：
/// MoltenVK 会把 drawableSize 压成 1x1 强行完成一帧，导致闪烁还可能
/// 一直停在 1x1，这里拦掉；EDR 开关必须在主线程改。
final class MPVMetalLayer: CAMetalLayer {
  override var drawableSize: CGSize {
    get { super.drawableSize }
    set {
      if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
        super.drawableSize = newValue
      }
    }
  }

  // wantsExtendedDynamicRangeContent 只有 iOS 16.0+ 才有，应用底线是
  // iOS 13.0——加 @available 让这个重写只在 16+ 生效，16 以下走基类
  // 默认行为（本来就没有 EDR）。
  @available(iOS 16.0, *)
  override var wantsExtendedDynamicRangeContent: Bool {
    get { super.wantsExtendedDynamicRangeContent }
    set {
      if Thread.isMainThread {
        super.wantsExtendedDynamicRangeContent = newValue
      } else {
        DispatchQueue.main.sync { super.wantsExtendedDynamicRangeContent = newValue }
      }
    }
  }
}

/// 承载 Metal 层的 view：layerClass 换成 MPVMetalLayer，尺寸变化时
/// 层跟着变（横竖屏旋转不用另处理）。
final class MPVVideoView: UIView {
  override class var layerClass: AnyClass { MPVMetalLayer.self }
  var metalLayer: MPVMetalLayer { layer as! MPVMetalLayer }
}

final class MPVEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private var mpv: OpaquePointer?
  private var api: MPVKitAPI?
  private var videoView: MPVVideoView?
  private var container: UIViewController?
  private var timer: Timer?
  private var eventQueue = DispatchQueue(label: "mpv-event", qos: .userInitiated)
  private var didFireEnded = false
  private var didFireError = false
  private var engineName = "mpv"
  private var videoW = 0
  private var videoH = 0

  // 诊断（v0.0.137）：136 真机证实 .log 事件到不了前端（open 标记是同步
  // 发的、不经过事件循环，它都没来），所以诊断改走 state 命令：mpv 日志
  // 留最近 30 行 + 总行数 + 事件循环是否跑起来过，前端轮询 state 读出来
  // 写进运行日志。事件循环标志只在首轮排空 ≥1 个事件时置位。
  private var eventLoopAlive = false
  private var logMessageCount = 0
  private var recentLogLines: [String] = []

  // 诊断（v0.0.139）：打开时的返回码与 URL 归属（只记 scheme/host，
  // 不记 path/query），以及事件循环累计排空数——区分“wakeup 后事件
  // 不再来”和“事件在走但没有日志行”。
  private var initResult: Int32 = -999
  private var loadfileResult: Int32 = -999
  private var openURLScheme: String = ""
  private var openURLHost: String = ""
  private var eventsDrainedTotal: Int = 0

  /// 分辨率：dwidth/dheight（mpv 实际显示尺寸），没拿到就报未知（.zero）。
  var videoSize: CGSize { CGSize(width: videoW, height: videoH) }

  var currentState: NativePlayerState {
    let position = getDouble("time-pos")
    let duration = getDouble("duration")
    let playing = mpv != nil && !getFlag("pause") && !getFlag("idle-active")
    return NativePlayerState(
      engine: engineName,
      playing: playing,
      position: position.isFinite ? position : 0,
      duration: duration.isFinite ? duration : 0,
      rate: getDouble("speed"),
      volume: getDouble("volume") / 100,
      muted: getFlag("mute"),
      videoWidth: videoW,
      videoHeight: videoH,
      mpvLogCount: logMessageCount,
      mpvLogLines: recentLogLines,
      mpvEventLoopAlive: eventLoopAlive,
      mpvIdleActive: getFlag("idle-active"),
      mpvVoConfigured: getFlag("vo-configured"),
      mpvPausedForCache: getFlag("paused-for-cache"),
      mpvEventsDrained: eventsDrainedTotal,
      mpvOpenDiag: "init=\(initResult) loadfile=\(loadfileResult) url=\(openURLScheme)://\(openURLHost)")
  }

  /// 引擎被插件丢掉也没调 close() 时也要把 libmpv 句柄销毁，
  /// 不然 wakeup 回调还会往已释放的 self 上打。
  deinit {
    timer?.invalidate()
    if let handle = mpv, let api = api {
      mpv = nil
      api.terminateDestroy(handle)
    }
  }

  func open(
    url: URL, position: Double, rate: Double, volume: Double, muted: Bool, title: String?,
    present: @escaping (UIViewController) -> Void,
    completion: @escaping (Result<NativePlayerState, Error>) -> Void
  ) {
    _ = title
    // 懒加载：到这里（用户选了 mpv）才 dlopen MPVKit.framework。
    // 启动时不走这里，所以启动完全不受 MPVKit 影响。
    let loaded = loadMPVKitAPI()
    guard let api = loaded.api else {
      completion(.failure(NativePlayerUnavailableError(
        message: "mpv 未接入：\(loaded.error ?? "MPVKit 加载失败")，详见 docs/developers/native-players.md")))
      return
    }
    self.api = api
    openURLScheme = url.scheme ?? ""
    openURLHost = url.host ?? ""
    initResult = -999
    loadfileResult = -999
    guard let handle = api.create() else {
      completion(.failure(NativePlayerUnavailableError(message: "mpv 创建失败")))
      return
    }
    // 渲染层先建好：wid 要的就是这个 CAMetalLayer。
    // 先 present 再 initialize：MoltenVK 建 swapchain 要层已有真实
    // 尺寸且已进窗口；0.0.133 是 initialize 在先、present 在后，
    // 层还没上屏、尺寸也未必对，swapchain 建坏了就再也出不了画面——
    // 只剩声音、时间照走（133 真机视频就是这样：mpv 徽标、1920x800、
    // 进度走到 23:35，画面全黑）。frame 直接取屏幕尺寸，不取尚未
    // layout 的 container.view.bounds。initialize 失败已 present
    // 过，要 dismiss 掉容器再报失败（loadfile 失败走 close()，里面
    // 本来就会 dismiss）。
    let videoView = MPVVideoView()
    let container = UIViewController()
    container.modalPresentationStyle = .fullScreen
    container.view.backgroundColor = .black
    videoView.frame = UIScreen.main.bounds
    videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.view.addSubview(videoView)
    self.videoView = videoView
    self.container = container
    present(container)
    container.view.layoutIfNeeded()

    var layer = videoView.metalLayer
    api.setOption(handle, "wid", MPV_FORMAT_INT64, &layer)
    api.setOptionString(handle, "vo", "gpu-next")
    api.setOptionString(handle, "gpu-api", "vulkan")
    api.setOptionString(handle, "gpu-context", "moltenvk")
    // 诊断（v0.0.140）：纯软解试播——关掉硬解，看《疯狂魔幻西哥》
    // 原画能不能播。UZN 的 mpv（0.41.0 系）能播同一文件，我们的
    // mpv（0.40.0 + videotoolbox 先硬解）播不了；先排除硬解接手
    // 卡住不回落这个可能。不是最终产品形态，验完再定怎么修。
    api.setOptionString(handle, "hwdec", "no")
    api.setOptionString(handle, "subs-match-os-language", "yes")
    api.setOptionString(handle, "subs-fallback", "yes")
    api.setOptionString(handle, "video-rotate", "no")
    // 诊断（v0.0.135 起）：mpv 日志常开、经事件写进运行日志。正式版
    // 以前是 "no"，黑画面只能靠猜；133/134 两轮都只剩声音没画面，
    // 原因只能看 mpv 自己的报错（VO/swapchain 那几行）。v0.0.140
    // 起正式版也开 debug 级：139 真机测时 info 级 0 行，解复用器
    // 探流、选解码器那几行只在 debug 级才有，播不了时没它们没法定位。
    api.requestLogMessages(handle, "debug")
    initResult = api.initialize(handle)
    guard initResult >= 0 else {
      api.terminateDestroy(handle)
      container.dismiss(animated: false, completion: nil)
      self.videoView = nil
      self.container = nil
      completion(.failure(NativePlayerUnavailableError(message: "mpv 初始化失败")))
      return
    }
    self.mpv = handle
    api.observeProperty(handle, 0, "dwidth", MPV_FORMAT_INT64)
    api.observeProperty(handle, 0, "dheight", MPV_FORMAT_INT64)
    api.setWakeupCallback(handle, { ctx in
      guard let ctx = ctx else { return }
      let engine = Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue()
      engine.readEvents()
    }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))

    // 回环 session 地址直接播：上游头/Range/密钥由 Rust 代理处理，
    // 不用再给 mpv 拼 http-header-fields。
    // loadfile 只是把命令排队（异步），返回 <0 才是参数级错误。
    loadfileResult = command(handle, "loadfile", args: [url.absoluteString, "replace"])
    if loadfileResult < 0 {
      close()
      completion(.failure(NativePlayerUnavailableError(message: "mpv 打开失败")))
      return
    }
    if position > 0 {
      _ = command(handle, "seek", args: ["\(position)", "absolute"])
    }
    setRate(rate)
    setVolume(volume, muted: muted)
    setFlag(handle, "pause", false)
    didFireEnded = false
    didFireError = false
    eventLoopAlive = false
    logMessageCount = 0
    recentLogLines = []
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      let state = self.currentState
      self.eventHandler?(.time(position: state.position, duration: state.duration, videoSize: self.videoSize))
      if !self.didFireEnded && state.duration > 0 && state.position >= state.duration - 0.3 {
        self.didFireEnded = true
        self.eventHandler?(.ended)
      }
    }
    completion(.success(currentState))
  }

  func play() {
    guard let handle = mpv else { return }
    setFlag(handle, "pause", false)
  }

  func pause() {
    guard let handle = mpv else { return }
    setFlag(handle, "pause", true)
  }

  func seek(to position: Double) {
    guard let handle = mpv else { return }
    _ = command(handle, "seek", args: ["\(position)", "absolute"])
  }

  func setRate(_ rate: Double) {
    guard let handle = mpv, let api = api else { return }
    var value = rate
    api.setProperty(handle, "speed", MPV_FORMAT_DOUBLE, &value)
  }

  func setVolume(_ volume: Double, muted: Bool) {
    guard let handle = mpv, let api = api else { return }
    var value = muted ? 0 : volume * 100
    api.setProperty(handle, "volume", MPV_FORMAT_DOUBLE, &value)
    setFlag(handle, "mute", muted)
  }

  func close() {
    timer?.invalidate()
    timer = nil
    // 先把引用清掉再销毁：后台事件循环每次循环都重读 self.mpv，
    // 读到 nil 就退出，不会再对已销毁的句柄调 mpv_wait_event。
    // terminate_destroy 会把阻塞在 wait_event 里的循环唤醒。
    let handle = mpv
    mpv = nil
    if let handle = handle, let api = api {
      _ = command(handle, "stop")
      api.terminateDestroy(handle)
    }
    api = nil
    videoView?.removeFromSuperview()
    videoView = nil
    container?.dismiss(animated: true, completion: nil)
    container = nil
    didFireEnded = false
    didFireError = false
    eventLoopAlive = false
    logMessageCount = 0
    recentLogLines = []
    initResult = -999
    loadfileResult = -999
    openURLScheme = ""
    openURLHost = ""
    eventsDrainedTotal = 0
    videoW = 0
    videoH = 0
  }

  // MARK: - libmpv 小工具（照搬 MPVKit Demo 的同名做法）

  private func getDouble(_ name: String) -> Double {
    guard let handle = mpv, let api = api else { return 0 }
    var data = Double()
    api.getProperty(handle, name, MPV_FORMAT_DOUBLE, &data)
    return data
  }

  private func getFlag(_ name: String) -> Bool {
    guard let handle = mpv, let api = api else { return false }
    var data = Int64()
    api.getProperty(handle, name, MPV_FORMAT_FLAG, &data)
    return data > 0
  }

  private func setFlag(_ handle: OpaquePointer, _ name: String, _ flag: Bool) {
    guard let api = api else { return }
    var data: Int = flag ? 1 : 0
    api.setProperty(handle, name, MPV_FORMAT_FLAG, &data)
  }

  /// 发一条 mpv 命令（argv 式）；返回 mpv 的错误码（0 成功，负数失败）。
  /// C 参数用 strdup/free 管理（Demo 同款）。
  @discardableResult
  private func command(_ handle: OpaquePointer, _ command: String, args: [String?] = []) -> Int32 {
    guard let api = api else { return -1 }
    var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
    defer {
      for ptr in cargs where ptr != nil {
        free(UnsafeMutablePointer(mutating: ptr!))
      }
    }
    return api.command(handle, &cargs)
  }

  private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
    if args.last == nil {
      fatalError("Command do not need a nil suffix")
    }
    var strArgs = args
    strArgs.insert(command, at: 0)
    strArgs.append(nil)
    return strArgs
  }

  /// mpv 事件排空（wakeup 回调进来后在后台队列跑）：只处理与本引擎
  /// 有关的几件——dwidth/dheight 变了记分辨率；播完/播错发事件；
  /// mpv 自己的日志（debug 级，v0.0.140 起正式版也开）经 .log 发回
  /// 前端写进运行日志。
  /// 其它事件直接丢掉，不打印。
  private func readEvents() {
    eventQueue.async { [weak self] in
      guard let self = self, let api = self.api else { return }
      var drained = 0
      while let handle = self.mpv {
        guard let rawEvent = api.waitEvent(handle, 0) else { break }
        let event = rawEvent.assumingMemoryBound(to: MPVEvent.self)
        if event.pointee.event_id == MPV_EVENT_NONE { break }
        drained += 1
        switch event.pointee.event_id {
        case MPV_EVENT_LOG_MESSAGE:
          guard let logMsg = UnsafePointer<MPVEventLogMessage>(OpaquePointer(event.pointee.data))?.pointee else { continue }
          let line = "\(String(cString: logMsg.prefix)): \(String(cString: logMsg.text).trimmingCharacters(in: .whitespacesAndNewlines))"
          DispatchQueue.main.async {
            self.logMessageCount += 1
            self.recentLogLines.append(line)
            if self.recentLogLines.count > 30 { self.recentLogLines.removeFirst(self.recentLogLines.count - 30) }
          }
        case MPV_EVENT_PROPERTY_CHANGE:
          guard let property = UnsafePointer<MPVEventProperty>(OpaquePointer(event.pointee.data))?.pointee else { continue }
          let name = String(cString: property.name)
          if name == "dwidth" || name == "dheight" {
            guard let value = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { continue }
            DispatchQueue.main.async {
              if name == "dwidth" { self.videoW = Int(value) } else { self.videoH = Int(value) }
            }
          }
        case MPV_EVENT_END_FILE:
          guard let endFile = UnsafePointer<MPVEventEndFile>(OpaquePointer(event.pointee.data))?.pointee else { continue }
          if endFile.reason == MPV_END_FILE_REASON_ERROR {
            DispatchQueue.main.async { self.fireError() }
          } else if endFile.reason == MPV_END_FILE_REASON_EOF {
            DispatchQueue.main.async { self.fireEnded() }
          }
        case MPV_EVENT_SHUTDOWN:
          // 句柄正在销毁：只把引用清掉就退出循环，不再碰它；
          // 真正的销毁只由 close()/deinit 做，不在这里重复 destroy。
          self.mpv = nil
          break
        default:
          break
        }
      }
      if drained > 0 {
        DispatchQueue.main.async {
          self.eventLoopAlive = true
          self.eventsDrainedTotal += drained
        }
      }
    }
  }

  private func fireEnded() {
    guard !didFireEnded else { return }
    didFireEnded = true
    eventHandler?(.ended)
  }

  private func fireError() {
    guard !didFireError else { return }
    didFireError = true
    eventHandler?(.error("mpv 播放失败"))
  }
}
