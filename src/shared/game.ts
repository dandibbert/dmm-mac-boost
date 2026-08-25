import type { Game } from "./types";

export function validateGameInput(input: {
  id?: string;
  name: string;
  url: string;
  note?: string;
}): Omit<Game, "id"> & { id?: string } {
  const name = input.name.trim();
  const url = input.url.trim();
  const note = (input.note ?? "").trim();
  if (!name) throw new Error("请填写游戏名称");
  if (!url) throw new Error("请填写页游地址");
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
      throw new Error("只支持 http/https 地址");
    }
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("只支持")) throw error;
    throw new Error("地址格式不正确");
  }
  return { id: input.id, name, url, note };
}
