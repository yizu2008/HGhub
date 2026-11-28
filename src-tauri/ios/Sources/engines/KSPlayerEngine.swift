// KSPlayer 引擎（kingslay/KSPlayer）：AVPlayer + FFmpeg 双路，HDR /
// Dolby Vision / Atmos、字幕支持好，Swift 写起来最顺。
// 许可证是关键：默认 GPL-3.0（要求开源自家代码），HGhub 是 PolyForm
// Noncommercial，不能直接按 GPL 发行；完整格式 / 全量 ASS / AV1 硬解 /
// FFmpeg 8.1 在付费 LGPL 版（联系 kingslay@icloud.com），免费 GPL 版
// 是 FFmpeg 6.1.0 且功能受限（见 docs/developers/native-players.md）。
// 没拿到付费 LGPL 之前不要用 KSPlayer 发正式包。
//
// 依赖未装时走 #else 分支：open 直接报 unavailable，说明缺什么、怎么装。
// #if 分支里按 KSPlayer README 所写（KSOptions.secondPlayerType =
// KSMEPlayer.self 切 FFmpeg 路，KSPlayerView 承载画面），类名/方法名
// 以接入的 KSPlayer 版本为准，第一次在 Mac 上编时由 Xcode 校验。

import UIKit

#if canImport(KSPlayer)
import KSPlayer

final class KSPlayerEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private var playerView: KSPlayerView?
  private var container: UIViewController?
  private var timer: Timer?
  private var didFireEnded = false
  private var engineName = "ksplayer"

  /// 分辨率上报暂未接这个引擎：先报未知（.zero），覆盖层与 state
  /// 按 0 处理为不显示；AVPlayer 已报真实尺寸。
  var videoSize: CGSize { .zero }

  var currentState: NativePlayerState {
    // KSPlayerView 的播放位置/时长按当前版本的 API 取；若版本里是
    // player.currentTime / player.duration，Xcode 会在 Mac 验证时指出。
    let position = playerView.map { Double($0.currentTime) } ?? 0
    let duration = playerView.map { Double($0.duration) } ?? 0
    return NativePlayerState(
      engine: engineName,
      playing: playerView?.isPlaying ?? false,
      position: position.isFinite ? position : 0,
      duration: duration.isFinite ? duration : 0,
      rate: 1,
      volume: 1,
      muted: false,
      videoWidth: 0,
      videoHeight: 0)
  }

  func open(
    url: URL, position: Double, rate: Double, volume: Double, muted: Bool, title: String?,
    hardwareAcceleration: Bool,
    present: @escaping (UIViewController) -> Void,
    completion: @escaping (Result<NativePlayerState, Error>) -> Void
  ) {
    // KSPlayer 的倍速/音量由前端 open 后的 setRate/setVolume 命令再调，
    // 这里只保证起播位置正确。
    _ = (rate, volume, muted, title, hardwareAcceleration)
    // FFmpeg 路：默认的 AVPlayer 路只吃苹果支持的格式，KSMEPlayer
    // 才能吃全格式；没这行 MKV/FLV 这类源会直接播不了。
    KSOptions.secondPlayerType = KSMEPlayer.self

    let playerView = KSPlayerView()
    playerView.set(url: url, options: KSOptions())
    self.playerView = playerView

    let container = UIViewController()
    container.modalPresentationStyle = .fullScreen
    container.view.backgroundColor = .black
    playerView.frame = container.view.bounds
    playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.view.addSubview(playerView)
    self.container = container
    present(container)

    if position > 0 {
      playerView.seek(to: position)
    }
    playerView.play()
    didFireEnded = false
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
    playerView?.play()
  }

  func pause() {
    playerView?.pause()
  }

  func seek(to position: Double) {
    playerView?.seek(to: position)
  }

  func setRate(_ rate: Double) {
    playerView?.setRate(Float(rate))
  }

  func setVolume(_ volume: Double, muted: Bool) {
    playerView?.setVolume(muted ? 0 : Float(volume))
  }

  func close() {
    timer?.invalidate()
    timer = nil
    playerView?.pause()
    playerView?.removeFromSuperview()
    playerView = nil
    container?.dismiss(animated: true, completion: nil)
    container = nil
  }
}

#else

/// KSPlayer 未接入（未在 Xcode 里加 SPM 依赖）时的替身：open 直接失败，
// 报错里写清许可证前提和怎么装，不冒充可用。
final class KSPlayerEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?
  private var engineName = "ksplayer"

  var videoSize: CGSize { .zero }

  var currentState: NativePlayerState {
    NativePlayerState(
      engine: engineName, playing: false, position: 0, duration: 0, rate: 1, volume: 1,
      muted: false, videoWidth: 0, videoHeight: 0)
  }

  func open(
    url: URL, position: Double, rate: Double, volume: Double, muted: Bool, title: String?,
    hardwareAcceleration: Bool,
    present: @escaping (UIViewController) -> Void,
    completion: @escaping (Result<NativePlayerState, Error>) -> Void
  ) {
    _ = (url, position, rate, volume, muted, title, present, hardwareAcceleration)
    completion(
      .failure(
        NativePlayerUnavailableError(message:
          "KSPlayer 未接入：请在 Mac 上用 SPM 加入 kingslay/KSPlayer；"
          + "注意默认 GPL-3.0 要求开源自家代码，HGhub（PolyForm Noncommercial）"
          + "正式发行需付费 LGPL 版（联系 kingslay@icloud.com），"
          + "详见 docs/developers/native-players.md")))
  }

  func play() {}
  func pause() {}
  func seek(to position: Double) {}
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Double, muted: Bool) {}
  func close() {}
}

#endif
