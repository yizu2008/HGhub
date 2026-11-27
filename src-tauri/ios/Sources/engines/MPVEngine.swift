// mpv 引擎（libmpv 原生 dylib + render API）：四个里格式和 ASS 字幕最强。
// v0.0.142 起换 UZN 的路：不再用 MPVKit XCFramework（28 个静态库打成的
// MPVKit.framework + wid + CAMetalLayer + gpu-api=vulkan + MoltenVK），
// 改嵌原生 dylib（libmpv.2.dylib + FFmpeg 全套，UZN 1.9.0 包里同款开
// 源库，见 src-tauri/ios/mpv-dylibs/），渲染走 libmpv render API
//（mpv_render_context_*）+ EAGLContext（OpenGL ES 3.0），vo=gpu-next
// + gpu-api=opengl。UZN 的 mpv 同为 0.41.0（已验），版本不是差别；
// 差别在接入方式——render API 由 App 自己掌控渲染循环，不依赖 wid
// 的层尺寸/上屏时序（133/134 的黑画面就是 wid 时序问题）。
// UZN 的做法还搬了两条（行为级重实现，没抄它闭源代码）：
// （1）hwdec 回退：硬解 videotoolbox 在 N 秒内出不了画面就自动切
// hwdec=no 软解重播（UZN 叫 hwdecRestoreRounds）；
// （2）打开失败时明确报错（渲染上下文建不起来、OpenGL ES 不可用、
// 初始化失败等），不静默卡住。
// DV 那条没搬：mpv 0.41.0 源码里没有 --dolby-vision-profile 这个
// 选项（已查 video/out + options），UZN 的 MPVForceDolbyVisionProfile5
// 是它自己的逻辑、静态看不出它到底改了 mpv 哪个设置，没法照搬；
// DV 片若硬解失败会走上面的 hwdec 回退进软解，日志里能看到编码。
// 详见 docs/developers/native-players.md 与
// ~/workspace/tmp/uzn/ANALYSIS.md。
//
// 懒加载（v0.0.127 起）：dylib 不静态链进主程序（v0.0.124/125 静态
// 链入后启动黑屏，126 摘掉就启动，已证实是它）。dylib 只嵌进
// .app/Frameworks/，启动时完全不碰；这里在用户第一次选 mpv 点播放
// 时才 dlopen libmpv.2.dylib + dlsym，加载失败就报 unavailable、
// 播放链回落 AVPlayer/WebView，绝不 crash。主程序里没有任何 mpv
// 符号（不 `import Libmpv`），所以启动与 126 完全一致。
// libmpv 的常量与结构体布局按 mpv 0.41.0 的 client.h / render.h /
// render_gl.h 手写（MPV_FORMAT_* / MPV_EVENT_* / MPV_END_FILE_REASON_* /
// mpv_event / mpv_event_property / mpv_event_end_file /
// mpv_render_param / mpv_opengl_init_params / mpv_opengl_fbo），
// 错一个字段就内存错乱，改版先核对头文件。client.h 与 render.h 已
// 随 0.41.0 源码取回（~/workspace/tmp/mpv-render-0.41.0.h、
// mpv-render-gl-0.41.0.h、mpv-client-0.41.0.h）。

import UIKit
import OpenGLES

/// libmpv 常量（client.h，mpv 0.41.0）：MPV_FORMAT_*。
private let MPV_FORMAT_STRING: Int32 = 1
private let MPV_FORMAT_FLAG: Int32 = 3
private let MPV_FORMAT_INT64: Int32 = 4
private let MPV_FORMAT_DOUBLE: Int32 = 5

/// libmpv 常量（client.h，mpv 0.41.0）：MPV_EVENT_*。
private let MPV_EVENT_NONE: Int32 = 0
private let MPV_EVENT_SHUTDOWN: Int32 = 1
private let MPV_EVENT_LOG_MESSAGE: Int32 = 2
private let MPV_EVENT_END_FILE: Int32 = 7
private let MPV_EVENT_PROPERTY_CHANGE: Int32 = 22

