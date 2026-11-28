// AetherEngine 引擎（v0.0.148）：Vincent Herbst 的独立开源引擎
// （github.com/superuser404notfound/AetherEngine，LGPL-3.0 + App Store
// 例外），FFmpeg n8.1.3 + VideoToolbox 硬解 + dav1d 软解，DV P7→8.1
// 转换、多声道输出。只接 6.x 线（6.89.1）：上游 7.x 要求 iOS 18，
// 用户手机 16.6.1 跑不了；6.x 要求 iOS 16（见 Package.swift）。
// 上游没有 hardwareDecoding / multichannelAudio 这两个开关名（那是
// ReelFlow 自己包的宿主层名字）：硬解/软解由 LoadOptions
// .preferredDecodePath 控制——.automatic（默认）开播时按编码分流，
// H.264/HEVC/硬件能解的 AV1 走原生路（VideoToolbox 硬解），其余走
// 软解；原生路拒绝时引擎自动升级到软解路重建一次（6.x 是内置行为，
// 没有 escalatesToSoftwarePath 这个开关名）。所以这里永远用
// .automatic，硬件加速开关（只对 mpv 生效）在此忽略。
// 上游类是 @MainActor：所有 engine 调用都走 Task { @MainActor in }
//（插件已保证在主线程调引擎方法，但主线程 ≠ actor 隔离）；
// currentState 只读 0.5s 轮询缓存的值，不碰 engine，state 命令在
// 任何线程调都安全。控制层复用 MPVControlOverlay（146 给 mpv 做的
// 那套，见 NativePlayerControlTarget），AVPlayer 仍用系统控制条。
// 引擎是单例复用设计（上游建议一个 App 生命周期只建一个），但插件
// 的生命周期是每次 open 建新引擎、close 拆掉；这里沿用插件的规矩，
// close 时 stop + unbind，旧实例随插件引用释放。
// 本机无 Xcode/Swift 工具链：本文件未编译，由 src-tauri/build.rs 在
// macOS 构建时经 SwiftLinker 编成静态库链进 Rust。

import AetherEngine
import UIKit

