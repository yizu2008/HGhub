// swift-tools-version:5.6
// （5.3 是 Tauri 模板原值；mpv 依赖的 `.package(url:exact:)` 要
// PackageDescription 5.6 才有，5.3 下 CI 报 'package(url:exact:)'
// is unavailable，见 v0.0.117 的 iOS 构建日志。）
// Copyright 2019-2023 Tauri Programme within The Commons Conservancy
// SPDX-License-Identifier: Apache-2.0
// SPDX-License-Identifier: MIT

import PackageDescription

// HGhub iOS 原生插件的 SPM 包：NativePlayerPlugin（native-player）与
// OrientationPlugin（orientation）共用这一个包、同一个 Swift 模块。
// 写法照搬官方 tauri-plugin-dialog 2.8.3 的 ios/Package.swift，只改
// 了包名与 target 名；依赖的 Tauri 模块来自 build.rs 在构建时拷到
// src-tauri/.tauri/tauri-api 的 tauri ios-api（见 src-tauri/build.rs）。
// 本包由 build.rs 经 SwiftLinker（swift build）在 macOS 构建时编成
// 静态库链进 Rust，Xcode 不编译这些文件——不要再把它们拷进
// gen/apple/Sources（那样会与静态库重复定义 init_plugin_* 符号）。
let package = Package(
  name: "NativePlugins",
  platforms: [
    // v0.0.141 起 MPVKit 0.41.0：它要求 macOS 11 / iOS 14（0.40.0
    // 是 macOS 10.15 / iOS 13）。macOS 10.15 的旧要求见 v0.0.119
    // 构建日志；iOS 14 底线是用户 2026-11-27 定的升版决定。
    .macOS(.v11),
    .iOS(.v14),
  ],
  products: [
    // Products define the executables and libraries a package produces, and make them visible to other packages.
    .library(
      name: "NativePlugins",
      type: .static,
      targets: ["NativePlugins"])
  ],
  dependencies: [
    .package(name: "Tauri", path: "../.tauri/tauri-api"),
    // mpv 软解（LGPL 版产品 `MPVKit`；GPL 版产品 `MPVKit-GPL` 含 Samba，
    // 与 HGhub 的 PolyForm Noncommercial 冲突，不要用）。
    // 钉 0.41.0 exact（v0.0.141 起；之前是 0.40.0-xcode）：0.41.0
    // 没有 -xcode 变体，38 个产物与 0.40.0-xcode 同名同数，LGPL
    // 闭包仍是那 28 个（build.rs 的 MPVKIT_FRAMEWORKS 不用改）。
    // 0.40.0 的 Libuavs3d / Libuchardet 清单校验和曾过期（子仓库
    // 重发了包、清单没跟上），0.41.0 的清单待 CI 验证。1.x 起最低
    // iOS 15.0，mpv 官方最新是 0.42.0（2026-11-05），但 MPVKit
    // 最新版（1.1.0-n9.0.2）里仍是 mpv 0.41.0，0.41.0 是目前能
    // 升到的最新。
    // 注意 MPVKit 只提供 libmpv/FFmpeg 的 XCFramework，没有 Swift
    // 播放器类——引擎直接调 libmpv C API（见 engines/MPVEngine.swift）。
    // v0.0.127 懒加载：这个依赖只让 SPM 把 XCFramework 下下来、供
    // build.rs 暂存到 gen/apple/MPVKit/，再由 build-ios-unsigned.sh
    // 打成 MPVKit.framework 动态库、嵌进 .app/Frameworks/，选 mpv
    // 播放时才 dlopen。主程序启动时完全不碰 MPVKit（v0.0.124/125
    // 静态链入后启动黑屏，126 摘掉就启动，已证实是它），所以
    // OTHER_LDFLAGS 里不再加 MPVKit 的 -framework；Swift 代码也不
    // 再 `import Libmpv`（改 dlopen + dlsym，见 MPVEngine.swift）。
    .package(url: "https://github.com/mpvkit/MPVKit.git", exact: "0.41.0")
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
      name: "NativePlugins",
      dependencies: [
        .byName(name: "Tauri"),
        .product(name: "MPVKit", package: "MPVKit"),
      ],
      path: "Sources")
  ]
)