/// libmpv 常量（client.h，mpv 0.41.0）：MPV_END_FILE_REASON_*。
/// 注意 0.41.0 里 ERROR = 4（不是 3），STOP = 2，QUIT = 3，REDIRECT = 5。
private let MPV_END_FILE_REASON_EOF: Int32 = 0
private let MPV_END_FILE_REASON_ERROR: Int32 = 4

/// libmpv render API 常量（render.h，mpv 0.41.0）：mpv_render_param_type。
private let MPV_RENDER_PARAM_INVALID: Int32 = 0
private let MPV_RENDER_PARAM_API_TYPE: Int32 = 1
private let MPV_RENDER_PARAM_OPENGL_INIT_PARAMS: Int32 = 2
private let MPV_RENDER_PARAM_OPENGL_FBO: Int32 = 3
private let MPV_RENDER_PARAM_FLIP_Y: Int32 = 4

/// libmpv render API 常量（render.h，mpv 0.41.0）：
//  mpv_render_context_update() 返回的标志位。
private let MPV_RENDER_UPDATE_FRAME: UInt64 = 1 << 0

/// libmpv 事件结构（client.h，mpv 0.41.0）：mpv_event。
/// 字段顺序与类型必须与 C 完全一致：event_id(int)、error(int)、
/// reply_userdata(uint64_t)、data(void*)。
private struct MPVEvent {
  var event_id: Int32
  var error: Int32
  var reply_userdata: UInt64
  var data: UnsafeMutableRawPointer?
}

/// libmpv 事件结构（client.h，mpv 0.41.0）：mpv_event_property。
/// 字段：name(const char*)、format(mpv_format/int)、data(void*)。
private struct MPVEventProperty {
  var name: UnsafePointer<CChar>!
  var format: Int32
  var data: UnsafeMutableRawPointer?
}

/// libmpv 事件结构（client.h，mpv 0.41.0）：mpv_event_log_message。
/// 字段：prefix(const char*)、level(const char*)、text(const char*)、
/// log_level(mpv_log_level/int)。text 自带一个换行，转发前去掉。
private struct MPVEventLogMessage {
  var prefix: UnsafePointer<CChar>!
  var level: UnsafePointer<CChar>!
  var text: UnsafePointer<CChar>!
  var log_level: Int32
}

/// libmpv 事件结构（client.h，mpv 0.41.0）：mpv_event_end_file。
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

/// libmpv render API 结构（render.h，mpv 0.41.0）：mpv_render_param。
/// 字段：type(mpv_render_param_type/enum/int)、data(void*)。
/// 参数数组以 type==0（INVALID）结尾。
private struct MPVRenderParam {
  var type: Int32
  var data: UnsafeMutableRawPointer?
}

/// libmpv render API 结构（render_gl.h，mpv 0.41.0）：mpv_opengl_init_params。
/// 字段：get_proc_address(fn)、get_proc_address_ctx(void*)。
private struct MPVOpenGLInitParams {
  var get_proc_address: (@convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?)?
  var get_proc_address_ctx: UnsafeMutableRawPointer?
}

/// libmpv render API 结构（render_gl.h，mpv 0.41.0）：mpv_opengl_fbo。
/// 字段：fbo(int)、w(int)、h(int)、internal_format(int)。
private struct MPVOpenGLFBO {
  var fbo: Int32
  var w: Int32
  var h: Int32
  var internal_format: Int32
}

/// dlopen 后 dlsym 出来的 libmpv 函数表：每个函数一个 @convention(c)
/// 函数指针。加载时逐个 dlsym、缺一个就整体失败（不调空指针）。
/// 前 12 个是核心 API（141 同款），后 6 个是 render API（142 新增）。
private struct MPVAPI {
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
  let renderContextCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<MPVRenderParam>?) -> Int32
  let renderContextFree: @convention(c) (OpaquePointer?) -> Void
  let renderContextRender: @convention(c) (OpaquePointer?, UnsafeMutablePointer<MPVRenderParam>?) -> Int32
  let renderContextSetUpdateCallback: @convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void
  let renderContextUpdate: @convention(c) (OpaquePointer?) -> UInt64
  let renderContextReportSwap: @convention(c) (OpaquePointer?) -> Void
}

