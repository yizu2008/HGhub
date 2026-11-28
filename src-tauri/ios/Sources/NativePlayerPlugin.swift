// iOS 原生播放器插件：Tauri 移动插件，名字 "native-player"。
// 写法对照本地 Tauri 2.12.5 的官方模板：
//   - 基类 / 事件：tauri-2.12.5/mobile/ios-api/Sources/Tauri/Plugin/Plugin.swift
//    （`open class Plugin`，`trigger(_:data:)`，`manager.viewController`）
//   - 调用约定：tauri-plugin-dialog-2.8.3/ios/Sources/DialogPlugin.swift
//    （`@objc func xxx(_ invoke: Invoke) throws`，`invoke.parseArgs` /
//     `invoke.resolve` / `invoke.reject`，结尾的
//     `@_cdecl("init_plugin_...") public func initNativePlayerPlugin() -> Plugin`）
// Rust 侧见 src-tauri/src/native_player.rs：
//   `tauri::ios_plugin_binding!(init_plugin_native_player)` +
//   `api.register_ios_plugin(init_plugin_native_player)`。
//
// 本机无 Xcode/Swift 工具链：本文件未编译，由 src-tauri/build.rs 在
// macOS 构建时经 SwiftLinker 编成静态库链进 Rust（见
// docs/developers/native-players.md）。

import Tauri
import UIKit

// MARK: - 与 Rust / 前端对齐的模型

/// Rust open_payload 发来的 JSON。注意 Rust 用 snake_case（session_id），
/// 这里用 CodingKeys 映射，字段名本身与前端 NativePlayerOpenOptions 一致。
struct NativePlayerOpenArgs: Decodable {
  var engine: String
  var url: String
  var sessionId: String
  var position: Double
  var rate: Double
  var volume: Double
  var muted: Bool
  var title: String?
  /// mpv 硬件加速（v0.0.146）：true = videotoolbox-copy，false = 软解；
  /// 缺省 true（旧前端没发这个键时默认硬解）。其它引擎忽略。
  var hardwareAcceleration: Bool?

  enum CodingKeys: String, CodingKey {
    case engine, url, position, rate, volume, muted, title
    case sessionId = "session_id"
    case hardwareAcceleration = "hardware_acceleration"
  }
}

struct NativePlayerSeekArgs: Decodable {
  var position: Double
}

struct NativePlayerRateArgs: Decodable {
  var rate: Double
}

struct NativePlayerVolumeArgs: Decodable {
  var volume: Double
  var muted: Bool
}

/// 与 Rust NativePlayerState 对齐的模型。注意：本 struct 无 CodingKeys，
/// 编码后键名就是 Swift 属性名（videoWidth/videoHeight 驼峰）；Rust 侧
/// 用 serde rename_all="camelCase" 对齐，不要改成 snake_case，否则
/// Rust 解回包时报 missing field `video_width`。
struct NativePlayerState: Encodable {
  var engine: String?
  var playing: Bool
  var position: Double
  var duration: Double
  var rate: Double
  var volume: Double
  var muted: Bool
  /// 当前视频原始分辨率（像素）；0 表示未知。
  var videoWidth: Int
  var videoHeight: Int
  /// mpv 诊断（v0.0.137 起）：.log 事件到不了前端，改走 state 命令。
  /// 最近 30 行 mpv 日志 + 总行数 + 事件循环是否跑起来过；其它引擎恒为默认。
  var mpvLogCount: Int = 0
  var mpvLogLines: [String] = []
  var mpvEventLoopAlive: Bool = false
  /// mpv 诊断（v0.0.139 起）：138 真机 mpv 日志行数恒为 0，靠日志行定位
  /// 到此为止，改直接读 mpv 状态量。idle-active / vo-configured /
  /// paused-for-cache 三个 mpv 属性 + 事件循环累计排空数 + 打开时的
  /// initialize/loadfile 返回码与 URL scheme/host（只记 host，不记
  /// path/query）；其它引擎恒为默认。
  var mpvIdleActive: Bool = false
  var mpvVoConfigured: Bool = false
  var mpvPausedForCache: Bool = false
  var mpvEventsDrained: Int = 0
  var mpvOpenDiag: String = ""
}

