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
    // AetherEngine 的二进制依赖（FFmpegBuild 的 AetherLib* 动态 framework
    // + LibDovi 的 libdovi.a）由 swift build 拷进 swift-rs 产物目录，但
    // swift-rs 只把 libNativePlugins.a 的搜索路径告诉 cargo，Xcode 链接
    // 时找不到这些 framework（ld: framework not found，131 个未定义符号）。
    // 这里把它们拷到 gen/apple/AetherLib/（固定位置），build 脚本再把
    // 该目录加进 FRAMEWORK_SEARCH_PATHS / LIBRARY_SEARCH_PATHS，并把
    // framework 嵌进 .app/Frameworks/。找不到就直接 panic，宁可构建
    // 失败也不要链进过期 framework。
    #[cfg(target_os = "macos")]
    stage_aether_frameworks(&manifest_dir);
    // mpv 原生 dylib（v0.0.142 起，不再用 MPVKit）：已 vendor 在
    // src-tauri/ios/mpv-dylibs/，build-ios-unsigned.sh 在 xcodebuild
    // 之后直接拷进 .app/Frameworks/，选 mpv 播放时才 dlopen。这里不
    // 用 staging、不链进主程序（启动零引用，126 的教训）。
}

/// 把 swift build 产物里的 AetherEngine 二进制依赖拷到
/// `gen/apple/AetherLib/`（固定位置，供 Xcode 链接与装包）。
/// 产物目录布局随 Xcode 版本变（26 是 arm64-apple-macosx/release，
/// 27 是 Products/Release-iphoneos），不写死路径，递归按名字找。
/// framework 取产物目录里已拷出来的那份；libdovi.a 不取产物目录
/// 里的那份（它是 macOS slice，见函数内注释），改从 checkouts/
/// 里 LibDovi 原包的 xcframework ios-arm64 slice 取。
#[cfg(target_os = "macos")]
fn stage_aether_frameworks(manifest_dir: &Path) {
    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR not set");
    let swift_root = PathBuf::from(out_dir)
        .join("swift-rs")
        .join("NativePlugins");
    let mut frameworks: Vec<PathBuf> = Vec::new();
    let mut dovis: Vec<PathBuf> = Vec::new();
    fn walk(dir: &Path, frameworks: &mut Vec<PathBuf>, dovis: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let Ok(ft) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with("AetherLib") && name.ends_with(".framework") {
                frameworks.push(entry.path());
            } else if name == "libdovi.a" {
                dovis.push(entry.path());
            } else if ft.is_dir() && name != "checkouts" {
                walk(&entry.path(), frameworks, dovis);
            }
        }
    }
    walk(&swift_root, &mut frameworks, &mut dovis);
    if frameworks.is_empty() {
        panic!(
            "AetherEngine framework 未找到：swift build 产物目录 {} 下没有 AetherLib*.framework",
            swift_root.display()
        );
    }
    // framework 与 libdovi.a 在构建树里不止一份（xcframework 解包后
    // 各 slice、宿主构建产物里都有）；产物目录是 framework 所在的那
    // 个目录（9 个都在同一目录），libdovi.a 必须取同一目录下的那份
    // （iOS slice）。直接取遍历到的最后一
    // 份会拿到 macOS slice（150 第四轮 CI 就是这么挂的：ld 报
    // libdovi.a built for 'macOS'）。
    let mut by_dir: Vec<(PathBuf, usize)> = Vec::new();
    for fw in &frameworks {
        let dir = fw.parent().unwrap().to_path_buf();
        if let Some(slot) = by_dir.iter_mut().find(|(d, _)| *d == dir) {
            slot.1 += 1;
        } else {
            by_dir.push((dir, 1));
        }
    }
    by_dir.sort_by(|a, b| b.1.cmp(&a.1));
    let (products_dir, _) = by_dir.into_iter().next().unwrap();
    let frameworks: Vec<PathBuf> = frameworks
        .into_iter()
        .filter(|fw| fw.parent().unwrap() == products_dir)
        .collect();
    // libdovi.a 不取产物目录里的那份：150 第四、五轮 CI 证明它就是
    // macOS slice（两轮 ld 报错的对象名完全相同），而同一目录下的
    // 9 个 framework 全是 iOS slice、链接正常（两轮都是零未定义
    // 符号，只挂 libdovi.a）。改成直接从 LibDovi 原包的
    // xcframework 里取 ios-arm64 slice（LibDovi Package.swift 里
    // binaryTarget path: "Dovi.xcframework"，Info.plist 声明的
    // ios-arm64 slice 存在）；原包路径不存在时才回退到产物目录
    // 里同目录的那份，两个都没有直接 panic。
    let xcframework_dovi = swift_root
        .join("checkouts")
        .join("LibDovi")
        .join("Dovi.xcframework")
        .join("ios-arm64")
        .join("libdovi.a");
    let dovi = if xcframework_dovi.is_file() {
        xcframework_dovi
    } else if let Some(d) = dovis
        .iter()
        .find(|d| d.parent().unwrap() == products_dir)
        .cloned()
    {
        d
    } else {
        panic!(
            "libdovi.a 未找到：LibDovi 原包 {} 不存在，framework 所在目录 {} 下也没有 libdovi.a（找到的候选：{:?}）",
            xcframework_dovi.display(),
            products_dir.display(),
            dovis
        );
    };
    // gen/ 已在 .gitignore 里，staging 不会进仓库；每次先清掉再拷，
    // 防止链进上个版本的过期 framework。
    let stage = manifest_dir.join("gen").join("apple").join("AetherLib");
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).expect("failed to create AetherLib stage dir");
    for fw in &frameworks {
        let dest = stage.join(fw.file_name().unwrap());
        copy_dir_preserve_symlinks(fw, &dest);
    }
    std::fs::copy(&dovi, stage.join("libdovi.a")).expect("failed to stage libdovi.a");
    println!(
        "cargo:warning=staged {} AetherLib frameworks + libdovi.a (from {}) to {}",
        frameworks.len(),
        dovi.display(),
        stage.display()
    );
}

/// 递归拷目录，保留符号链接（.framework 里 Headers/Current 等是链接，
/// fs::copy 会跟随链接把目录当文件拷而报错）。
#[cfg(target_os = "macos")]
fn copy_dir_preserve_symlinks(src: &Path, dst: &Path) {
    std::fs::create_dir_all(dst).expect("failed to create dir");
    for entry in std::fs::read_dir(src).expect("failed to read dir") {
        let entry = entry.expect("failed to read entry");
        let from = entry.path();
        let to = dst.join(entry.file_name());
        let meta = std::fs::symlink_metadata(&from).expect("failed to stat");
        if meta.file_type().is_symlink() {
            let target = std::fs::read_link(&from).expect("failed to read link");
            std::os::unix::fs::symlink(&target, &to).expect("failed to create symlink");
        } else if meta.is_dir() {
            copy_dir_preserve_symlinks(&from, &to);
        } else {
            std::fs::copy(&from, &to).expect("failed to copy file");
        }
    }
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