/// mpv OpenGL 后端要的 get_proc_address：从 OpenGLES.framework 里
/// dlsym 出 GL 函数指针。ctx 是 dlopen 出来的 OpenGLES 句柄；拿不到
/// 就走 RTLD_DEFAULT（全局符号表，-2）。libmpv 自己不链 GL 库，
/// 全靠这个回调解析函数。
private let mpvGLGetProcAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { ctx, name in
  guard let name = name else { return nil }
  if let ctx = ctx {
    return dlsym(ctx, name)
  }
  return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
}

/// dlopen 原生 libmpv.2.dylib 并 dlsym 出全部 libmpv 函数。
/// 失败返回 nil（附 dlerror 原因，调用方写进 unavailable 错误）。
/// 只在用户选 mpv 播放时调（open 入口），启动时绝不调。
/// 不 dlclose：播完不卸载，进程生命周期内常驻（重复 dlopen 同一路
/// 径本就会返回同一 handle）。
private func loadMPVAPI() -> (api: MPVAPI?, error: String?) {
  guard let path = Bundle.main.path(
    forResource: "libmpv.2", ofType: "dylib",
    inDirectory: "Frameworks")
  else {
    return (nil, "libmpv.2.dylib 不在包里")
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
        let setWakeupCallback = sym("mpv_set_wakeup_callback", as: (@convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void).self),
        let renderContextCreate = sym("mpv_render_context_create", as: (@convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<MPVRenderParam>?) -> Int32).self),
        let renderContextFree = sym("mpv_render_context_free", as: (@convention(c) (OpaquePointer?) -> Void).self),
        let renderContextRender = sym("mpv_render_context_render", as: (@convention(c) (OpaquePointer?, UnsafeMutablePointer<MPVRenderParam>?) -> Int32).self),
        let renderContextSetUpdateCallback = sym("mpv_render_context_set_update_callback", as: (@convention(c) (OpaquePointer?, (@convention(c) (UnsafeMutableRawPointer?) -> Void)?, UnsafeMutableRawPointer?) -> Void).self),
        let renderContextUpdate = sym("mpv_render_context_update", as: (@convention(c) (OpaquePointer?) -> UInt64).self),
        let renderContextReportSwap = sym("mpv_render_context_report_swap", as: (@convention(c) (OpaquePointer?) -> Void).self)
  else {
    return (nil, "dlsym 缺函数（libmpv 版本不对？）")
  }
  return (MPVAPI(
    create: create, initialize: initialize, terminateDestroy: terminateDestroy,
    setOption: setOption, setOptionString: setOptionString, command: command,
    setProperty: setProperty, getProperty: getProperty,
    observeProperty: observeProperty, requestLogMessages: requestLogMessages,
    waitEvent: waitEvent, setWakeupCallback: setWakeupCallback,
    renderContextCreate: renderContextCreate, renderContextFree: renderContextFree,
    renderContextRender: renderContextRender,
    renderContextSetUpdateCallback: renderContextSetUpdateCallback,
    renderContextUpdate: renderContextUpdate,
    renderContextReportSwap: renderContextReportSwap), nil)
}

/// mpv render API 用的 GL 视图：CAEAGLLayer + EAGLContext（OpenGL ES 3.0，
/// 不行就 2.0）+ 自己管的 FBO/颜色 renderbuffer。mpv 的帧经
/// mpv_render_context_render() 画进这个 FBO，再 presentRenderbuffer
/// 上屏。全部 GL 调用与 render-context 调用都在一条专用串行队列
/// glQueue 上跑（EAGLContext 只认一个线程），主线程只负责布局。
/// 尺寸变化时（旋转）layoutSubviews 会把新像素尺寸发给 glQueue 重建 FBO。
final class MPVGLView: UIView {
  override class var layerClass: AnyClass { CAEAGLLayer.self }
  /// 层在 init（主线程）后抓出来存着：rebuildFramebuffer 在 glQueue
  /// 上跑，UIView 的 layer 属性不能在后台线程读。
  private var glLayer: CAEAGLLayer!

