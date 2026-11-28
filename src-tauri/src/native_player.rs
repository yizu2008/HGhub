// iOS 原生播放器桥：React -> Tauri 命令 -> Swift NativePlayerPlugin -> 四个引擎。
// WebView / <video> 仍是默认播放路径（见 VideoSurface.tsx），这里只在用户
// 选了原生引擎且平台是 iOS 时才转发；非 iOS 平台命令直接返回明确错误。

use serde::{Deserialize, Serialize};
#[cfg(target_os = "ios")]
use serde_json::{json, Value};
#[cfg(target_os = "ios")]
use tauri::Manager;

/// Swift 侧的插件入口（src-tauri/ios/NativePlayerPlugin.swift 里的
/// `@_cdecl("init_plugin_native_player")`）。写法与官方 tauri-plugin-dialog
/// 完全一致：`tauri::ios_plugin_binding!` + `api.register_ios_plugin(init_fn)`。
/// 只在 iOS 编译；Linux/macOS/Windows/Android 上不存在这个符号。
#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_native_player);

/// iOS 移动插件句柄（与 commands.rs 里的 OrientationPlugin 同一模式）。
#[cfg(target_os = "ios")]
pub struct NativePlayerPlugin(pub tauri::plugin::PluginHandle<tauri::Wry>);

/// 四个原生引擎。名字与前端 NativeEngine、Swift makeEngine 保持一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NativeEngine {
    Avplayer,
    Mdk,
    Ksplayer,
    Mpv,
}

/// open / play / pause / seek / set_rate / set_volume 的回包：Swift 侧
/// NativePlayerState 编码后键名是 Swift 属性名（videoWidth/videoHeight
/// 驼峰，无 CodingKeys），Rust 侧必须用 camelCase 对齐，否则
/// run_mobile_plugin_async 反序列化回包时报
/// "missing field `video_width`"——回包解不到不代表没播：Swift 侧在
/// open 完成回调里先 present 再 resolve，播放器已经弹出来了，只是
/// invoke 的 Promise 被拒，DownloadManager 就显示报错横条。
/// 序列化方向也一样：前端 NativePlayerState 声明的是 videoWidth。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativePlayerState {
    pub engine: Option<String>,
    pub playing: bool,
    pub position: f64,
    pub duration: f64,
    pub rate: f64,
    pub volume: f64,
    pub muted: bool,
    /// 当前视频原始分辨率（像素）；0 表示未知（引擎未报或未加载出视频轨）。
    pub video_width: u32,
    pub video_height: u32,
    /// mpv 诊断（v0.0.137 起）：.log 事件到不了前端，改走 state 命令。
    /// 最近 30 行 mpv 日志 + 总行数 + 事件循环是否跑起来过；其它引擎为默认。
    /// 缺省 default——旧版 Swift 回包没有这些键时也不报错。
    #[serde(default)]
    pub mpv_log_count: u64,
    #[serde(default)]
    pub mpv_log_lines: Vec<String>,
    #[serde(default)]
    pub mpv_event_loop_alive: bool,
    /// mpv 诊断（v0.0.139 起）：138 真机 mpv 日志行数恒为 0，改直接读
    /// mpv 状态量透传给前端；缺省 default——旧版 Swift 回包没有这些键
    /// 时也不报错。
    #[serde(default)]
    pub mpv_idle_active: bool,
    #[serde(default)]
    pub mpv_vo_configured: bool,
    #[serde(default)]
    pub mpv_paused_for_cache: bool,
    #[serde(default)]
    pub mpv_events_drained: u64,
    #[serde(default)]
    pub mpv_open_diag: String,
}

/// 向 Swift 插件注册 "native-player"。setup 闭包与 native_player.rs 在同一
/// 模块内引用 init_plugin_native_player（宏生成的绑定只在本模块可见）。
pub fn plugin() -> tauri::plugin::TauriPlugin<tauri::Wry> {
    tauri::plugin::Builder::<tauri::Wry, ()>::new("native-player")
        .setup(|app, api| {
            #[cfg(target_os = "ios")]
            {
                let handle = api.register_ios_plugin(init_plugin_native_player)?;
                app.manage(NativePlayerPlugin(handle));
            }
            #[cfg(not(target_os = "ios"))]
            let _ = (app, api);
            Ok(())
        })
        .build()
}

#[cfg(target_os = "ios")]
async fn forward<T: serde::de::DeserializeOwned>(
    plugin: &tauri::State<'_, NativePlayerPlugin>,
    command: &str,
    payload: Value,
) -> Result<T, String> {
    plugin
        .0
        .run_mobile_plugin_async::<T>(command, payload)
        .await
        .map_err(|error| error.to_string())
}

