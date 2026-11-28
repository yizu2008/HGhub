// MDK 引擎（wang-bin/mdk-sdk）：FFmpeg 底，VideoToolbox 硬解 + Metal 渲染，
// 格式覆盖比 AVPlayer 宽，ASS 字幕需可选的 ass.framework。
// 许可证是 key 制：开源 / 非商业免费，找作者申请 key；无 key 且 SDK 过期
// 时最后一帧可能出现二维码水印（见 docs/developers/native-players.md）。
//
// 依赖未装时走 #else 分支：open 直接报 unavailable，说明缺什么、怎么装，
// 绝不留一个“能打开但播不了”的空实现。
// #if 分支里的方法名按 swift-mdk 的 Player API 所写（setMedia /
// setVideoOutput / play / pause / seek / volume，position/duration 按
// MDK 的毫秒单位换算），第一次在 Mac 上编时以 swift-mdk 当前 README
// 为准由 Xcode 校验——这是 Mac 验证清单的第一项。

import UIKit

#if canImport(swift_mdk)
import swift_mdk

final class MDKEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?

  private var player: Player?
  private var container: UIViewController?
  private var timer: Timer?
  private var didFireEnded = false
  private var engineName = "mdk"

  /// 分辨率上报暂未接这个引擎：先报未知（.zero），覆盖层与 state
  /// 按 0 处理为不显示；AVPlayer 已报真实尺寸。
  var videoSize: CGSize { .zero }

  var currentState: NativePlayerState {
    // MDK 的 position/duration 是毫秒整数。
    let position = (player.map { Double($0.position) } ?? 0) / 1000
    let duration = (player.map { Double($0.duration) } ?? 0) / 1000
    return NativePlayerState(
      engine: engineName,
      playing: player?.state == .playing,
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
    // MDK 不走倍速/静音参数做首帧控制：rate/volume 在 open 后由前端
    // 的 setRate/setVolume 命令再调；这里只保证起播位置正确。
    _ = (rate, volume, muted, title, hardwareAcceleration)
    let player = Player()
    // iOS 解码器顺序：先 VideoToolbox 硬解，缺失时回落 FFmpeg 软解，
    // AV1 再回落 dav1d（需链接 dav1d.framework 才生效）。
    player.setDecoders(.video, ["VT", "FFmpeg", "dav1d"])
    player.setMedia(url.absoluteString)

    let container = UIViewController()
    container.modalPresentationStyle = .fullScreen
    container.view.backgroundColor = .black
    player.setVideoOutput(container.view)
    self.container = container
    self.player = player
    present(container)

    if position > 0 {
      player.seek(Int64(position * 1000))
    }
    player.play()
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
    player?.play()
  }

  func pause() {
    player?.pause()
  }

  func seek(to position: Double) {
    player?.seek(Int64(position * 1000))
  }

  func setRate(_ rate: Double) {
    // MDK 的倍速是 playbackRate；按 swift-mdk 当前 API 核对。
    player?.setPlaybackRate(Float(rate))
  }

  func setVolume(_ volume: Double, muted: Bool) {
    player?.setVolume(muted ? 0 : Float(volume))
  }

  func close() {
    timer?.invalidate()
    timer = nil
    player?.stop()
    player = nil
    container?.dismiss(animated: true, completion: nil)
    container = nil
  }
}

#else

/// swift-mdk 未接入（未在 Xcode 里加 SPM/CocoaPods 依赖）时的替身：
/// open 直接失败，报错里写清怎么装，不冒充可用。
final class MDKEngine: NSObject, NativePlayerEngine {
  var eventHandler: ((NativePlayerEvent) -> Void)?
  private var engineName = "mdk"

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
          "MDK 未接入：请在 Mac 上用 SPM 或 CocoaPods 加入 swift-mdk（pod 'mdk'），"
          + "并向作者申请开源/非商业 key；详见 docs/developers/native-players.md")))
  }

  func play() {}
  func pause() {}
  func seek(to position: Double) {}
  func setRate(_ rate: Double) {}
  func setVolume(_ volume: Double, muted: Bool) {}
  func close() {}
}

#endif
