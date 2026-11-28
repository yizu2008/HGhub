import { createContext, useCallback, useContext, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { platform } from "./environment";
import type { PlaybackEngine } from "./plugins/playbackEngine";
import { DEFAULT_PLAYBACK_ENGINE, isPlaybackEngine } from "./plugins/playbackEngine";
/** 画面设置（更多播放选项 → 画面设置）：适应 = 原来的自动逻辑（横屏/全屏
 *  完整显示，竖屏看横屏视频默认完整显示，竖屏视频竖屏看铺满）；拉伸 = 拉满
 *  （object-fit: fill，画面变形）；铺满 = 裁切铺满（cover）；16:9 / 4:3 =
 *  按比例裁切显示（cover + 画面框定死比例）。 */
export type PictureMode = "fit" | "stretch" | "fill" | "16:9" | "4:3";
export function isPictureMode(v: string): v is PictureMode { return ["fit", "stretch", "fill", "16:9", "4:3"].includes(v); }
import type { SourceStart } from "./plugins/sourceMatching";
export type Tab = "home" | "category" | "search" | "webhome" | "profile";
export type Theme = "dark" | "light";
export type PageInput = { kind: "plugins"; focusId?: string } | { kind: "settings" } | { kind: "media"; pluginId: string; mediaId: string; start?: SourceStart } | { kind: "section"; pluginId: string; sectionId: string; title?: string } | { kind: "live"; pluginId: string } | { kind: "articles"; pluginId: string } | { kind: "article"; pluginId: string; articleId: string } | { kind: "feed"; pluginId: string } | { kind: "recommendations"; pluginId: string };
export type Page = PageInput & { key: string };
function read<T>(key: string, fallback: T): T { try { return JSON.parse(localStorage.getItem(key) || "null") ?? fallback; } catch { return fallback; } }
function useApplication() {
  const [theme, setTheme] = useState<Theme>(() => read<string>("hpp.theme", "dark") === "light" ? "light" : "dark");
  const [glass, setGlass] = useState(() => read<boolean>("hpp.glass", false) === true);
  const [tab, setTabRaw] = useState<Tab>("home"), [stack, setStack] = useState<Page[]>([]);
  const [muteOnStartup, setMuteOnStartup] = useState(() => read<boolean>("hpp.startMuted", true) !== false);
  const [volume, setVolume] = useState(() => { const v = read("hpp.volume", 0.7); return typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0.7; });
  const [watching, setWatching] = useState(false);
  const [muted, setMuted] = useState(muteOnStartup);
  const [theater, setTheater] = useState(false), [fs, setFs] = useState(false), [clean, setClean] = useState(false);
  const [playbackEngine, setPlaybackEngine] = useState<PlaybackEngine>(() => { const v = read<string>("hpp.playbackEngine", DEFAULT_PLAYBACK_ENGINE); return isPlaybackEngine(v) ? v : DEFAULT_PLAYBACK_ENGINE; });
  /** mpv 硬件加速（v0.0.146）：开 = VideoToolbox 硬解（videotoolbox-copy），
   * 关 = 软解（hwdec=no）。只影响 mpv 原生播放，下次原生播放生效。 */
  const [mpvHardwareAcceleration, setMpvHardwareAcceleration] = useState(() => read<boolean>("hpp.mpvHardwareAcceleration", true) !== false);
  const [pictureMode, setPictureMode] = useState<PictureMode>(() => { const v = read<string>("hpp.pictureMode", "fit"); return isPictureMode(v) ? v : "fit"; });
  const [strictSecurity, setStrict] = useState(true), [strictSecurityReady, setSecurityReady] = useState(false), [securityPending, setPending] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    document.documentElement.classList.toggle("theme-light", theme === "light"); document.documentElement.style.colorScheme = theme;
    document.documentElement.classList.toggle("hg-glass", glass);
    try { localStorage.setItem("hpp.theme", JSON.stringify(theme)); localStorage.setItem("hpp.glass", JSON.stringify(glass)); localStorage.setItem("hpp.startMuted", JSON.stringify(muteOnStartup)); localStorage.setItem("hpp.volume", JSON.stringify(volume)); localStorage.setItem("hpp.playbackEngine", JSON.stringify(playbackEngine)); localStorage.setItem("hpp.mpvHardwareAcceleration", JSON.stringify(mpvHardwareAcceleration)); localStorage.setItem("hpp.pictureMode", JSON.stringify(pictureMode)); } catch { setError("无法保存应用偏好"); }
  }, [theme, glass, muteOnStartup, volume, playbackEngine, mpvHardwareAcceleration, pictureMode]);
  useEffect(() => { void invoke<{strict_security:boolean}>("app_boot").then(v => { setStrict(v.strict_security); setSecurityReady(true); }).catch(() => setError("无法读取网络设置")); }, []);
  const setStrictSecurity = useCallback(async (strict: boolean) => { setPending(true); try { setStrict(await invoke<boolean>("security_set", { strict })); } finally { setPending(false); } }, []);
  const setTab = useCallback((tab: Tab) => { setTabRaw(tab); setStack([]); }, []);
  const push = useCallback((p: PageInput) => setStack(old => [...old, { ...p, key: crypto.randomUUID() }]), []);
  const replace = useCallback((p: PageInput) => setStack(old => [...old.slice(0, -1), { ...p, key: crypto.randomUUID() }]), []);
  const pop = useCallback(() => setStack(old => old.slice(0, -1)), []);
  return { watching, setWatching, platform, theme, setTheme, glass, setGlass, tab, setTab, stack, push, replace, pop, muteOnStartup, setMuteOnStartup, volume, setVolume, muted, setMuted, theater, setTheater, fs, setFs, clean, setClean, playbackEngine, setPlaybackEngine, mpvHardwareAcceleration, setMpvHardwareAcceleration, pictureMode, setPictureMode, strictSecurity, strictSecurityReady, securityPending, setStrictSecurity, error };
}
const Context = createContext<ReturnType<typeof useApplication>>(null!);
export const useStore = () => useContext(Context);
export function AppProvider({children}: {children: React.ReactNode}) { const value = useApplication(); return <Context.Provider value={value}>{children}</Context.Provider>; }
