import { invoke, addPluginListener, type PluginListener } from "@tauri-apps/api/core";
import { platform } from "../environment";

// iOS 原生播放器前端封装：React -> Rust native_player_* 命令 ->
// Swift NativePlayerPlugin -> 各原生引擎。WebView / <video> 仍是
// 一条路，v0.0.148 起默认是 auto（原生优先），只在用户选了 WebView
// 时才走内嵌（见 playbackEngine.ts 与 Feed.tsx）。
//
// 注意 invoke 参数名：Tauri `#[tauri::command]` 默认按 camelCase 传参
// （tauri-macros 默认 rename_all="camelCase"），Rust 形参 session_id
// 对应 JS 键 sessionId，这里传的就是 sessionId。不要改成 snake_case，
// v0.0.33 的 downloadId 就是这么错过的。
// 注意回包字段名：Swift 回包的键是驼峰 videoWidth（见
// NativePlayerPlugin.swift 的 NativePlayerState，无 CodingKeys），
// Rust 侧 NativePlayerState 用 rename_all="camelCase" 对齐，前端
// NativePlayerState 接口声明的也是 videoWidth。

export type NativeEngine = "avplayer" | "mpv" | "aether";

export interface NativePlayerOpenOptions {
  engine: NativeEngine;
  url: string;
  sessionId: string;
  position?: number;
  rate?: number;
  volume?: number;
  muted?: boolean;
  title?: string;
  /** mpv 硬件加速（v0.0.146）：true = videotoolbox-copy，false = 软解；其它引擎忽略。 */
  hardwareAcceleration?: boolean;
}

export interface NativePlayerState {
  engine: string | null;
  playing: boolean;
  position: number;
  duration: number;
  rate: number;
  volume: number;
  muted: boolean;
  /** 当前视频原始分辨率（像素）；0 表示未知。 */
  videoWidth: number;
  videoHeight: number;
  /** mpv 诊断（v0.0.137 起）：最近 30 行 mpv 日志 + 总行数 + 事件循环是否跑起来过；其它引擎为默认。 */
  mpvLogCount: number;
  mpvLogLines: string[];
  mpvEventLoopAlive: boolean;
  /** mpv 诊断（v0.0.139 起）：138 真机日志行数恒为 0，改直接读状态量。idle-active / vo-configured / paused-for-cache + 事件循环累计排空数 + 打开时的返回码与 URL 归属（只记 scheme/host）；其它引擎为默认。 */
  mpvIdleActive: boolean;
  mpvVoConfigured: boolean;
  mpvPausedForCache: boolean;
  mpvEventsDrained: number;
  mpvOpenDiag: string;
}

export interface NativePlayerTimeEvent {
  engine: string;
  sessionId: string;
  position: number;
  duration: number;
  /** 当前视频原始分辨率（像素）；0 表示未知。 */
  videoWidth: number;
  videoHeight: number;
}

export interface NativePlayerEndEvent {
  engine: string;
  sessionId: string;
  position: number;
}

export interface NativePlayerErrorEvent {
  engine: string;
  sessionId: string;
  message: string;
}

export interface NativePlayerClosedEvent {
  engine: string;
  sessionId: string;
  position: number;
}

export interface NativePlayerLogEvent {
  engine: string;
  sessionId: string;
  message: string;
}

/** 只有 iOS 才有原生播放器桥；其它平台 invoke 会直接报“不支持”。 */
export function isNativePlayerAvailable(): boolean {
  return platform === "ios";
}

/** 本地已下载文件正在走原生播放（AVPlayer）：Feed 里注册的
 * native-player-closed / native-player-error 回落逻辑（回到当前
 * 在播的在线流）这时不适用——关掉就是回到下载管理，不回流。
 * DownloadManager 点播前置位，Feed 的关闭/报错回调里读到就清位
 * 并跳过回落。模块级标记即可，两边共用同一个原生播放器。 */
let localPlayback = false;
export function markLocalNativePlayback(): void {
  localPlayback = true;
}
export function isLocalNativePlayback(): boolean {
  return localPlayback;
}
export function clearLocalNativePlayback(): void {
  localPlayback = false;
}

export function openNativePlayer(options: NativePlayerOpenOptions): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_open", {
    engine: options.engine,
    url: options.url,
    sessionId: options.sessionId,
    position: options.position ?? 0,
    rate: options.rate ?? 1,
    volume: options.volume ?? 1,
    muted: options.muted ?? false,
    title: options.title,
    hardwareAcceleration: options.hardwareAcceleration ?? true,
  });
}

export function closeNativePlayer(): Promise<void> {
  return invoke<void>("native_player_close", {});
}

export function playNativePlayer(): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_play", {});
}

export function pauseNativePlayer(): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_pause", {});
}

export function seekNativePlayer(position: number): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_seek", { position });
}

export function setNativePlayerRate(rate: number): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_set_rate", { rate });
}

export function setNativePlayerVolume(volume: number, muted: boolean): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_set_volume", { volume, muted });
}

export function nativePlayerState(): Promise<NativePlayerState> {
  return invoke<NativePlayerState>("native_player_state", {});
}

export function onNativePlayerTime(cb: (event: NativePlayerTimeEvent) => void): Promise<PluginListener> {
  return addPluginListener<NativePlayerTimeEvent>("native-player", "native-player-time", cb);
}

export function onNativePlayerEnded(cb: (event: NativePlayerEndEvent) => void): Promise<PluginListener> {
  return addPluginListener<NativePlayerEndEvent>("native-player", "native-player-ended", cb);
}

export function onNativePlayerError(cb: (event: NativePlayerErrorEvent) => void): Promise<PluginListener> {
  return addPluginListener<NativePlayerErrorEvent>("native-player", "native-player-error", cb);
}

export function onNativePlayerClosed(cb: (event: NativePlayerClosedEvent) => void): Promise<PluginListener> {
  return addPluginListener<NativePlayerClosedEvent>("native-player", "native-player-closed", cb);
}

export function onNativePlayerLog(cb: (event: NativePlayerLogEvent) => void): Promise<PluginListener> {
  return addPluginListener<NativePlayerLogEvent>("native-player", "native-player-log", cb);
}
