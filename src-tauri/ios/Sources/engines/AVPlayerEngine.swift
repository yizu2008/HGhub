// AVPlayer 引擎：系统自带，零依赖、零许可证风险。
// 只吃 H.264/HEVC + MP4/HLS；MKV/FLV/WebM/VP9/AV1/DASH/ASS 不支持，
// 那些格式由 Auto 链里的 MDK / KSPlayer / mpv 接手。
// 取流地址就是 Rust media.rs 给的本地回环 session 地址
// （http://127.0.0.1:{port}/hpp/{id}/{index}），上游头/Range/密钥都由
// Rust 代理处理，这里直接播，不拼头、不改地址。

import AVFoundation
import AVKit
import UIKit

/// 用户点 AVPlayerViewController 的 Done 时靠它把“已关闭”传回插件，
/// 这样前端才能把最新进度回写并回落 WebView。
private final class DismissablePlayerViewController: AVPlayerViewController {
  var onDismiss: (() -> Void)?
  private var didFireDismiss = false

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed && !didFireDismiss {
      didFireDismiss = true
      onDismiss?()
    }
  }
}

final class AVPlayerEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private var player: AVPlayer?
  private var playerItem: AVPlayerItem?
  private var controller: DismissablePlayerViewController?
  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var rate: Double = 1
  private var volume: Double = 1
  private var muted = false
  private var engineName = "avplayer"

  /// 当前视频的原始分辨率（AVPlayerItem.presentationSize）；视频轨
  /// 没加载出来时为 .zero，覆盖层与 state 按 0 处理为不显示。
  var videoSize: CGSize {
    playerItem?.presentationSize ?? .zero
  }

  /// 原生全屏里的分辨率角标（contentOverlayView 右上角下方），未知尺寸时隐藏；
  /// 起播后显示 3 秒自动消失（与 WebView 路一致）。
  private let resolutionLabel: UILabel = {
    let label = UILabel()
    label.font = .systemFont(ofSize: 13, weight: .bold)
    label.textColor = .white
    label.backgroundColor = UIColor(white: 0, alpha: 0.55)
    label.layer.cornerRadius = 11
    label.clipsToBounds = true
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.isHidden = true
    return label
  }()

  /// 分辨率角标 3 秒自动消失的定时器；只在角标刚出现时起一次，0.5s 的刷新不续期。
  private var resolutionHideTimer: Timer?

  var currentState: NativePlayerState {
    let position = player.map { $0.currentTime().seconds } ?? 0
    let duration = playerItem.map { $0.duration.seconds } ?? 0
    let size = videoSize
    return NativePlayerState(
      engine: engineName,
      playing: (player?.rate ?? 0) > 0 && player?.error == nil,
      position: position.isFinite ? position : 0,
      duration: duration.isFinite && !duration.isNaN ? duration : 0,
      rate: rate,
      volume: volume,
      muted: muted,
      videoWidth: Int(size.width),
      videoHeight: Int(size.height))
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
    // title 在 AVPlayerViewController 上没有展示位，忽略（不影响播放）。
    // AVPlayer 没有硬解开关：永远用 VideoToolbox 硬解 H.264/HEVC，
    // 不支持的格式直接播不了——hardwareAcceleration 在此忽略。
    _ = (title, hardwareAcceleration)

    let asset = AVURLAsset(url: url)
    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)
    player.volume = Float(volume)
    player.isMuted = muted
    // defaultRate 只在 iOS 16.0+ 可用；部署目标是 iOS 15.0，15 上跳过
    // 预设倍速即可（setRate 里 playImmediately(atRate:) 的路子不受影响）。
    if #available(iOS 16.0, *) {
      player.defaultRate = Float(rate)
    }
    self.player = player
    self.playerItem = item

    var didComplete = false
    let finish: (Result<NativePlayerState, Error>) -> Void = { [weak self] result in
      guard let self = self, !didComplete else { return }
      didComplete = true
      completion(result)
    }

    // 起播失败（如回环地址不可达 / 媒体损坏）走 error 事件 + open 失败，
    // 前端据此回落下一个引擎或 WebView。
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      guard let self = self else { return }
      if item.status == .failed {
        let message = item.error?.localizedDescription ?? "AVPlayer 加载失败"
        self.eventHandler?(.error(message))
        finish(.failure(NativePlayerUnavailableError(message: message)))
      }
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(itemDidEnd),
      name: .AVPlayerItemDidPlayToEndTime, object: item)
    NotificationCenter.default.addObserver(
      self, selector: #selector(itemDidFail(_:)),
      name: .AVPlayerItemFailedToPlayToEndTime, object: item)

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      guard let self = self else { return }
      let position = time.seconds
      guard position.isFinite else { return }
      self.updateResolutionLabel()
      self.eventHandler?(
        .time(position: position, duration: self.currentState.duration, videoSize: self.videoSize))
    }

    let controller = DismissablePlayerViewController()
    controller.player = player
    controller.modalPresentationStyle = .fullScreen
    controller.onDismiss = { [weak self] in
      self?.eventHandler?(.closed)
    }
    self.controller = controller
    // 分辨率角标放在 AVPlayerViewController 的 contentOverlayView 右上角下方：
    // 顶部系统控制条之下、视频之上；起播显示 3 秒后自动消失。
    // contentOverlayView 是 UIView?，没有时只跳过角标，不影响起播。
    if resolutionLabel.superview == nil, let overlay = controller.contentOverlayView {
      overlay.addSubview(resolutionLabel)
      NSLayoutConstraint.activate([
        resolutionLabel.topAnchor.constraint(
          equalTo: overlay.topAnchor, constant: 72),
        resolutionLabel.trailingAnchor.constraint(
          equalTo: overlay.trailingAnchor, constant: -12),
      ])
    }
    resolutionHideTimer?.invalidate()
    resolutionHideTimer = nil
    resolutionLabel.isHidden = true
    updateResolutionLabel()
    present(controller)

    if position > 0 {
      player.seek(
        to: CMTime(seconds: position, preferredTimescale: 600),
        toleranceBefore: .zero, toleranceAfter: .zero)
    }
    player.playImmediately(atRate: Float(rate))
    finish(.success(currentState))
  }

  @objc private func itemDidEnd() {
    eventHandler?(.ended)
  }

  @objc private func itemDidFail(_ notification: Notification) {
    let message =
      (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
      .localizedDescription ?? "AVPlayer 播放失败"
    eventHandler?(.error(message))
  }

  /// 刷新覆盖层角标：presentationSize 已知就显示“1920×1080”，否则隐藏。
  /// 每 0.5s 的进度回调里调一次，HLS 切清晰度时也能跟上；起播后显示
  /// 3 秒自动消失（只在角标刚出现时起一次定时器，刷新不续期）。
  private func updateResolutionLabel() {
    let size = videoSize
    guard size.width > 0 && size.height > 0 else {
      resolutionHideTimer?.invalidate()
      resolutionHideTimer = nil
      resolutionLabel.isHidden = true
      return
    }
    resolutionLabel.text = " \(Int(size.width))×\(Int(size.height)) "
    if resolutionLabel.isHidden {
      resolutionLabel.isHidden = false
      resolutionHideTimer?.invalidate()
      resolutionHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
        self?.resolutionLabel.isHidden = true
      }
    }
  }

  func play() {
    player?.playImmediately(atRate: Float(rate))
  }

  func pause() {
    player?.pause()
  }

  func seek(to position: Double) {
    player?.seek(
      to: CMTime(seconds: position, preferredTimescale: 600),
      toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setRate(_ rate: Double) {
    self.rate = rate
    if #available(iOS 16.0, *) {
      player?.defaultRate = Float(rate)
    }
    if player?.rate ?? 0 > 0 {
      player?.playImmediately(atRate: Float(rate))
    }
  }

  func setVolume(_ volume: Double, muted: Bool) {
    self.volume = volume
    self.muted = muted
    player?.volume = Float(volume)
    player?.isMuted = muted
  }

  func close() {
    resolutionHideTimer?.invalidate()
    resolutionHideTimer = nil
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
      timeObserver = nil
    }
    statusObservation?.invalidate()
    statusObservation = nil
    NotificationCenter.default.removeObserver(self)
    player?.pause()
    controller?.dismiss(animated: true, completion: nil)
    controller = nil
    playerItem = nil
    player = nil
  }
}