  /// 渲染线程：GL 上下文与 mpv render-context 的调用都在这里。
  let glQueue = DispatchQueue(label: "mpv-gl", qos: .userInitiated)
  private var glContext: EAGLContext?
  private var glHandle: UnsafeMutableRawPointer?
  private var framebuffer: GLuint = 0
  private var colorRenderbuffer: GLuint = 0
  private var pixelW: Int = 0
  private var pixelH: Int = 0
  private var glReady = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    // layerClass 已换成 CAEAGLLayer，这里拿到的就是本视图的层。
    glLayer = layer as! CAEAGLLayer
    backgroundColor = .black
    glLayer.isOpaque = true
    glLayer.drawableProperties = [
      kEAGLDrawablePropertyRetainedBacking: false,
      kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
    ]
    // OpenGLES.framework 的 dlopen 句柄：给 mpv 的 get_proc_address 用。
    // 失败也不致命（回落 RTLD_DEFAULT），所以这里不报失败。
    glHandle = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW)
  }

  required init?(coder: NSCoder) { nil }

  /// 布局变了（旋转/尺寸）就重建 FBO。主线程调，实际重建走 glQueue。
  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = contentScaleFactor
    let w = max(1, Int(bounds.width * scale))
    let h = max(1, Int(bounds.height * scale))
    glQueue.async { [weak self] in
      guard let self = self else { return }
      if w != self.pixelW || h != self.pixelH {
        self.pixelW = w
        self.pixelH = h
        self.rebuildFramebuffer()
      }
    }
  }

  /// 在 glQueue 上建 EAGLContext 并设为当前、建 FBO。返回上下文是否可用。
  /// open() 里在创建 render-context 之前调（render API 要求建上下文时
  /// GL 上下文已是当前）。
  func setupGL() -> Bool {
    // 尺寸在调用线程（主线程）读，UIView 属性不能在后台线程碰。
    let scale = contentScaleFactor
    let w = max(1, Int(bounds.width * scale))
    let h = max(1, Int(bounds.height * scale))
    var ok = false
    glQueue.sync {
      if glContext == nil {
        glContext = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)
      }
      guard let ctx = glContext, EAGLContext.setCurrent(ctx) else { return }
      if framebuffer == 0 {
        pixelW = w
        pixelH = h
        rebuildFramebuffer()
      }
      ok = glReady
    }
    return ok
  }

  /// get_proc_address 的 ctx：OpenGLES 的 dlopen 句柄（没有就 nil，
  /// 回调里走 RTLD_DEFAULT）。
  var glProcAddressContext: UnsafeMutableRawPointer? { glHandle }

  /// 让 GL 上下文在 glQueue 上成为当前。render 前调。
  func makeCurrent() -> Bool {
    guard let ctx = glContext else { return false }
    return EAGLContext.setCurrent(ctx)
  }

  /// FBO/颜色 renderbuffer 重建（glQueue 上跑，调用时 GL 上下文已是当前）。
  private func rebuildFramebuffer() {
    guard let ctx = glContext, EAGLContext.setCurrent(ctx) else { return }
    destroyFramebuffer()
    glGenFramebuffers(1, &framebuffer)
    glGenRenderbuffers(1, &colorRenderbuffer)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
    glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorRenderbuffer)
    ctx.renderbufferStorage(Int(GL_RENDERBUFFER), from: glLayer)
    glFramebufferRenderbuffer(
      GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0),
      GLenum(GL_RENDERBUFFER), colorRenderbuffer)
    glReady = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
    if !glReady {
      destroyFramebuffer()
    }
  }

  private func destroyFramebuffer() {
    if framebuffer != 0 {
      glDeleteFramebuffers(1, &framebuffer)
      framebuffer = 0
    }
    if colorRenderbuffer != 0 {
      glDeleteRenderbuffers(1, &colorRenderbuffer)
      colorRenderbuffer = 0
    }
    glReady = false
  }

  /// 当前 FBO 的像素尺寸（render 参数用）。glQueue 上读。
  var fboSize: (w: Int, h: Int) { (pixelW, pixelH) }

  /// 当前 FBO 名（render 参数用）。glQueue 上读。
  var fboName: GLuint { framebuffer }

  /// GL 是否就绪（上下文 + FBO 完好）。glQueue 上读。
  var isGLReady: Bool { glReady }

  /// 把 renderbuffer 上屏（glQueue 上跑，render 之后调）。
  func presentFramebuffer() {
    glContext?.presentRenderbuffer(Int(GL_RENDERBUFFER))
  }

  /// 释放 FBO/renderbuffer（close 时在 glQueue 上调；deinit 时也调一次，
  /// 抓的是纯值，不碰已释放的 self）。
  func teardownGL() {
    glQueue.async { [weak self] in
      guard let self = self else { return }
      guard let ctx = self.glContext, EAGLContext.setCurrent(ctx) else { return }
      self.destroyFramebuffer()
    }
  }

  deinit {
    let ctx = glContext
    let fbo = framebuffer
    let rbo = colorRenderbuffer
    glQueue.async {
      guard let ctx = ctx, EAGLContext.setCurrent(ctx) else { return }
      var fbo = fbo
      var rbo = rbo
      if fbo != 0 { glDeleteFramebuffers(1, &fbo) }
      if rbo != 0 { glDeleteRenderbuffers(1, &rbo) }
    }
  }
}

