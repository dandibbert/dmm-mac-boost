import { existsSync } from "node:fs";
import { join } from "node:path";
import { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage } from "electron";
import type { AppStatus } from "../shared/types";
import { applyChromiumKeepAliveFlags } from "./keepAlive";
import { deleteGame, getGame, listGames, saveGame } from "./store";
import {
  createLauncherWindow,
  hideGame,
  listRuntimes,
  openGameWindow,
  openLoginWindow,
  prepareSession,
  showGame,
  stopGame,
} from "./windows";

applyChromiumKeepAliveFlags();

const preloadCandidates = [
  join(__dirname, "../preload/index.mjs"),
  join(__dirname, "../preload/index.js"),
];
const preload = preloadCandidates.find((file) => existsSync(file)) ?? preloadCandidates[0];
let launcher: BrowserWindow | null = null;
let tray: Tray | null = null;

function collectStatus(): AppStatus {
  const runtimes = listRuntimes();
  const metrics = app.getAppMetrics();
  const bytes = metrics.reduce((sum, item) => sum + (item.memory?.workingSetSize ?? 0), 0);
  return {
    runtimes,
    memoryMB: Math.round(bytes / 1024),
    gameCount: listGames().length,
    runningCount: runtimes.filter((item) => item.running).length,
  };
}

function broadcastStatus(): void {
  const status = collectStatus();
  for (const win of BrowserWindow.getAllWindows()) {
    win.webContents.send("pagekeep:status", status);
  }
}

function registerIpc(): void {
  ipcMain.handle("pagekeep:listGames", () => listGames());
  ipcMain.handle("pagekeep:saveGame", (_event, payload) => {
    const game = saveGame(payload);
    broadcastStatus();
    return game;
  });
  ipcMain.handle("pagekeep:deleteGame", (_event, id: string) => {
    stopGame(id);
    deleteGame(id);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:launch", (_event, id: string) => {
    const game = getGame(id);
    if (!game) throw new Error("找不到这条页游");
    openGameWindow(game, preload);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:hide", (_event, id: string) => {
    hideGame(id);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:show", (_event, id: string) => {
    showGame(id);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:stop", (_event, id: string) => {
    stopGame(id);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:openLogin", () => {
    openLoginWindow(preload);
    broadcastStatus();
  });
  ipcMain.handle("pagekeep:getStatus", () => collectStatus());
}

function createTray(): void {
  try {
    const image = nativeImage.createEmpty();
    tray = new Tray(image);
    tray.setTitle("保活");
    tray.setToolTip("页游保活：后台窗口仍按常速跑");
  } catch {
    tray = null;
    return;
  }
  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: "打开启动器",
        click: () => {
          launcher?.show();
          launcher?.focus();
        },
      },
      { type: "separator" },
      {
        label: "退出（会停掉所有页游）",
        click: () => {
          app.quit();
        },
      },
    ])
  );
}

app.whenReady().then(() => {
  prepareSession();
  registerIpc();
  createTray();
  launcher = createLauncherWindow(preload);
  launcher.on("close", (event) => {
    if (listRuntimes().some((item) => item.running)) {
      event.preventDefault();
      launcher?.hide();
    }
  });
  setInterval(broadcastStatus, 3000);
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    launcher = createLauncherWindow(preload);
  } else {
    launcher?.show();
  }
});
