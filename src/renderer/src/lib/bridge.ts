import { validateGameInput } from "../../../shared/game";
import type { AppStatus, Game, PagekeepAPI } from "../../../shared/types";

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

function readGames(): Game[] {
  try {
    const raw = localStorage.getItem("pagekeep.games");
    if (!raw) return PRESETS.map((game) => ({ ...game }));
    const parsed = JSON.parse(raw) as Game[];
    return parsed.length ? parsed : PRESETS.map((game) => ({ ...game }));
  } catch {
    return PRESETS.map((game) => ({ ...game }));
  }
}

function writeGames(games: Game[]): void {
  localStorage.setItem("pagekeep.games", JSON.stringify(games));
}

function createBrowserMock(): PagekeepAPI {
  let games = readGames();
  let runtimes: AppStatus["runtimes"] = [];
  const listeners = new Set<(status: AppStatus) => void>();

  const persist = (next: Game[]): void => {
    games = next;
    writeGames(next);
  };

  const status = (): AppStatus => ({
    runtimes,
    memoryMB: 180 + runtimes.filter((item) => item.running).length * 240,
    gameCount: games.length,
    runningCount: runtimes.filter((item) => item.running).length,
  });

  const emit = (): void => {
    const next = status();
    listeners.forEach((listener) => listener(next));
  };

  return {
    async listGames() {
      return games.map((game) => ({ ...game }));
    },
    async saveGame(input) {
      const parsed = validateGameInput(input);
      if (parsed.id) {
        const index = games.findIndex((game) => game.id === parsed.id);
        if (index === -1) throw new Error("找不到这条页游");
        const next = games.map((game, i) =>
          i === index
            ? { ...game, name: parsed.name, url: parsed.url, note: parsed.note }
            : game
        );
        persist(next);
        emit();
        return { ...next[index] };
      }
      const game: Game = {
        id: crypto.randomUUID(),
        name: parsed.name,
        url: parsed.url,
        note: parsed.note,
      };
      persist([...games, game]);
      emit();
      return { ...game };
    },
    async deleteGame(id) {
      persist(games.filter((game) => game.id !== id));
      runtimes = runtimes.filter((item) => item.id !== id);
      emit();
    },
    async launch(id) {
      const existing = runtimes.find((item) => item.id === id);
      if (existing) {
        existing.running = true;
        existing.hidden = false;
      } else {
        runtimes = [...runtimes, { id, running: true, hidden: false }];
      }
      emit();
    },
    async hide(id) {
      runtimes = runtimes.map((item) => (item.id === id ? { ...item, hidden: true } : item));
      emit();
    },
    async show(id) {
      runtimes = runtimes.map((item) => (item.id === id ? { ...item, hidden: false } : item));
      emit();
    },
    async stop(id) {
      runtimes = runtimes.filter((item) => item.id !== id);
      emit();
    },
    async openLogin() {
      await this.launch("preset-dmm-login");
    },
    async getStatus() {
      return status();
    },
    onStatus(callback) {
      listeners.add(callback);
      return () => listeners.delete(callback);
    },
  };
}

export const isDesktop = Boolean(window.pagekeep);
export const api: PagekeepAPI = window.pagekeep ?? createBrowserMock();
