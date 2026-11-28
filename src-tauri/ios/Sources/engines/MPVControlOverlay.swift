// mpv 原生播放的控制层（v0.0.146）：原生 UIKit 覆盖层，跟 WebView 内嵌看齐。
// 顶栏（关闭 + 标题 + 分辨率）+ 底栏（播放/暂停、进度、静音、倍速、旋转）
// + 手势（单击显隐、双击播放/暂停、左半屏竖滑亮度、右半屏竖滑系统音量、
// 横滑快进/快退）+ 按视频分辨率自动横竖屏 + 手动旋转 + 横屏隐藏状态栏。
// AVPlayer 用系统控制条，不走这里；MDK/KSPlayer 未实现。
// 亮度/系统音量的做法与详情页手势一致（见 OrientationPlugin：亮度走
// UIScreen.main.brightness，下限 0.05；音量走藏起来的 MPVolumeView 滑块，
// iOS 没有公开的设置系统音量 API，这是标准做法）；旋转走
// requestGeometryUpdate（iOS 16+）/ KVC 老路（iOS 15），与
// OrientationPlugin.setOrientation 同一套 API。
// 本机无 Xcode/Swift 工具链：本文件未编译，由 src-tauri/build.rs 在
// macOS 构建时经 SwiftLinker 编成静态库链进 Rust。

import AVFoundation
import MediaPlayer
import UIKit

/// mpv 容器里的控制覆盖层。由 MPVEngine.open() 建好加进容器，0.5s 的
/// 状态轮询调 refresh(state:) 刷新；close() 时 teardown() + 移掉。
/// 手势只认视频区域：控制条（顶栏/底栏）上的触摸交给按钮和滑块。
final class MPVControlOverlay: UIView, UIGestureRecognizerDelegate {
  weak var engine: MPVEngine?

  // MARK: - 控件

  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let resolutionLabel = UILabel()
  private let bottomBar = UIView()
  private let playPauseButton = UIButton(type: .system)
  private let currentTimeLabel: UILabel = {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
  private let progressSlider = UISlider()
  private let durationLabel: UILabel = {
    let label = UILabel()
    label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    label.textColor = .white
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()
  private let muteButton = UIButton(type: .system)
  private let rateButton = UIButton(type: .system)
  private let rotateButton = UIButton(type: .system)
  private let centerIndicator = UILabel()

  // MARK: - 状态

  private var lastState: NativePlayerState?
  private var controlsVisible = true
  private var hideTimer: Timer?
  private var indicatorTimer: Timer?
  private var autoRotated = false
  private var lastStatusBarHidden: Bool?
  private var isScrubbing = false

  private enum PanMode { case none, brightness, volume, seek }
  private var panMode: PanMode = .none
  private var panStart = CGPoint.zero
  private var panStartBrightness: Double = 0
  private var panStartVolume: Double = 0
  private var panStartPosition: Double = 0
  private var panStartDuration: Double = 0
  private var panSeekTarget: Double = 0
  /// 系统音量读回有滞后（见 OrientationPlugin）：2 秒内用最近一次
  /// 写的值当基准，连续快滑才不会互相抵消；亮度读回是同步的，不用。
  private var lastVolume: (value: Double, at: Date)?
  private var volumeView: MPVolumeView?

  private let rates: [Double] = [1, 1.25, 1.5, 2, 0.5, 0.75]

  init(engine: MPVEngine, title: String?) {
    self.engine = engine
    super.init(frame: .zero)
    backgroundColor = .clear
    setupViews(title: title)
    setupGestures()
    showControls()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    hideTimer?.invalidate()
    indicatorTimer?.invalidate()
  }

  /// close() 时调：停掉定时器，免得覆盖层被移掉后还在跑。
  func teardown() {
    hideTimer?.invalidate()
    hideTimer = nil
    indicatorTimer?.invalidate()
    indicatorTimer = nil
  }

  // MARK: - 布局

  private func makeIconButton(systemName: String) -> UIButton {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: systemName), for: .normal)
    button.tintColor = .white
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }

  private func setupViews(title: String?) {
    let barBackground = UIColor.black.withAlphaComponent(0.45)

    topBar.backgroundColor = barBackground
    topBar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(topBar)
    bottomBar.backgroundColor = barBackground
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bottomBar)

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.tintColor = .white
    closeButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.addTarget(self, action: #selector(onClose), for: .touchUpInside)
    closeButton.accessibilityLabel = "关闭"
    topBar.addSubview(closeButton)

    titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
    titleLabel.textColor = .white
    titleLabel.text = title ?? ""
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    topBar.addSubview(titleLabel)

    // 分辨率角标（与 AVPlayerEngine 的一致）："1920×1080"，尺寸未
    // 知时隐藏；控制条显隐时跟着走，不另设 3 秒定时器。
    resolutionLabel.font = .systemFont(ofSize: 13, weight: .bold)
    resolutionLabel.textColor = .white
    resolutionLabel.backgroundColor = UIColor(white: 0, alpha: 0.55)
    resolutionLabel.layer.cornerRadius = 11
    resolutionLabel.clipsToBounds = true
    resolutionLabel.textAlignment = .center
    resolutionLabel.translatesAutoresizingMaskIntoConstraints = false
    resolutionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    resolutionLabel.isHidden = true
    topBar.addSubview(resolutionLabel)

    playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
    playPauseButton.tintColor = .white
    playPauseButton.translatesAutoresizingMaskIntoConstraints = false
    playPauseButton.addTarget(self, action: #selector(onPlayPause), for: .touchUpInside)
    playPauseButton.accessibilityLabel = "播放/暂停"

    currentTimeLabel.text = "0:00"
    currentTimeLabel.textAlignment = .right
    durationLabel.text = "0:00"
    durationLabel.textAlignment = .left

    progressSlider.minimumValue = 0
    progressSlider.maximumValue = 1
    progressSlider.value = 0
    progressSlider.minimumTrackTintColor = .white
    progressSlider.maximumTrackTintColor = UIColor(white: 1, alpha: 0.35)
    progressSlider.thumbTintColor = .white
    progressSlider.translatesAutoresizingMaskIntoConstraints = false
    progressSlider.addTarget(self, action: #selector(onScrub), for: .valueChanged)
    progressSlider.addTarget(self, action: #selector(onScrubEnd), for: [.touchUpInside, .touchUpOutside])
    progressSlider.addTarget(self, action: #selector(onScrubCancel), for: .touchCancel)
    progressSlider.accessibilityLabel = "进度"

    muteButton.setImage(UIImage(systemName: "speaker.fill"), for: .normal)
    muteButton.tintColor = .white
    muteButton.translatesAutoresizingMaskIntoConstraints = false
    muteButton.addTarget(self, action: #selector(onMute), for: .touchUpInside)
    muteButton.accessibilityLabel = "静音"

    rateButton.setTitle("1×", for: .normal)
    rateButton.setTitleColor(.white, for: .normal)
    rateButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
    rateButton.translatesAutoresizingMaskIntoConstraints = false
    rateButton.addTarget(self, action: #selector(onRate), for: .touchUpInside)
    rateButton.accessibilityLabel = "倍速"

    rotateButton.setImage(UIImage(systemName: "rotate.right"), for: .normal)
    rotateButton.tintColor = .white
    rotateButton.translatesAutoresizingMaskIntoConstraints = false
    rotateButton.addTarget(self, action: #selector(onRotate), for: .touchUpInside)
    rotateButton.accessibilityLabel = "切换横竖屏"

    centerIndicator.font = .systemFont(ofSize: 15, weight: .bold)
    centerIndicator.textColor = .white
    centerIndicator.backgroundColor = UIColor(white: 0, alpha: 0.6)
    centerIndicator.layer.cornerRadius = 18
    centerIndicator.clipsToBounds = true
    centerIndicator.textAlignment = .center
    centerIndicator.translatesAutoresizingMaskIntoConstraints = false
    centerIndicator.isHidden = true
    addSubview(centerIndicator)

    // 顶栏：关闭 + 标题（撑满）+ 分辨率；底栏：进度行 + 按钮行。
    let progressRow = UIStackView(arrangedSubviews: [currentTimeLabel, progressSlider, durationLabel])
    progressRow.axis = .horizontal
    progressRow.spacing = 8
    progressRow.alignment = .center
    progressRow.translatesAutoresizingMaskIntoConstraints = false
    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    let buttonRow = UIStackView(arrangedSubviews: [playPauseButton, muteButton, rateButton, rotateButton, spacer])
    buttonRow.axis = .horizontal
    buttonRow.spacing = 8
    buttonRow.alignment = .center
    buttonRow.translatesAutoresizingMaskIntoConstraints = false
    let bottomStack = UIStackView(arrangedSubviews: [progressRow, buttonRow])
    bottomStack.axis = .vertical
    bottomStack.spacing = 2
    bottomStack.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(bottomStack)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      topBar.heightAnchor.constraint(equalToConstant: 56),

      closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
      closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),

      titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
      titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      titleLabel.trailingAnchor.constraint(equalTo: resolutionLabel.leadingAnchor, constant: -8),

      resolutionLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
      resolutionLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
      resolutionLabel.heightAnchor.constraint(equalToConstant: 22),

      bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),

      bottomStack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
      bottomStack.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
      bottomStack.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
      bottomStack.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor, constant: -8),

      currentTimeLabel.widthAnchor.constraint(equalToConstant: 48),
      durationLabel.widthAnchor.constraint(equalToConstant: 48),
      playPauseButton.widthAnchor.constraint(equalToConstant: 44),
      playPauseButton.heightAnchor.constraint(equalToConstant: 44),
      muteButton.widthAnchor.constraint(equalToConstant: 44),
      muteButton.heightAnchor.constraint(equalToConstant: 44),
      rateButton.widthAnchor.constraint(equalToConstant: 60),
      rateButton.heightAnchor.constraint(equalToConstant: 44),
      rotateButton.widthAnchor.constraint(equalToConstant: 44),
      rotateButton.heightAnchor.constraint(equalToConstant: 44),

      centerIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
      centerIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
      centerIndicator.heightAnchor.constraint(equalToConstant: 36),
    ])
  }

  private func setupGestures() {
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap))
    singleTap.numberOfTapsRequired = 1
    singleTap.delegate = self
    addGestureRecognizer(singleTap)
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.delegate = self
    addGestureRecognizer(doubleTap)
    singleTap.require(toFail: doubleTap)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
    pan.delegate = self
    addGestureRecognizer(pan)
  }

