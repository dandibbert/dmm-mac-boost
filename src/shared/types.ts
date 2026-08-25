export type Game = {
  id: string;
  name: string;
  url: string;
  note: string;
};

export type GameRuntime = {
  id: string;
  running: boolean;
  hidden: boolean;
};

export type AppStatus = {
  runtimes: GameRuntime[];
  memoryMB: number;
  gameCount: number;
  runningCount: number;
};

export type PagekeepAPI = {
  listGames: () => Promise<Game[]>;
  saveGame: (game: { id?: string; name: string; url: string; note?: string }) => Promise<Game>;
  deleteGame: (id: string) => Promise<void>;
  launch: (id: string) => Promise<void>;
  hide: (id: string) => Promise<void>;
  show: (id: string) => Promise<void>;
  stop: (id: string) => Promise<void>;
  openLogin: () => Promise<void>;
  getStatus: () => Promise<AppStatus>;
  onStatus: (callback: (status: AppStatus) => void) => () => void;
};
