import type { PagekeepAPI } from "../shared/types";

declare global {
  interface Window {
    pagekeep?: PagekeepAPI;
  }
}

export {};
