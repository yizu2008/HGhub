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
    // MPVKit 28 个 LGPL 产物是 SPM 二进制目标（XCFramework，静态库），
    // swift build 只把它们下到构建目录，不会链进 NativePlugins 静态库，
    // 更不会进最终 Xcode 链接——v0.0.121 就是这么挂的（`_mpv_*` 全是
    // undefined symbols，`framework 'Libmpv' not found`）。这里在
    // swift build 跑完后，把 28 个产物的 device/sim 切片拷到
    // gen/apple/MPVKit/，由 build-ios-unsigned.sh 的 xcodebuild 参数
    // （FRAMEWORK_SEARCH_PATHS + OTHER_LDFLAGS）链进最终可执行文件。
    // XCFramework 里是静态库（ar archive），不用嵌进 .app，所以没有
    // --install-app 步骤。28 个是 MPVKit 0.41.0 的 LGPL 产品
    // `MPVKit` 的传递闭包（从它的 Package.swift 算出；0.41.0 与
    // 0.40.0-xcode 同名同数，清单不用改）；换 MPVKit 版本要重新算。
    // 只在 macOS host + iOS target 跑。
    // v0.0.127 懒加载：MPVKit 28 个静态库只暂存、不链进主程序。
    // stage_mpvkit_frameworks 把 28 个产物的 ios-arm64 切片拷到
    // gen/apple/MPVKit/，build-ios-unsigned.sh 在 xcodebuild 之后
    // 用它们打一个 MPVKit.framework 动态库、嵌进 .app/Frameworks/，
    // 选 mpv 播放时才 dlopen。主程序启动时完全不碰 MPVKit（126 已
    // 证实摘掉就启动），所以 OTHER_LDFLAGS 里不再加 MPVKit 的
    // -framework（见 build-ios-unsigned.sh）。只在 macOS host +
    // iOS target 跑。
    #[cfg(target_os = "macos")]
    stage_mpvkit_frameworks(&manifest_dir);
}

/// MPVKit LGPL 产品 `MPVKit` 的传递闭包（0.41.0，28 个二进制目标）。
/// 顺序是链接拓扑（被依赖的在后），build-ios-unsigned.sh 里按此顺序
/// 传 -framework（同一组列两遍，防静态库循环依赖漏符号）。
#[cfg(target_os = "macos")]
const MPVKIT_FRAMEWORKS: [&str; 28] = [
    "Libmpv", "Libavdevice", "Libavfilter", "Libavformat", "Libavcodec",
    "Libass", "Libbluray", "Libssl", "gnutls", "Libswscale",
    "Libswresample", "Libplacebo", "Libshaderc_combined", "MoltenVK",
    "Libdovi", "Libdav1d", "Libuavs3d", "Libharfbuzz", "Libfreetype",
    "Libfribidi", "Libunibreak", "lcms2", "Libcrypto", "nettle",
    "hogweed", "gmp", "Libavutil", "Libuchardet",
];

/// 把 MPVKit 28 个产物的对应切片拷到 gen/apple/MPVKit/（见上）。
/// swift-rs 把 SPM 包编到 OUT_DIR/swift-rs/NativePlugins（构建目录），
/// 二进制产物在它下面；布局不硬编码，递归按名找。
#[cfg(target_os = "macos")]
fn stage_mpvkit_frameworks(manifest_dir: &Path) {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target != "aarch64-apple-ios" && target != "aarch64-apple-ios-sim" {
        return;
    }
    let slice = if target == "aarch64-apple-ios-sim" {
        "ios-arm64-simulator"
    } else {
        "ios-arm64"
    };
    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let swift_build_dir = out_dir.join("swift-rs").join("NativePlugins");
    let stage_dir = manifest_dir.join("gen").join("apple").join("MPVKit");
    let mut missing: Vec<&str> = Vec::new();
    for name in MPVKIT_FRAMEWORKS {
        match find_xcframework(&swift_build_dir, name) {
            Some(xc) => {
                // 两种形态：多数是 <Name>.framework（目录），MoltenVK 是
                // 库型 XCFramework——切片里只有 libMoltenVK.a，没有
                // .framework 包（见 v0.0.122 构建日志的 Copying 步）。
                let slice_dir = xc.join(slice);
                let framework = slice_dir.join(format!("{name}.framework"));
                let lib = slice_dir.join(format!("lib{name}.a"));
                if framework.is_dir() {
                    let dest = stage_dir.join(format!("{name}.framework"));
                    let _ = std::fs::remove_dir_all(&dest);
                    copy_dir_filtered(&framework, &dest, &[]);
                } else if lib.is_file() {
                    let dest = stage_dir.join(format!("lib{name}.a"));
                    let _ = std::fs::remove_file(&dest);
                    std::fs::copy(&lib, &dest).unwrap_or_else(|e| {
                        panic!("MPVKit staging：拷 {name} 的静态库失败：{e}")
                    });
                } else {
                    missing.push(name);
                }
            }
            None => missing.push(name),
        }
    }
    if !missing.is_empty() {
        panic!(
            "MPVKit staging 缺少产物（swift build 没下下来？）：{}",
            missing.join(", ")
        );
    }
}

/// 在 `root` 下递归找名为 `{name}.xcframework` 的目录。
#[cfg(target_os = "macos")]
fn find_xcframework(root: &Path, name: &str) -> Option<PathBuf> {
    let want = format!("{name}.xcframework");
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if entry.file_name() == want.as_str() && path.is_dir() {
                return Some(path);
            }
            if path.is_dir() {
                stack.push(path);
            }
        }
    }
    None
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
