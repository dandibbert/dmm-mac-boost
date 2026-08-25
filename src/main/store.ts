import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { app } from "electron";
import { validateGameInput } from "../shared/game";
import type { Game } from "../shared/types";

const PRESETS: Game[] = [
  {
    id: "preset-dmm-login",
    name: "DMM 登录",
    url: "https://accounts.dmm.com/service/login/password/=/path=DRVESVwZTkVPEh9cXltUAg__",
    note: "先在这里登一次，后面的页游共用同一份登录态。",
  },
  {
    id: "preset-dmm-library",
    name: "DMM GAMES 游戏库",
    url: "https://games.dmm.com/my-games/",
    note: "从游戏库点进具体页游，再把地址栏 URL 存成一条。",
  },
];

type StoreFile = {
  games: Game[];
};

function storePath(): string {
  return join(app.getPath("userData"), "pagekeep.json");
}

function clonePresets(): Game[] {
  return PRESETS.map((game) => ({ ...game }));
}

function readStore(): StoreFile {
  const file = storePath();
  if (!existsSync(file)) {
    return { games: clonePresets() };
  }
  try {
    const parsed = JSON.parse(readFileSync(file, "utf8")) as StoreFile;
    if (!Array.isArray(parsed.games) || parsed.games.length === 0) {
      return { games: clonePresets() };
    }
    return parsed;
  } catch {
    return { games: clonePresets() };
  }
}

function writeStore(data: StoreFile): void {
  const file = storePath();
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(data, null, 2), "utf8");
}

export function listGames(): Game[] {
  return readStore().games;
}

export function saveGame(input: { id?: string; name: string; url: string; note?: string }): Game {
  const store = readStore();
  const parsed = validateGameInput(input);

  if (parsed.id) {
    const index = store.games.findIndex((game) => game.id === parsed.id);
    if (index === -1) throw new Error("找不到这条页游");
    const next: Game = {
      ...store.games[index],
      name: parsed.name,
      url: parsed.url,
      note: parsed.note,
    };
    store.games[index] = next;
    writeStore(store);
    return next;
  }

  const game: Game = {
    id: randomUUID(),
    name: parsed.name,
    url: parsed.url,
    note: parsed.note,
  };
  store.games.push(game);
  writeStore(store);
  return game;
}

export function deleteGame(id: string): void {
  const store = readStore();
  store.games = store.games.filter((game) => game.id !== id);
  writeStore(store);
}

export function getGame(id: string): Game | undefined {
  return readStore().games.find((game) => game.id === id);
}
