import { app } from "electron";

/**
 * DMM 页游几乎都嵌在 iframe 里，切到后台后会同时踩中两层节流：
 * 1. Chromium 降低后台标签的定时器 / rAF
 * 2. 游戏自己监听 Page Visibility / blur 后主动暂停
 *
 * 这段脚本在每个 frame（含 iframe）里尽早注入，让页面一直以为自己在前台。
 */
export const KEEP_ALIVE_SCRIPT = `
(() => {
  if (window.__pagekeepKeepAlive) return;
  window.__pagekeepKeepAlive = true;

  const spoofVisible = (target) => {
    try {
      Object.defineProperty(target, "hidden", { get: () => false, configurable: true });
      Object.defineProperty(target, "visibilityState", { get: () => "visible", configurable: true });
      Object.defineProperty(target, "webkitHidden", { get: () => false, configurable: true });
      Object.defineProperty(target, "webkitVisibilityState", { get: () => "visible", configurable: true });
    } catch {}
  };

  spoofVisible(document);

  const stop = (event) => {
    event.stopImmediatePropagation();
    event.stopPropagation();
  };

  for (const name of ["visibilitychange", "webkitvisibilitychange", "freeze", "resume"]) {
    document.addEventListener(name, stop, true);
  }
  for (const name of ["blur", "pagehide", "freeze"]) {
    window.addEventListener(name, stop, true);
  }

  document.hasFocus = () => true;
})();
`;

export function applyChromiumKeepAliveFlags(): void {
  app.commandLine.appendSwitch("disable-background-timer-throttling");
  app.commandLine.appendSwitch("disable-backgrounding-occluded-windows");
  app.commandLine.appendSwitch("disable-renderer-backgrounding");
  app.commandLine.appendSwitch(
    "disable-features",
    [
      "IntensiveWakeUpThrottling",
      "CalculateNativeWinOcclusion",
      "IntensiveWakeUpThrottlingFromBattery",
    ].join(",")
  );
}