// MARK: - 引擎事件（经 trigger 发回前端，见前端 nativePlayer.ts）

struct NativePlayerTimeEvent: Encodable {
  var engine: String
  var sessionId: String
  var position: Double
  var duration: Double
  /// 当前视频原始分辨率（像素）；0 表示未知。
  var videoWidth: Int
  var videoHeight: Int
}

struct NativePlayerEndEvent: Encodable {
  var engine: String
  var sessionId: String
  var position: Double
}

struct NativePlayerErrorEvent: Encodable {
  var engine: String
  var sessionId: String
  var message: String
}

struct NativePlayerClosedEvent: Encodable {
  var engine: String
  var sessionId: String
  var position: Double
}

/// mpv 自己的日志行（诊断用，见 MPVEngine 的 requestLogMessages）：
/// message 是 "前缀: 内容"，前端写进运行日志，不触发播放失败。
struct NativePlayerLogEvent: Encodable {
  var engine: String
  var sessionId: String
  var message: String
}

enum NativePlayerEvent {
  case time(position: Double, duration: Double, videoSize: CGSize)
  case ended
  case error(String)
  case closed
  case log(String)
}

// MARK: - 统一引擎协议：四个引擎都实现它，插件只认这个接口

protocol NativePlayerEngine: AnyObject {
  var eventHandler: ((NativePlayerEvent) -> Void)? { get set }
  var currentState: NativePlayerState { get }
  /// 当前视频原始分辨率；未知时为 .zero（前端与覆盖层按 0 处理为不显示）。
  var videoSize: CGSize { get }
  func open(
    url: URL, position: Double, rate: Double, volume: Double, muted: Bool, title: String?,
    hardwareAcceleration: Bool,
    present: @escaping (UIViewController) -> Void,
    completion: @escaping (Result<NativePlayerState, Error>) -> Void
  )
  func play()
  func pause()
  func seek(to position: Double)
  func setRate(_ rate: Double)
  func setVolume(_ volume: Double, muted: Bool)
  func close()
}

struct NativePlayerUnavailableError: LocalizedError {
  var message: String
  var errorDescription: String? { message }
}

// MARK: - 插件本体

class NativePlayerPlugin: Plugin {
  private var engine: (any NativePlayerEngine)?
  private var engineName: String?
  private var sessionId: String?
  private var lastPosition: Double = 0
  private var lastDuration: Double = 0

  private func makeEngine(_ name: String) -> (any NativePlayerEngine)? {
    switch name {
    case "avplayer": return AVPlayerEngine()
    case "mdk": return MDKEngine()
    case "ksplayer": return KSPlayerEngine()
    case "mpv": return MPVEngine()
    case "aether": return AetherPlayerEngine()
    default: return nil
    }
  }

  private func present(_ viewController: UIViewController) {
    manager.viewController?.present(viewController, animated: true, completion: nil)
  }

  private func forwardEvent(_ event: NativePlayerEvent) {
    guard let engineName = engineName, let sessionId = sessionId else { return }
    do {
      switch event {
      case .time(let position, let duration, let videoSize):
        lastPosition = position
        lastDuration = duration
        try trigger(
          "native-player-time",
          data: NativePlayerTimeEvent(
            engine: engineName, sessionId: sessionId, position: position, duration: duration,
            videoWidth: Int(videoSize.width), videoHeight: Int(videoSize.height)))
      case .ended:
        lastPosition = engine?.currentState.position ?? lastPosition
        try trigger(
          "native-player-ended",
          data: NativePlayerEndEvent(
            engine: engineName, sessionId: sessionId, position: lastPosition))
        engine = nil
      case .error(let message):
        try trigger(
          "native-player-error",
          data: NativePlayerErrorEvent(
            engine: engineName, sessionId: sessionId, message: message))
        engine = nil
      case .closed:
        lastPosition = engine?.currentState.position ?? lastPosition
        try trigger(
          "native-player-closed",
          data: NativePlayerClosedEvent(
            engine: engineName, sessionId: sessionId, position: lastPosition))
        engine = nil
      case .log(let message):
        // 只转发、不结束播放：mpv 日志不是播放失败。
        try trigger(
          "native-player-log",
          data: NativePlayerLogEvent(
            engine: engineName, sessionId: sessionId, message: message))
      }
    } catch {
      // 事件发不出去不影响播放本身；播放状态仍可由 state 命令查询。
    }
  }