#[cfg(target_os = "ios")]
fn open_payload(
    engine: NativeEngine,
    url: String,
    session_id: String,
    position: f64,
    rate: f64,
    volume: f64,
    muted: bool,
    title: Option<String>,
    hardware_acceleration: bool,
) -> Value {
    // 注意：这里的 session_id 是发给 Swift 插件的载荷键名（Swift 侧按
    // snake_case 解），与 Tauri invoke 参数名是两回事。Tauri invoke 默认
    // 按 camelCase 传参（tauri-macros 默认 rename_all="camelCase"），所以
    // 前端 nativePlayer.ts 里 invoke 用的是 sessionId。
    json!({
        "engine": engine,
        "url": url,
        "session_id": session_id,
        "position": position,
        "rate": rate,
        "volume": volume,
        "muted": muted,
        "title": title,
        "hardware_acceleration": hardware_acceleration,
    })
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_open(
    plugin: tauri::State<'_, NativePlayerPlugin>,
    engine: NativeEngine,
    url: String,
    session_id: String,
    position: f64,
    rate: f64,
    volume: f64,
    muted: bool,
    title: Option<String>,
    hardware_acceleration: bool,
) -> Result<NativePlayerState, String> {
    forward(
        &plugin,
        "open",
        open_payload(engine, url, session_id, position, rate, volume, muted, title, hardware_acceleration),
    )
    .await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_open(
    engine: NativeEngine,
    url: String,
    session_id: String,
    position: f64,
    rate: f64,
    volume: f64,
    muted: bool,
    title: Option<String>,
    hardware_acceleration: bool,
) -> Result<NativePlayerState, String> {
    let _ = (engine, url, session_id, position, rate, volume, muted, title, hardware_acceleration);
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_close(
    plugin: tauri::State<'_, NativePlayerPlugin>,
) -> Result<(), String> {
    forward::<()>(&plugin, "close", json!({})).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_close() -> Result<(), String> {
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_play(
    plugin: tauri::State<'_, NativePlayerPlugin>,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "play", json!({})).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_play() -> Result<NativePlayerState, String> {
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_pause(
    plugin: tauri::State<'_, NativePlayerPlugin>,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "pause", json!({})).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_pause() -> Result<NativePlayerState, String> {
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_seek(
    plugin: tauri::State<'_, NativePlayerPlugin>,
    position: f64,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "seek", json!({ "position": position })).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_seek(position: f64) -> Result<NativePlayerState, String> {
    let _ = position;
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_set_rate(
    plugin: tauri::State<'_, NativePlayerPlugin>,
    rate: f64,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "setRate", json!({ "rate": rate })).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_set_rate(rate: f64) -> Result<NativePlayerState, String> {
    let _ = rate;
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_set_volume(
    plugin: tauri::State<'_, NativePlayerPlugin>,
    volume: f64,
    muted: bool,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "setVolume", json!({ "volume": volume, "muted": muted })).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_set_volume(volume: f64, muted: bool) -> Result<NativePlayerState, String> {
    let _ = (volume, muted);
    Err("当前平台不支持原生播放器".into())
}

#[cfg(target_os = "ios")]
#[tauri::command]
pub async fn native_player_state(
    plugin: tauri::State<'_, NativePlayerPlugin>,
) -> Result<NativePlayerState, String> {
    forward(&plugin, "state", json!({})).await
}

#[cfg(not(target_os = "ios"))]
#[tauri::command]
pub fn native_player_state() -> Result<NativePlayerState, String> {
    Err("当前平台不支持原生播放器".into())
}

#[cfg(test)]
mod tests {
    use super::NativePlayerState;

    /// Swift 侧 NativePlayerState 无 CodingKeys，编码后键名是 Swift
    /// 属性名（videoWidth/videoHeight 驼峰）；Rust 侧必须用 camelCase
    /// 对齐。v0.0.38 之前这里没加 rename_all，Rust 按 snake_case 解，
    /// 真机报 missing field `video_width`（播放器其实已经弹出来了，
    /// 只是回包解不到，invoke 被拒）。
    #[test]
    fn state_matches_swift_camel_case_keys() {
        let from_swift = serde_json::json!({
            "engine": "avplayer",
            "playing": true,
            "position": 1.5,
            "duration": 187.0,
            "rate": 1.0,
            "volume": 1.0,
            "muted": false,
            "videoWidth": 1280,
            "videoHeight": 720,
            "mpvLogCount": 3,
            "mpvLogLines": ["vo/gpu: 1920x800", "vo/gpu: done"],
            "mpvEventLoopAlive": true,
            "mpvIdleActive": false,
            "mpvVoConfigured": true,
            "mpvPausedForCache": false,
            "mpvEventsDrained": 17,
            "mpvOpenDiag": "init=0 loadfile=0 url=http://127.0.0.1"
        });
        let state: NativePlayerState =
            serde_json::from_value(from_swift).expect("Swift 回包应按驼峰键解出");
        assert_eq!(state.video_width, 1280);
        assert_eq!(state.video_height, 720);
        assert_eq!(state.mpv_log_count, 3);
        assert_eq!(state.mpv_log_lines.len(), 2);
        assert!(state.mpv_event_loop_alive);
        assert!(!state.mpv_idle_active);
        assert!(state.mpv_vo_configured);
        assert!(!state.mpv_paused_for_cache);
        assert_eq!(state.mpv_events_drained, 17);
        assert_eq!(state.mpv_open_diag, "init=0 loadfile=0 url=http://127.0.0.1");
        // 序列化方向也一样：前端 NativePlayerState 声明的是 videoWidth。
        let back = serde_json::to_value(&state).unwrap();
        assert_eq!(back["videoWidth"], 1280);
        assert!(back.get("video_width").is_none());
        assert_eq!(back["mpvLogCount"], 3);
        assert_eq!(back["mpvEventLoopAlive"], true);
        assert_eq!(back["mpvVoConfigured"], true);
        assert_eq!(back["mpvEventsDrained"], 17);
        assert_eq!(back["mpvOpenDiag"], "init=0 loadfile=0 url=http://127.0.0.1");
    }
}
