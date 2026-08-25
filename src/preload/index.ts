import { contextBridge, ipcRenderer } from "electron";
import type { AppStatus, PagekeepAPI } from "../shared/types";

const api: PagekeepAPI = {
  listGames: () => ipcRenderer.invoke("pagekeep:listGames"),
  saveGame: (game) => ipcRenderer.invoke("pagekeep:saveGame", game),
  deleteGame: (id) => ipcRenderer.invoke("pagekeep:deleteGame", id),
  launch: (id) => ipcRenderer.invoke("pagekeep:launch", id),
  hide: (id) => ipcRenderer.invoke("pagekeep:hide", id),
  show: (id) => ipcRenderer.invoke("pagekeep:show", id),
  stop: (id) => ipcRenderer.invoke("pagekeep:stop", id),
  openLogin: () => ipcRenderer.invoke("pagekeep:openLogin"),
  getStatus: () => ipcRenderer.invoke("pagekeep:getStatus"),
  onStatus: (callback) => {
    const listener = (_event: unknown, status: AppStatus) => callback(status);
    ipcRenderer.on("pagekeep:status", listener);
    return () => {
      ipcRenderer.removeListener("pagekeep:status", listener);
    };
  },
};

contextBridge.exposeInMainWorld("pagekeep", api);
