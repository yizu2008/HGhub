// swift-tools-version:5.9
// （5.3 是 Tauri 模板原值；mpv 依赖的 `.package(url:exact:)` 要
// PackageDescription 5.6 才有，5.3 下 CI 报 'package(url:exact:)'
// is unavailable，见 v0.0.117 的 iOS 构建日志。5.9 是因为平台：
// `.macOS(.v14)` 要 5.9 才有、`.iOS(.v16)` 要 5.7，5.6 下 manifest
// 编译直接报 'v14'/'v16' is unavailable，见 v0.0.148 首轮 CI 日志。
// 5.9 仍是 Swift 5 语言模式，不会像 6.0 那样切 Swift 6。）
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
    // v0.0.148 起是 macOS 14 / iOS 16（AetherEngine 6.x 线的要求，
    // 见下）。之前是 macOS 11 / iOS 14（MPVKit 0.41.0 时代）。
    // 应用的 MinOS 也随之从 15.0 抬到 16.0：15.0 是 Tauri 模板的
    // 生成默认值，仓库里没有地方写死它，抬升靠
    // scripts/build-ios-unsigned.sh 的 xcodebuild 参数
    // IPHONEOS_DEPLOYMENT_TARGET=16.0。
    .macOS(.v14),
    .iOS(.v16),
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
    // AetherEngine（v0.0.148 起）：独立开源播放引擎
    // （github.com/superuser404notfound/AetherEngine），FFmpeg n8.1.3
    // + VideoToolbox 硬解 + dav1d 软解，DV P7→8.1 转换。只走 6.x 线：
    // 上游 7.x 要求 iOS 18，用户手机是 16.6.1 跑不了；6.89.1 要求
    // iOS 16。版本用 "6.89.1"..<"7.0.0" 的范围写法——等价于上游
    // 文档说的 `.upToNextMajor(from: "6.89.1")`，但那个写法要
    // swift-tools 6.0 以上；本包用 5.9（升 6.0 会把整个包切到
    // Swift 6 语言模式，现有代码要重过并发检查），范围写法 5.6
    // 就有，5.9 也支持。只 link `AetherEngine` product；SMB 播放用的
    // `AetherEngineSMB` 没接，不需要。
    .package(url: "https://github.com/superuser404notfound/AetherEngine", "6.89.1"..<"7.0.0"),
    // mpv 原生 dylib（v0.0.142 起，替代 MPVKit）：已 vendor 在
    // src-tauri/ios/mpv-dylibs/（mpv 0.41.0 + FFmpeg 8.1-dev 一代，
    // UZN 1.9.0 包里同款开源库），build-ios-unsigned.sh 在 xcodebuild
    // 之后直接拷进 .app/Frameworks/，选 mpv 播放时才 dlopen。
    // 这里不再声明 MPVKit 依赖，Swift 代码也不 `import Libmpv`
    //（改 dlopen + dlsym，见 engines/MPVEngine.swift）。主程序启动
    // 时完全不碰 mpv（v0.0.124/125 静态链入后启动黑屏，126 摘掉就
    // 启动，已证实是它）。
  ],
  targets: [
    // Targets are the basic building blocks of a package. A target can define a module or a test suite.
    // Targets can depend on other targets in this package, and on products in packages this package depends on.
    .target(
      name: "NativePlugins",
      dependencies: [
        .byName(name: "Tauri"),
        .product(name: "AetherEngine", package: "AetherEngine"),
      ],
      path: "Sources")
  ]
)