  // 控制条区域的手势交给按钮和滑块；控制条藏起来时不拦（点哪里都显隐）。
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard controlsVisible else { return true }
    let point = touch.location(in: self)
    if topBar.frame.contains(point) || bottomBar.frame.contains(point) { return false }
    return true
  }

  // MARK: - 刷新（引擎 0.5s 轮询调）

  func refresh(state: NativePlayerState) {
    lastState = state
    playPauseButton.setImage(
      UIImage(systemName: state.playing ? "pause.fill" : "play.fill"), for: .normal)
    muteButton.setImage(
      UIImage(systemName: state.muted ? "speaker.slash.fill" : "speaker.fill"), for: .normal)
    rateButton.setTitle(formatRate(state.rate), for: .normal)
    if state.videoWidth > 0 && state.videoHeight > 0 {
      resolutionLabel.text = " \(state.videoWidth)×\(state.videoHeight) "
      resolutionLabel.isHidden = false
    } else {
      resolutionLabel.isHidden = true
    }
    // 拖动进度条时不抢滑块位置和当前时间（拖动中由 onScrub 实时写），
    // 但量程（最大值）照常跟，避免时长刚拿到时滑块还卡在 0..1。
    progressSlider.maximumValue = Float(max(state.duration, 1))
    if !isScrubbing {
      progressSlider.value = Float(min(state.position, max(state.duration, 1)))
      currentTimeLabel.text = formatTime(state.position)
    }
    durationLabel.text = formatTime(state.duration)
    // 诊断版 v0.0.149：自动转屏已关（147 电影首帧转横屏后闪退，疑首帧
    // 两句转横屏请求重叠——覆盖层这句 + 前端按视频尺寸调的那句）。
    // 只关自动这一句：手动旋转按钮、手动转手机、前端调方向都不动；
    // 首帧只记 autoRotated，不再发请求。
    if !autoRotated && state.videoWidth > 0 && state.videoHeight > 0 {
      autoRotated = true
    }
    // 横屏隐藏状态栏、竖屏显示（与 WebView 播放页同规则），变了才写。
    let landscape = window?.windowScene?.interfaceOrientation.isLandscape == true
    if lastStatusBarHidden != landscape {
      lastStatusBarHidden = landscape
      UIApplication.shared.isStatusBarHidden = landscape
    }
  }

  // MARK: - 显隐与指示条

  private func showControls() {
    controlsVisible = true
    topBar.isHidden = false
    bottomBar.isHidden = false
    topBar.isUserInteractionEnabled = true
    bottomBar.isUserInteractionEnabled = true
    UIView.animate(withDuration: 0.25) {
      self.topBar.alpha = 1
      self.bottomBar.alpha = 1
    }
    pokeControls()
  }

  private func hideControls() {
    controlsVisible = false
    topBar.isUserInteractionEnabled = false
    bottomBar.isUserInteractionEnabled = false
    UIView.animate(withDuration: 0.25, animations: {
      self.topBar.alpha = 0
      self.bottomBar.alpha = 0
    }, completion: { _ in
      self.topBar.isHidden = true
      self.bottomBar.isHidden = true
    })
  }

  private func toggleBars() {
    if controlsVisible { hideControls() } else { showControls() }
  }

  /// 任意交互后都调：播着时 3 秒后自动藏控制条；暂停时一直显示
  ///（与 WebView 的 PlayerControls visible 规则一致）。
  private func pokeControls() {
    hideTimer?.invalidate()
    hideTimer = nil
    guard controlsVisible else { return }
    hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      if self.lastState?.playing == true { self.hideControls() }
    }
  }

  private func showIndicator(_ text: String) {
    centerIndicator.text = " \(text) "
    centerIndicator.isHidden = false
    centerIndicator.alpha = 1
    indicatorTimer?.invalidate()
    indicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
      self?.centerIndicator.isHidden = true
    }
  }

  // MARK: - 按钮

  @objc private func onClose() {
    engine?.userClose()
  }

  @objc private func onSingleTap() {
    toggleBars()
  }

  @objc private func onDoubleTap() {
    guard let state = lastState else { return }
    if state.playing { engine?.pause() } else { engine?.play() }
    pokeControls()
  }

  @objc private func onPlayPause() {
    guard let state = lastState else { return }
    if state.playing { engine?.pause() } else { engine?.play() }
    pokeControls()
  }

  @objc private func onMute() {
    guard let state = lastState else { return }
    engine?.setVolume(state.volume, muted: !state.muted)
    pokeControls()
  }

  @objc private func onRate() {
    guard let state = lastState else { return }
    let idx = rates.firstIndex(where: { abs($0 - state.rate) < 0.01 }) ?? 0
    let next = rates[(idx + 1) % rates.count]
    engine?.setRate(next)
    rateButton.setTitle(formatRate(next), for: .normal)
    pokeControls()
  }

  @objc private func onRotate() {
    // 读实时方向（v0.0.23 的教训：不能读缓存的 state，程序触发旋转
    // 后 resize 可能不来、或来时尺寸还是旧的），切到反面。
    let landscape = window?.windowScene?.interfaceOrientation.isLandscape == true
    requestOrientation(landscape: !landscape)
    showIndicator(!landscape ? "已切换到横屏" : "已切换到竖屏")
    pokeControls()
  }

  @objc private func onScrub() {
    isScrubbing = true
    currentTimeLabel.text = formatTime(Double(progressSlider.value))
  }

  @objc private func onScrubEnd() {
    guard isScrubbing else { return }
    isScrubbing = false
    engine?.seek(to: Double(progressSlider.value))
    pokeControls()
  }

  @objc private func onScrubCancel() {
    isScrubbing = false
  }

  // MARK: - 手势（竖滑亮度/音量、横滑快进/快退）

  @objc private func onPan(_ gesture: UIPanGestureRecognizer) {
    guard let state = lastState else { return }
    let point = gesture.location(in: self)
    switch gesture.state {
    case .began:
      panStart = point
      panMode = .none
      panStartBrightness = Double(UIScreen.main.brightness)
      let now = Date()
      if let last = lastVolume, now.timeIntervalSince(last.at) < 2.0 {
        panStartVolume = last.value
      } else {
        panStartVolume = Double(AVAudioSession.sharedInstance().outputVolume)
      }
      panStartPosition = state.position
      panStartDuration = state.duration
      panSeekTarget = state.position
    case .changed:
      let dx = point.x - panStart.x
      let dy = point.y - panStart.y
      if panMode == .none {
        if abs(dx) > abs(dy) {
          // 横滑快进/快退：没时长（直播/未知）时不做。
          if panStartDuration > 0 { panMode = .seek } else { return }
        } else if panStart.x < bounds.width / 2 {
          panMode = .brightness
        } else {
          panMode = .volume
        }
      }
      switch panMode {
      case .brightness:
        // 上滑增大：整屏高度拖满 = 0..1；下限 0.05，避免全黑。
        let next = min(1.0, max(0.05, panStartBrightness - Double(dy) / Double(bounds.height)))
        UIScreen.main.brightness = CGFloat(next)
        showIndicator("亮度 \(Int(next * 100))%")
      case .volume:
        let next = min(1.0, max(0.0, panStartVolume - Double(dy) / Double(bounds.height)))
        lastVolume = (next, Date())
        if let slider = systemVolumeSlider() {
          slider.value = Float(next)
          slider.sendActions(for: .valueChanged)
        }
        showIndicator("音量 \(Int(next * 100))%")
      case .seek:
        panSeekTarget = min(max(panStartPosition + Double(dx) / Double(bounds.width) * panStartDuration, 0), panStartDuration)
        currentTimeLabel.text = formatTime(panSeekTarget)
        progressSlider.value = Float(panSeekTarget)
        showIndicator("\(formatTime(panSeekTarget)) / \(formatTime(panStartDuration))")
      case .none:
        break
      }
    case .ended, .cancelled:
      if panMode == .seek && gesture.state == .ended {
        engine?.seek(to: panSeekTarget)
      }
      panMode = .none
      pokeControls()
    default:
      break
    }
  }

  /// 系统音量没有公开的设置 API：藏一个 1×1 的 MPVolumeView，
  /// 写它的滑块（与 OrientationPlugin 同一套做法）。
  private func systemVolumeSlider() -> UISlider? {
    if volumeView == nil {
      let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
      view.isHidden = true
      addSubview(view)
      view.layoutIfNeeded()
      volumeView = view
    }
    return volumeView?.subviews.compactMap { $0 as? UISlider }.first
  }

  // MARK: - 旋转

  /// 与 OrientationPlugin.setOrientation 同一套 API：iOS 16+ 走
  /// scene.requestGeometryUpdate，iOS 15 走 KVC 老路。
  private func requestOrientation(landscape: Bool) {
    if #available(iOS 16.0, *) {
      guard let scene = window?.windowScene else { return }
      let mask: UIInterfaceOrientationMask = landscape ? [.landscapeLeft, .landscapeRight] : .portrait
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    } else {
      if landscape {
        let current = UIDevice.current.orientation
        let target: UIInterfaceOrientation =
          (current == .landscapeLeft || current == .landscapeRight)
          ? UIInterfaceOrientation(rawValue: current.rawValue) ?? .landscapeLeft
          : .landscapeLeft
        UIDevice.current.setValue(target.rawValue, forKey: "orientation")
      } else {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
      }
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  // MARK: - 格式化

  private func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite && seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
  }

  private func formatRate(_ rate: Double) -> String {
    if rate == Double(Int(rate)) {
      return "\(Int(rate))×"
    }
    return "\(rate)×"
  }
}