  private func requireEngine(_ invoke: Invoke) -> (any NativePlayerEngine)? {
    guard let engine = engine else {
      invoke.reject("没有正在播放的原生播放器")
      return nil
    }
    return engine
  }

  private func resolveState(_ invoke: Invoke, from engine: (any NativePlayerEngine)? = nil) {
    if let engine = engine ?? self.engine {
      invoke.resolve(engine.currentState)
    } else {
      invoke.resolve(
        NativePlayerState(
          engine: engineName, playing: false, position: lastPosition, duration: lastDuration,
          rate: 1, volume: 1, muted: false, videoWidth: 0, videoHeight: 0))
    }
  }

  @objc public func open(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NativePlayerOpenArgs.self)
    guard let url = URL(string: args.url) else {
      invoke.reject("无效的播放地址")
      return
    }
    guard let next = makeEngine(args.engine) else {
      invoke.reject("未知的播放引擎：\(args.engine)")
      return
    }
    DispatchQueue.main.async {
      self.engine?.close()
      self.engine = next
      self.engineName = args.engine
      self.sessionId = args.sessionId
      self.lastPosition = args.position
      self.lastDuration = 0
      next.eventHandler = { [weak self] event in self?.forwardEvent(event) }
      next.open(
        url: url, position: args.position, rate: args.rate, volume: args.volume,
        muted: args.muted, title: args.title, hardwareAcceleration: args.hardwareAcceleration ?? true,
        present: { [weak self] viewController in self?.present(viewController) }
      ) { result in
        switch result {
        case .success(let state):
          self.lastPosition = state.position
          self.lastDuration = state.duration
          invoke.resolve(state)
        case .failure(let error):
          self.engine = nil
          invoke.reject(error.localizedDescription)
        }
      }
    }
  }

  @objc public func close(_ invoke: Invoke) throws {
    DispatchQueue.main.async {
      self.engine?.close()
      self.engine = nil
      invoke.resolve()
    }
  }

  @objc public func play(_ invoke: Invoke) throws {
    guard let engine = requireEngine(invoke) else { return }
    DispatchQueue.main.async {
      engine.play()
      self.resolveState(invoke, from: engine)
    }
  }

  @objc public func pause(_ invoke: Invoke) throws {
    guard let engine = requireEngine(invoke) else { return }
    DispatchQueue.main.async {
      engine.pause()
      self.resolveState(invoke, from: engine)
    }
  }

  @objc public func seek(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NativePlayerSeekArgs.self)
    guard let engine = requireEngine(invoke) else { return }
    DispatchQueue.main.async {
      engine.seek(to: args.position)
      self.resolveState(invoke, from: engine)
    }
  }

  @objc public func setRate(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NativePlayerRateArgs.self)
    guard let engine = requireEngine(invoke) else { return }
    DispatchQueue.main.async {
      engine.setRate(args.rate)
      self.resolveState(invoke, from: engine)
    }
  }

  @objc public func setVolume(_ invoke: Invoke) throws {
    let args = try invoke.parseArgs(NativePlayerVolumeArgs.self)
    guard let engine = requireEngine(invoke) else { return }
    DispatchQueue.main.async {
      engine.setVolume(args.volume, muted: args.muted)
      self.resolveState(invoke, from: engine)
    }
  }

  @objc public func state(_ invoke: Invoke) throws {
    resolveState(invoke)
  }
}

/// Rust 侧 `tauri::ios_plugin_binding!(init_plugin_native_player)` 找的就是
/// 这个符号；C 符号名改了要同步改 Rust 侧的宏参数。Swift 函数名本身
/// 在包内必须唯一（OrientationPlugin 里的同名函数叫 initOrientationPlugin）。
@_cdecl("init_plugin_native_player")
public func initNativePlayerPlugin() -> Plugin {
  return NativePlayerPlugin()
}