final class AetherPlayerEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private let engineName = "aether"
  private var engine: AetherEngine?
  private var playerView: AetherPlayerView?
  private var container: UIViewController?
  private var overlay: MPVControlOverlay?
  private var timer: Timer?
  private var rate: Double = 1
  private var volume: Double = 1
  private var muted = false
  private var didFireEnded = false
  private var didFireError = false
  private var lastPosition: Double = 0
  private var lastDuration: Double = 0
  private var lastVideoWidth = 0
  private var lastVideoHeight = 0
  private var lastPlaying = false

  /// 当前视频原始分辨率；未知时为 .zero（前端与覆盖层按 0 处理为不显示）。
  var videoSize: CGSize {
    CGSize(width: lastVideoWidth, height: lastVideoHeight)
  }

  var currentState: NativePlayerState {
    NativePlayerState(
      engine: engineName,
      playing: lastPlaying,
      position: lastPosition,
      duration: lastDuration,
      rate: rate,
      volume: volume,
      muted: muted,
      videoWidth: lastVideoWidth,
      videoHeight: lastVideoHeight)
  }

  func open(
    url: URL, position: Double, rate: Double, volume: Double, muted: Bool, title: String?,
    hardwareAcceleration: Bool,
    present: @escaping (UIViewController) -> Void,
    completion: @escaping (Result<NativePlayerState, Error>) -> Void
  ) {
    self.rate = rate
    self.volume = volume
    self.muted = muted
    // AetherEngine 没有硬解开关：preferredDecodePath 永远 .automatic，
    // 引擎按编码自己分流；硬件加速开关只对 mpv 生效，这里忽略。
    // title 由覆盖层顶栏显示。
    _ = hardwareAcceleration

    var didComplete = false
    let finish: (Result<NativePlayerState, Error>) -> Void = { [weak self] result in
      guard let self = self, !didComplete else { return }
      didComplete = true
      completion(result)
    }

    let playerView = AetherPlayerView()
    playerView.translatesAutoresizingMaskIntoConstraints = false
    self.playerView = playerView

    let container = UIViewController()
    container.modalPresentationStyle = .fullScreen
    container.view.backgroundColor = .black
    container.view.addSubview(playerView)
    NSLayoutConstraint.activate([
      playerView.topAnchor.constraint(equalTo: container.view.topAnchor),
      playerView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
      playerView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
    ])
    let overlay = MPVControlOverlay(engine: self, title: title)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    container.view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: container.view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
      overlay.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
    ])
    self.overlay = overlay
    self.container = container
    present(container)

    // load 是 async 且上游类是 @MainActor：放进 MainActor 任务里。
    // autoplay 默认 true，load 成功即开播。
    Task { @MainActor [weak self] in
      guard let self = self else { return }
      do {
        let engine = try AetherEngine()
        self.engine = engine
        engine.bind(view: playerView)
        _ = try await engine.load(
          url: url,
          startPosition: position > 0 ? position : nil,
          options: LoadOptions())
        // 上游没有 isMuted：静音就是音量设 0，取消静音恢复存的音量。
        engine.volume = Float(self.muted ? 0 : self.volume)
        engine.setRate(Float(self.rate))
        self.startTimer()
        finish(.success(self.currentState))
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.eventHandler?(.error(message))
        // load 失败：把容器拆掉，否则黑屏盖住底下的 WebView，
        // 前端按链回落下一个引擎或 WebView 时看不到画面。
        self.teardownContainer()
        finish(.failure(NativePlayerUnavailableError(message: message)))
      }
    }
  }

  func play() {
    Task { @MainActor [weak self] in self?.engine?.play() }
  }

  func pause() {
    Task { @MainActor [weak self] in self?.engine?.pause() }
  }

  func seek(to position: Double) {
    Task { @MainActor [weak self] in
      guard let engine = self?.engine else { return }
      await engine.seek(to: position)
    }
  }

  func setRate(_ rate: Double) {
    self.rate = rate
    Task { @MainActor [weak self] in self?.engine?.setRate(Float(rate)) }
  }

  func setVolume(_ volume: Double, muted: Bool) {
    self.volume = volume
    self.muted = muted
    Task { @MainActor [weak self] in
      self?.engine?.volume = Float(muted ? 0 : volume)
    }
  }

  /// 覆盖层关闭按钮调：先拆播放器再发 .closed（与 MPVEngine.userClose 同义）。
  func userClose() {
    close()
    eventHandler?(.closed)
  }

  func close() {
    timer?.invalidate()
    timer = nil
    let engine = self.engine
    let view = self.playerView
    self.engine = nil
    self.playerView = nil
    // stop + unbind 必须在 MainActor 上调；engine 引用先抓出来，
    // 再清成员，避免任务跑起来时 self.engine 已是 nil。
    Task { @MainActor in
      engine?.stop()
      if let view = view { engine?.unbind(view: view) }
    }
    teardownContainer()
    didFireEnded = false
    didFireError = false
  }

  // MARK: - 轮询与容器

  /// 0.5s 轮询（与 MPVEngine 同节奏）：读进度/时长/状态推 .time 事件，
  /// .ended 与 .error 只发一次，顺带刷新覆盖层。
  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.poll() }
    }
  }

  private func poll() {
    guard let engine = engine else { return }
    let position = engine.clock.currentTime
    let duration = engine.duration
    lastPosition = position.isFinite ? position : 0
    lastDuration = duration.isFinite && !duration.isNaN ? duration : 0
    lastPlaying = engine.state == .playing
    lastVideoWidth = Int(engine.sourceVideoWidth)
    lastVideoHeight = Int(engine.sourceVideoHeight)
    switch engine.state {
    case .ended:
      // .ended 是终态：重播须重新 load；这里只发一次事件，不拆容器，
      // 退出由用户点关闭或前端调 close（与 MPVEngine 同义）。
      if !didFireEnded {
        didFireEnded = true
        eventHandler?(.ended)
      }
    case .error(let message):
      if !didFireError {
        didFireError = true
        eventHandler?(.error(message))
      }
    default:
      break
    }
    eventHandler?(.time(position: lastPosition, duration: lastDuration, videoSize: videoSize))
    overlay?.refresh(state: currentState)
  }

  private func teardownContainer() {
    overlay?.teardown()
    overlay?.removeFromSuperview()
    overlay = nil
    container?.dismiss(animated: true, completion: nil)
    container = nil
  }
}

// 方法已满足 NativePlayerControlTarget（play/pause/seek/setRate/
// setVolume 来自 NativePlayerEngine，userClose 见上），只声明
// conformance，让 MPVControlOverlay 能以协议类型持有它。
extension AetherPlayerEngine: NativePlayerControlTarget {}
