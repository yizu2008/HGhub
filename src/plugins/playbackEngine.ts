import type { NativeEngine } from "./nativePlayer";

// 播放引擎选择。v0.0.148 起默认 "auto"：原生优先（先试 AVPlayer，
// 再试 mpv、AetherEngine），原生都打不开才回落 WebView；只在用户
// 明确选了 "webview" 时才内嵌。MDK / KSPlayer 已从选择里剔除
// （v0.0.146）：依赖没装、点了只会报“未接入”；引擎替身代码还在
// src-tauri/ios/Sources/engines/ 里（未接入时直接失败），哪天装好
// 依赖再把选项加回来。
export type PlaybackEngine = "webview" | NativeEngine | "auto";

export const DEFAULT_PLAYBACK_ENGINE: PlaybackEngine = "auto";

const ENGINES: readonly string[] = ["webview", "avplayer", "mpv", "aether", "auto"];

export function isPlaybackEngine(value: unknown): value is PlaybackEngine {
  return typeof value === "string" && (ENGINES as readonly string[]).includes(value);
}

export function isNativeEngine(engine: PlaybackEngine): engine is NativeEngine {
  return engine === "avplayer" || engine === "mpv" || engine === "aether";
}

export function playbackEngineLabel(engine: PlaybackEngine): string {
  switch (engine) {
    case "webview": return "WebView（原）";
    case "avplayer": return "AVPlayer";
    case "mpv": return "mpv";
    case "aether": return "AetherEngine";
    case "auto": return "自动";
  }
}

/**
 * 下拉框里的选项文案（v0.0.148）：原生内核后面标“（支持原生播放）”，
 * 让用户一眼看出哪个是原生路。角标（Feed.tsx 右上角）仍用短的
 * playbackEngineLabel，太长放不下。
 */
export function playbackEngineOptionLabel(engine: PlaybackEngine): string {
  switch (engine) {
    case "avplayer": return "AVPlayer（支持原生播放）";
    case "mpv": return "mpv（支持原生播放）";
    case "aether": return "AetherEngine（支持原生播放）";
    default: return playbackEngineLabel(engine);
  }
}

/**
 * Auto 的 fallback 链（纯函数，可单测）。HLS / progressive 先试 AVPlayer：
 * 系统自带、零依赖，H.264/HEVC + MP4/HLS 都能硬解；AVPlayer 吃不下的
 * 格式再试 mpv；mpv 也打不开再试 AetherEngine；最后回落 WebView。
 * 注意这里只排“尝试顺序”，真正播不播得了由各引擎在打开时决定，
 * 失败时调用方按链往下试（见 Feed.tsx 的 openNative）。
 */
export function playbackEngineFallbackChain(
  engine: PlaybackEngine,
  format: "hls" | "progressive",
): NativeEngine[] {
  if (engine === "webview") return [];
  if (isNativeEngine(engine)) return [engine];
  // auto：目前 HLS 与 progressive 都先走 AVPlayer；容器/编码信息不在
  // PreparedMedia 里，AVPlayer 打不开时再由调用方往下试。mpv 已真机
  // 验过（v0.0.145），排在 AVPlayer 之后；AetherEngine 是新接的、
  // 没真机验过，排最后——链里越靠后，越是兜底。
  void format;
  return ["avplayer", "mpv", "aether"];
}
