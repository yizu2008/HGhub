use std::path::{Path, PathBuf};

fn main() {
    // native-player 是 Rust 内联插件（native_player::plugin()）：它的权限
    // manifest 不在 app.toml 里，须经 InlinedPlugin 从
    // permissions/native-player/ 生成——只加文件不改 build.rs 是不够的。
    // v0.0.90：补 registerListener/removeListener 的权限定义，否则前端
    // addPluginListener("native-player", …) 在真机上被 ACL 拒绝。
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .plugin("native-player", tauri_build::InlinedPlugin::new()),
    )
    .expect("failed to build Tauri app");
    // tauri-build links its Common Controls v6 manifest only into binary targets.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        let out = std::env::var("OUT_DIR").unwrap();
        println!("cargo:rustc-link-arg-examples={out}/resource.lib");
    }

    // iOS 原生插件（src-tauri/ios/）走 SPM + SwiftLinker，与官方
    // tauri-plugin-dialog 的 build.rs 同款做法：Swift 代码编成静态库
    // 链进 Rust，Xcode 不编译这些文件。只在 iOS target 时做事，
    // 其他目标直接返回；macOS host 以外也直接返回（但函数本身不
    // 加 target_os cfg，让 Linux 上的 cargo check 也能验证它）。
    link_ios_native_plugins();
    // iOS 上 Rust 链接期找 Python.framework（见 link_python_framework）。
    link_python_framework();
    // iOS 上 SystemConfiguration.framework（见 link_system_configuration）。
    link_system_configuration();
}

/// iOS 上 Rust 链接期找 Python.framework。
///
/// `src/python.rs` 的裸 FFI 用 `#[link(name = "Python", kind = "framework")]`，
/// 只给链接器 `-framework Python`，不给搜索路径；Xcode 的
/// FRAMEWORK_SEARCH_PATHS 只对 Xcode 自己的链接生效，cargo 调 `cc` 链接
/// cdylib/staticlib 时拿不到，v0.0.54 在此挂掉（`ld: framework 'Python'
/// not found`）。这里在 iOS target 时把 xcframework 对应切片目录加进
/// framework 搜索路径；xcframework 由 sync-ios-python.mjs 在 xcodebuild
/// 之前解包到 gen/apple（CI 与本地同一套路径）。
fn link_python_framework() {
    let target = std::env::var("TARGET").unwrap_or_default();
    let slice = match target.as_str() {
        "aarch64-apple-ios" => "ios-arm64",
        "aarch64-apple-ios-sim" => "ios-arm64-simulator",
        _ => return,
    };
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let framework_dir = manifest_dir
        .join("gen")
        .join("apple")
        .join("Python.xcframework")
        .join(slice);
    println!(
        "cargo:rustc-link-search=framework={}",
        framework_dir.display()
    );
    println!("cargo:rerun-if-changed=gen/apple/Python.xcframework");
}

/// iOS 上链接 SystemConfiguration.framework。
///
/// `proxy.rs` 的 iOS 分支用 system-configuration crate 调
/// SCDynamicStoreCopyProxies 读系统代理；该 crate 只给链接器符号引用，
/// 不给 framework 链接参数，Xcode 的 app 链接也不会自动补上，v0.0.62
/// 在此挂掉（`Undefined symbols _SCDynamicStoreCopyProxies ...`）。
/// 这里在 iOS target 时显式链接该 framework；与 link_python_framework
/// 同款做法（只看 TARGET，不加 target_os cfg，让 Linux 上的 cargo
/// check 也能验证它）。
fn link_system_configuration() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target != "aarch64-apple-ios" && target != "aarch64-apple-ios-sim" {
        return;
    }
    println!("cargo:rustc-link-lib=framework=SystemConfiguration");
}

/// 把 src-tauri/ios/ 的 Swift 插件包（NativePlugins）编成静态库链进 Rust。
/// 1. 把 tauri 的 iOS Swift API（DEP_TAURI_IOS_LIBRARY_PATH，tauri 的
///    build.rs 以 cargo:ios_library_path 暴露）拷到 src-tauri/.tauri/tauri-api，
///    供 Package.swift 的 .package(path: "../.tauri/tauri-api") 引用
///    （路径是相对 Package.swift 所在目录解析的，也就是相对 ios/，
///    所以目标是 crate 根 src-tauri/ 下的 .tauri/，不是 ios/ 下）；
/// 2. 调 tauri_utils::build::link_apple_library("NativePlugins", ios-dir)，
///    由 swift-rs 以 swift build 编包并链接。
/// 非 macOS host 上 tauri 不输出 DEP_TAURI_IOS_LIBRARY_PATH，直接跳过，
/// 不报错（Linux 上编 Android / 桌面目标都走这条路）。
fn link_ios_native_plugins() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target != "aarch64-apple-ios" && target != "aarch64-apple-ios-sim" {
        return;
    }
    let Ok(tauri_api_src) = std::env::var("DEP_TAURI_IOS_LIBRARY_PATH") else {
        return;
    };
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    copy_tauri_api(Path::new(&tauri_api_src), &manifest_dir.join(".tauri").join("tauri-api"));

    println!("cargo:rerun-if-changed=ios/Package.swift");
    println!("cargo:rerun-if-changed=ios/Sources");
    #[cfg(target_os = "macos")]
    tauri_utils::build::link_apple_library("NativePlugins", &manifest_dir.join("ios"));
    // mpv 原生 dylib（v0.0.142 起，不再用 MPVKit）：已 vendor 在
    // src-tauri/ios/mpv-dylibs/，build-ios-unsigned.sh 在 xcodebuild
    // 之后直接拷进 .app/Frameworks/，选 mpv 播放时才 dlopen。这里不
    // 用 staging、不链进主程序（启动零引用，126 的教训）。
}

/// 把 tauri 的 iOS Swift API 目录拷到 `dst`（即 src-tauri/.tauri/tauri-api）。
/// 跳过构建产物与测试（.build / Package.resolved / Tests），与官方插件
/// 的拷贝规则一致。目标已存在且来源一致时跳过，避免无谓重写。
fn copy_tauri_api(src: &Path, dst: &Path) {
    const SKIP: [&str; 3] = [".build", "Package.resolved", "Tests"];
    // 用来源路径做标记：tauri 一升级，来源路径就变，下次自动重拷。
    let marker = dst.join(".tauri-src");
    let same = std::fs::read_to_string(&marker)
        .map(|s| s.trim() == src.to_string_lossy())
        .unwrap_or(false);
    if same && dst.join("Package.swift").exists() {
        return;
    }
    let _ = std::fs::remove_dir_all(dst);
    copy_dir_filtered(src, dst, &SKIP);
    let _ = std::fs::write(&marker, src.to_string_lossy().as_ref());
}

fn copy_dir_filtered(src: &Path, dst: &Path, skip: &[&str]) {
    std::fs::create_dir_all(dst).expect("failed to create tauri-api dir");
    for entry in std::fs::read_dir(src).expect("failed to read tauri ios-api dir") {
        let entry = entry.expect("failed to read tauri ios-api entry");
        let name = entry.file_name();
        if skip.iter().any(|s| name == *s) {
            continue;
        }
        let from = entry.path();
        let to = dst.join(&name);
        if entry
            .file_type()
            .expect("failed to stat tauri ios-api entry")
            .is_dir()
        {
            copy_dir_filtered(&from, &to, skip);
        } else {
            std::fs::copy(&from, &to).expect("failed to copy tauri ios-api file");
        }
    }
}
