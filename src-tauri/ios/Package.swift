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
    // v0.0.141 起是 macOS 11 / iOS 14（当时 MPVKit 0.41.0 的要求）。
    // v0.0.142 起不再用 MPVKit（改嵌原生 dylib，见
    // src-tauri/ios/mpv-dylibs/README.md），底线保持 macOS 11 /
    // iOS 14 不变——dylib 本身的 minOS 由构建方定，dlopen 失败时
    // mpv 只报 unavailable、播放链回落，不影响启动。
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
      ],
      path: "Sources")
  ]
)