final class MPVEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private var mpv: OpaquePointer?
  private var api: MPVAPI?
  private var renderContext: OpaquePointer?
  private var glView: MPVGLView?
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
  private var renderResult: Int32 = -999
  private var openURLScheme: String = ""
  private var openURLHost: String = ""
  private var eventsDrainedTotal: Int = 0

  // hwdec 回退（v0.0.142，UZN 的做法）：硬解 videotoolbox 在 8 秒内
  // 出不了画面（有数据、有时长、就是没视频轨）就自动切 hwdec=no 软解
  // 重播一次。只触发一次；触发后 hwdecFallback=true，写进诊断行。
  private var currentURL: URL?
  private var loadfileAt: Date?
  private var hwdecMode = "videotoolbox"
  private var hwdecFallbackDone = false
  private var hwdecFallback = false

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
      mpvOpenDiag: "init=\(initResult) loadfile=\(loadfileResult) render=\(renderResult) hwdec=\(hwdecMode)\(hwdecFallback ? "(fallback)" : "") url=\(openURLScheme)://\(openURLHost)")
  }

  /// 引擎被插件丢掉也没调 close() 时也要把 libmpv 句柄销毁，
  /// 不然 wakeup 回调还会往已释放的 self 上打。
  /// render-context 必须在 terminate_destroy 之前 free（render.h）。
  deinit {
    timer?.invalidate()
    if let renderContext = renderContext, let api = api, let glView = glView {
      glView.glQueue.sync {
        api.renderContextFree(renderContext)
      }
      self.renderContext = nil
    }
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
    // 懒加载：到这里（用户选了 mpv）才 dlopen libmpv.2.dylib。
    // 启动时不走这里，所以启动完全不受 mpv 影响。
    let loaded = loadMPVAPI()
    guard let api = loaded.api else {
      completion(.failure(NativePlayerUnavailableError(
        message: "mpv 未接入：\(loaded.error ?? "libmpv 加载失败")，详见 docs/developers/native-players.md")))
      return
    }
    self.api = api
    openURLScheme = url.scheme ?? ""
    openURLHost = url.host ?? ""
    initResult = -999
    loadfileResult = -999
    renderResult = -999
    currentURL = url
    hwdecMode = "videotoolbox"
    hwdecFallbackDone = false
    hwdecFallback = false
    guard let handle = api.create() else {
      completion(.failure(NativePlayerUnavailableError(message: "mpv 创建失败")))
      return
    }
    // 渲染层先建好：render API 的 FBO 要从这个 CAEAGLLayer 的
    // drawable 上建。先 present 再 initialize：层要已有真实尺寸且
    // 已进窗口，FBO 才建得出来；133 的 wid 版就是 present 在后导致
    // swapchain 建坏、只剩声音没画面。frame 直接取屏幕尺寸，不取
    // 尚未 layout 的 container.view.bounds。initialize 失败已 present
    // 过，要 dismiss 掉容器再报失败（loadfile 失败走 close()，里面
    // 本来就会 dismiss）。
    let glView = MPVGLView()
    let container = UIViewController()
    container.modalPresentationStyle = .fullScreen
    container.view.backgroundColor = .black
    glView.frame = UIScreen.main.bounds
    glView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.view.addSubview(glView)
    self.glView = glView
    self.container = container
    present(container)
    container.view.layoutIfNeeded()
    guard glView.setupGL() else {
      api.terminateDestroy(handle)
      container.dismiss(animated: false, completion: nil)
      self.glView = nil
      self.container = nil
      completion(.failure(NativePlayerUnavailableError(message: "mpv 渲染层建不起来（OpenGL ES 不可用）")))
      return
    }

    api.setOptionString(handle, "vo", "gpu-next")
    api.setOptionString(handle, "gpu-api", "opengl")
    // v0.0.142：硬解 videotoolbox（H.264/HEVC 硬解；AV1 等走 dav1d
    // 软解）。出不了画面时由下面的 hwdec 回退切软解重播。
    api.setOptionString(handle, "hwdec", "videotoolbox")
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
      self.glView = nil
      self.container = nil
      completion(.failure(NativePlayerUnavailableError(message: "mpv 初始化失败")))
      return
    }
    self.mpv = handle
    // render-context 必须在 GL 上下文是当前时建（render_gl.h），且
    // 只能在渲染线程（glQueue）上调。建失败就当 mpv 不可用——不回落
    // wid（142 已去掉 wid 路），播放链会回落 AVPlayer/WebView。
    var newRenderContext: OpaquePointer? = nil
    var apiType: [CChar] = Array("opengl".utf8CString)
    renderResult = apiType.withUnsafeMutableBufferPointer { apiTypePtr in
      let apiTypeData = UnsafeMutableRawPointer(apiTypePtr.baseAddress)
      var result: Int32 = -1
      glView.glQueue.sync {
        guard glView.makeCurrent() else { return }
        var initParams = MPVOpenGLInitParams(
          get_proc_address: mpvGLGetProcAddress,
          get_proc_address_ctx: glView.glProcAddressContext)
        var params: [MPVRenderParam] = [
          MPVRenderParam(type: MPV_RENDER_PARAM_API_TYPE, data: apiTypeData),
          MPVRenderParam(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &initParams),
          MPVRenderParam(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        result = api.renderContextCreate(&newRenderContext, handle, &params)
      }
      return result
    }
    guard renderResult >= 0, let renderContext = newRenderContext else {
      api.terminateDestroy(handle)
      self.mpv = nil
      container.dismiss(animated: false, completion: nil)
      self.glView = nil
      self.container = nil
      completion(.failure(NativePlayerUnavailableError(message: "mpv 渲染上下文建不起来")))
      return
    }
    self.renderContext = renderContext
    api.renderContextSetUpdateCallback(renderContext, { ctx in
      guard let ctx = ctx else { return }
      let engine = Unmanaged<MPVEngine>.fromOpaque(ctx).takeUnretainedValue()
      engine.renderFrame()
    }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
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
    loadfileAt = Date()
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
      self.maybeFallbackHwdec(state: state)
      if !self.didFireEnded && state.duration > 0 && state.position >= state.duration - 0.3 {
        self.didFireEnded = true
        self.eventHandler?(.ended)
      }
    }
    completion(.success(currentState))
  }

  /// hwdec 回退：loadfile 8 秒后仍没视频轨（有数据、有时长、播着），
  /// 且硬解还是 videotoolbox，就切 hwdec=no 软解重播一次。
  /// 只触发一次；纯音频/还没拿到数据时不触发。
  private func maybeFallbackHwdec(state: NativePlayerState) {
    guard !hwdecFallbackDone,
          let at = loadfileAt,
          let handle = mpv,
          let url = currentURL,
          Date().timeIntervalSince(at) > 8,
          hwdecMode == "videotoolbox",
          state.playing, state.duration > 0, videoW == 0
    else { return }
    hwdecFallbackDone = true
    hwdecFallback = true
    hwdecMode = "no"
    setStringProperty(handle, "hwdec", "no")
    loadfileResult = command(handle, "loadfile", args: [url.absoluteString, "replace"])
    loadfileAt = Date()
  }

  /// mpv 发来新帧通知（update 回调，不在回调里调 mpv API，只派发）：
  /// 在渲染线程上 update + 画一帧。
  private func renderFrame() {
    guard let glView = glView else { return }
    glView.glQueue.async { [weak self] in
      guard let self = self, let api = self.api,
            let renderContext = self.renderContext, self.mpv != nil,
            let glView = self.glView,
            glView.makeCurrent()
      else { return }
      let flags = api.renderContextUpdate(renderContext)
      guard flags & MPV_RENDER_UPDATE_FRAME != 0 else { return }
      guard glView.isGLReady else { return }
      let size = glView.fboSize
      var fbo = MPVOpenGLFBO(
        fbo: Int32(glView.fboName), w: Int32(size.w), h: Int32(size.h),
        internal_format: 0)
      var flip: Int32 = 1
      var params: [MPVRenderParam] = [
        MPVRenderParam(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fbo),
        MPVRenderParam(type: MPV_RENDER_PARAM_FLIP_Y, data: &flip),
        MPVRenderParam(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      let result = api.renderContextRender(renderContext, &params)
      if result >= 0 {
        glView.presentFramebuffer()
        api.renderContextReportSwap(renderContext)
      }
    }
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
    // render-context 必须在 terminate_destroy 之前 free，且要在
    // 渲染线程（glQueue）上 free——sync 等队列里已排队的渲染跑完，
    // 再 free，不会 free 掉正在画的上下文。
    let handle = mpv
    mpv = nil
    if let renderContext = renderContext, let api = api, let glView = glView {
      glView.glQueue.sync {
        api.renderContextFree(renderContext)
      }
      self.renderContext = nil
    }
    if let handle = handle, let api = api {
      _ = command(handle, "stop")
      api.terminateDestroy(handle)
    }
    api = nil
    glView?.teardownGL()
    glView?.removeFromSuperview()
    glView = nil
    container?.dismiss(animated: true, completion: nil)
    container = nil
    didFireEnded = false
    didFireError = false
    eventLoopAlive = false
    logMessageCount = 0
    recentLogLines = []
    initResult = -999
    loadfileResult = -999
    renderResult = -999
    openURLScheme = ""
    openURLHost = ""
    eventsDrainedTotal = 0
    currentURL = nil
    loadfileAt = nil
    hwdecMode = "videotoolbox"
    hwdecFallbackDone = false
    hwdecFallback = false
    videoW = 0
    videoH = 0
  }

  // MARK: - libmpv 小工具

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

  /// 运行时改一个字符串属性（hwdec 回退用）。MPV_FORMAT_STRING=1，
  /// data 是 char**（指向 C 字符串指针的指针）。
  private func setStringProperty(_ handle: OpaquePointer, _ name: String, _ value: String) {
    guard let api = api else { return }
    var cValue: [CChar] = Array(value.utf8CString)
    cValue.withUnsafeMutableBufferPointer { buf in
      var ptr: UnsafePointer<CChar>? = buf.baseAddress
      api.setProperty(handle, name, MPV_FORMAT_STRING, &ptr)
    }
  }

  /// 发一条 mpv 命令（argv 式）；返回 mpv 的错误码（0 成功，负数失败）。
  /// C 参数用 strdup/free 管理。
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
