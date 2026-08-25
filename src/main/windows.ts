import { BrowserWindow, session, webFrameMain } from "electron";
import { join } from "node:path";
import type { Game, GameRuntime } from "../shared/types";
import { KEEP_ALIVE_SCRIPT } from "./keepAlive";

const PARTITION = "persist:pagekeep";
const gameWindows = new Map<string, BrowserWindow>();

function injectKeepAlive(contents: Electron.WebContents): void {
  const run = async (): Promise<void> => {
    try {
      await contents.executeJavaScript(KEEP_ALIVE_SCRIPT, true);
    } catch {
      // 跨域或尚未就绪时忽略，frame 回调会再试
    }

    for (const frame of contents.mainFrame.framesInSubtree) {
      try {
        await frame.executeJavaScript(KEEP_ALIVE_SCRIPT, true);
      } catch {
        // iframe 未就绪
      }
    }
  };

  void run();
}

function attachKeepAlive(contents: Electron.WebContents): void {
  contents.on("dom-ready", () => injectKeepAlive(contents));
  contents.on("did-finish-load", () => injectKeepAlive(contents));
  contents.on("did-frame-finish-load", (_event, _isMain, processId, routingId) => {
    try {
      const frame = webFrameMain.fromId(processId, routingId);
      void frame?.executeJavaScript(KEEP_ALIVE_SCRIPT, true);
    } catch {
      // frame 已销毁
    }
  });
  contents.on("did-attach-webview", (_event, wc) => {
    attachKeepAlive(wc);
    injectKeepAlive(wc);
  });
}

const CHROME_MAC_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.127 Safari/537.36";

export function getSession() {
  return session.fromPartition(PARTITION);
}

export function prepareSession(): void {
  const ses = getSession();
  ses.setUserAgent(CHROME_MAC_UA);
}

export function listRuntimes(): GameRuntime[] {
  return [...gameWindows.entries()].map(([id, win]) => ({
    id,
    running: !win.isDestroyed(),
    hidden: !win.isDestroyed() && !win.isVisible(),
  }));
}

export function stopGame(id: string): void {
  const win = gameWindows.get(id);
  if (!win || win.isDestroyed()) {
    gameWindows.delete(id);
    return;
  }
  win.destroy();
  gameWindows.delete(id);
}

export function hideGame(id: string): void {
  const win = gameWindows.get(id);
  if (!win || win.isDestroyed()) return;
  win.hide();
}

export function showGame(id: string): void {
  const win = gameWindows.get(id);
  if (!win || win.isDestroyed()) return;
  win.show();
  win.focus();
}

export function openGameWindow(game: Game, preload: string): BrowserWindow {
  const existing = gameWindows.get(game.id);
  if (existing && !existing.isDestroyed()) {
    existing.show();
    existing.focus();
    return existing;
  }

  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 900,
    minHeight: 600,
    title: `${game.name} · 页游保活`,
    backgroundColor: "#161310",
    autoHideMenuBar: true,
    webPreferences: {
      preload,
      partition: PARTITION,
      sandbox: false,
      backgroundThrottling: false,
      nodeIntegration: false,
      contextIsolation: true,
      spellcheck: false,
    },
  });

  win.webContents.setBackgroundThrottling(false);
  attachKeepAlive(win.webContents);
  void win.loadURL(game.url);

  win.on("closed", () => {
    gameWindows.delete(game.id);
  });

  gameWindows.set(game.id, win);
  return win;
}

export function openLoginWindow(preload: string): BrowserWindow {
  return openGameWindow(
    {
      id: "preset-dmm-login",
      name: "DMM 登录",
      url: "https://accounts.dmm.com/service/login/password/=/path=DRVESVwZTkVPEh9cXltUAg__",
      note: "",
    },
    preload
  );
}

export function createLauncherWindow(preload: string): BrowserWindow {
  const win = new BrowserWindow({
    width: 1080,
    height: 760,
    minWidth: 860,
    minHeight: 620,
    title: "页游保活",
    backgroundColor: "#161310",
    autoHideMenuBar: true,
    webPreferences: {
      preload,
      sandbox: false,
      backgroundThrottling: false,
      nodeIntegration: false,
      contextIsolation: true,
    },
  });

  if (process.env.ELECTRON_RENDERER_URL) {
    void win.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    void win.loadFile(join(__dirname, "../renderer/index.html"));
  }
  return win;
}
