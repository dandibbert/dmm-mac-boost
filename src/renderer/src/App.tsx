import { useEffect, useMemo, useState, type ReactNode } from "react";
import { Plus, Shield, Timer, Waves } from "lucide-react";
import type { AppStatus, Game, GameRuntime } from "../../shared/types";
import { Button } from "@/components/ui/button";
import { Dialog } from "@/components/ui/dialog";
import { Input, Label, Textarea } from "@/components/ui/input";
import { api, isDesktop } from "@/lib/bridge";

type FormState = {
  id?: string;
  name: string;
  url: string;
  note: string;
};

const EMPTY_FORM: FormState = { name: "", url: "", note: "" };

function runtimeOf(id: string, runtimes: GameRuntime[]): GameRuntime | undefined {
  return runtimes.find((item) => item.id === id);
}

export default function App() {
  const [games, setGames] = useState<Game[]>([]);
  const [status, setStatus] = useState<AppStatus | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [form, setForm] = useState<FormState | null>(null);
  const [saving, setSaving] = useState(false);

  const refresh = async (): Promise<void> => {
    const [nextGames, nextStatus] = await Promise.all([api.listGames(), api.getStatus()]);
    setGames(nextGames);
    setStatus(nextStatus);
  };

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await refresh();
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : "启动器读取失败");
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    const off = api.onStatus((next) => setStatus(next));
    return () => {
      cancelled = true;
      off();
    };
  }, []);

  const running = status?.runningCount ?? 0;
  const memory = status?.memoryMB ?? 0;
  const empty = !loading && games.length === 0;

  const summary = useMemo(() => {
    if (running === 0) return "现在没有页游在跑。打开一条后，切走窗口也不会掉速。";
    return `${running} 条页游在常速运行。把窗口收起即可腾出桌面，后台仍按 100% 走。`;
  }, [running]);

  const runAction = async (id: string, action: () => Promise<void>): Promise<void> => {
    setBusyId(id);
    setError("");
    try {
      await action();
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "操作失败");
    } finally {
      setBusyId(null);
    }
  };

  const submitForm = async (): Promise<void> => {
    if (!form) return;
    setSaving(true);
    setError("");
    try {
      await api.saveGame(form);
      setForm(null);
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "保存失败");
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="mx-auto min-h-screen max-w-6xl px-4 py-6 sm:px-8 sm:py-10">
      <header className="flex flex-col gap-6 border-b border-line/80 pb-8 lg:flex-row lg:items-end lg:justify-between">
        <div className="max-w-2xl">
          <p className="text-xs tracking-[0.28em] text-gold">PAGEKEEP · DMM 页游</p>
          <h1 className="mt-2 font-sans text-4xl leading-tight text-paper sm:text-5xl">页游保活</h1>
          <p className="mt-3 max-w-xl text-sm leading-7 text-mute sm:text-base">
            Arc 会把后台标签几乎停掉，内存也偏高。这里每个页游是独立窗口：关节流、伪装前台、共享一份
            DMM 登录，切到别的应用也按常速跑。
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="line" onClick={() => void runAction("login", () => api.openLogin())}>
            打开 DMM 登录
          </Button>
          <Button onClick={() => setForm(EMPTY_FORM)}>
            <Plus size={16} />
            添加页游
          </Button>
        </div>
      </header>

      <section className="mt-6 grid gap-3 sm:grid-cols-3">
        <Stat icon={<Timer size={18} />} label="常速后台" value={running ? `${running} 条运行中` : "待命"} />
        <Stat icon={<Waves size={18} />} label="进程内存" value={memory ? `${memory} MB` : "—"} />
        <Stat icon={<Shield size={18} />} label="登录态" value="所有窗口共用" />
      </section>

      <p className="mt-5 text-sm leading-6 text-mute">{summary}</p>
      {!isDesktop ? (
        <p className="mt-2 rounded-2xl border border-gold/25 bg-gold/10 px-4 py-3 text-sm leading-6 text-gold-2">
          这是启动器界面预览。真正关 Chromium
          节流、注入保活脚本、收起窗口到托盘，需要在 macOS 上运行桌面版：
          <code className="mx-1 rounded bg-ink px-1.5 py-0.5 text-paper">npm install && npm run dev</code>
        </p>
      ) : null}

      {error ? (
        <div className="mt-4 rounded-2xl border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
          {error}
        </div>
      ) : null}

      {loading ? (
        <div className="mt-8 grid gap-4 md:grid-cols-2">
          <SkeletonCard />
          <SkeletonCard />
        </div>
      ) : null}

      {empty ? (
        <div className="mt-8 rounded-3xl border border-dashed border-line bg-panel/70 px-6 py-16 text-center">
          <p className="font-sans text-2xl">还没有页游</p>
          <p className="mx-auto mt-3 max-w-md text-sm leading-7 text-mute">
            先打开 DMM 登录，再到游戏库点进具体页游，把地址栏里的网址存下来。之后启动即可后台常速。
          </p>
          <Button className="mt-6" onClick={() => setForm(EMPTY_FORM)}>
            添加第一条
          </Button>
        </div>
      ) : null}

      <div className="mt-8 grid gap-4 md:grid-cols-2">
        {games.map((game) => (
          <GameCard
            key={game.id}
            game={game}
            runtime={runtimeOf(game.id, status?.runtimes ?? [])}
            busy={busyId === game.id}
            onLaunch={() => void runAction(game.id, () => api.launch(game.id))}
            onHide={() => void runAction(game.id, () => api.hide(game.id))}
            onShow={() => void runAction(game.id, () => api.show(game.id))}
            onStop={() => void runAction(game.id, () => api.stop(game.id))}
            onEdit={() => setForm(game)}
            onDelete={() => {
              if (window.confirm(`删除「${game.name}」？正在跑的窗口也会关掉。`)) {
                void runAction(game.id, () => api.deleteGame(game.id));
              }
            }}
          />
        ))}
      </div>

      <section className="mt-10 grid gap-4 border-t border-line/80 pt-8 lg:grid-cols-3">
        <Tip title="为什么 Arc 会停">
          Arc 会主动休眠不用的标签。Chromium 自己也会把后台定时器降到约 1
          次/秒，并暂停 requestAnimationFrame。远征、建造、回合计时都会拖成慢动作。
        </Tip>
        <Tip title="这里怎么保活">
          每个游戏是独立窗口，而不是标签。启动时关闭后台节流，并在主页面和
          iframe 里伪装「始终可见」，游戏就不会自己暂停。
        </Tip>
        <Tip title="怎么少占内存">
          不要用整站浏览器。这里没有扩展、没有多余标签、登录态只存一份。不用看的窗口请点「收起」，不要关——关掉才会卸掉游戏。
        </Tip>
      </section>

      <Dialog
        open={Boolean(form)}
        title={form?.id ? "编辑页游" : "添加页游"}
        description="推荐存具体游戏页，而不是 DMM 首页。舰队收藏一类地址通常带 app_id 或游戏域名。"
        onClose={() => setForm(null)}
      >
        <form
          className="space-y-4"
          onSubmit={(event) => {
            event.preventDefault();
            void submitForm();
          }}
        >
          <div>
            <Label>名称</Label>
            <Input
              value={form?.name ?? ""}
              placeholder="例如 舰队收藏"
              onChange={(event) => setForm((prev) => (prev ? { ...prev, name: event.target.value } : prev))}
            />
          </div>
          <div>
            <Label>页游地址</Label>
            <Input
              value={form?.url ?? ""}
              placeholder="https://www.dmm.com/netgame/social/-/gadgets/=/app_id=..."
              onChange={(event) => setForm((prev) => (prev ? { ...prev, url: event.target.value } : prev))}
            />
          </div>
          <div>
            <Label>备注（可选）</Label>
            <Textarea
              value={form?.note ?? ""}
              placeholder="分辨率、要开的活动页，随你记。"
              onChange={(event) => setForm((prev) => (prev ? { ...prev, note: event.target.value } : prev))}
            />
          </div>
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="ghost" onClick={() => setForm(null)}>
              取消
            </Button>
            <Button type="submit" disabled={saving}>
              {saving ? "保存中…" : "保存"}
            </Button>
          </div>
        </form>
      </Dialog>
    </div>
  );
}

function Stat({ icon, label, value }: { icon: ReactNode; label: string; value: string }) {
  return (
    <div className="rounded-2xl border border-line bg-panel px-4 py-4">
      <div className="flex items-center gap-2 text-gold">
        {icon}
        <span className="text-xs tracking-wider">{label}</span>
      </div>
      <p className="mt-2 font-sans text-2xl text-paper">{value}</p>
    </div>
  );
}

function Tip({ title, children }: { title: string; children: string }) {
  return (
    <article className="rounded-2xl border border-line bg-panel/80 px-4 py-4">
      <h3 className="text-sm text-gold">{title}</h3>
      <p className="mt-2 text-sm leading-7 text-mute">{children}</p>
    </article>
  );
}

function SkeletonCard() {
  return <div className="h-52 animate-pulse rounded-3xl bg-panel" />;
}

function GameCard({
  game,
  runtime,
  busy,
  onLaunch,
  onHide,
  onShow,
  onStop,
  onEdit,
  onDelete,
}: {
  game: Game;
  runtime?: GameRuntime;
  busy: boolean;
  onLaunch: () => void;
  onHide: () => void;
  onShow: () => void;
  onStop: () => void;
  onEdit: () => void;
  onDelete: () => void;
}) {
  const running = Boolean(runtime?.running);
  const hidden = Boolean(runtime?.hidden);
  const state = !running ? "未启动" : hidden ? "后台常速" : "前台运行";

  return (
    <article className="flex flex-col rounded-3xl border border-line bg-panel p-5">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="font-sans text-2xl leading-tight">{game.name}</h2>
          <p className="mt-1 break-all text-xs text-mute">{game.url}</p>
        </div>
        <span
          className={`shrink-0 rounded-full px-2.5 py-1 text-xs ${
            running ? "bg-live/15 text-live" : "bg-line text-mute"
          }`}
        >
          {state}
        </span>
      </div>
      {game.note ? <p className="mt-3 text-sm leading-6 text-mute">{game.note}</p> : null}
      <div className="mt-5 flex flex-wrap gap-2">
        {!running ? (
          <Button size="sm" disabled={busy} onClick={onLaunch}>
            启动
          </Button>
        ) : hidden ? (
          <Button size="sm" disabled={busy} onClick={onShow}>
            唤回窗口
          </Button>
        ) : (
          <Button size="sm" variant="ghost" disabled={busy} onClick={onHide}>
            收起（保持常速）
          </Button>
        )}
        {running ? (
          <Button size="sm" variant="danger" disabled={busy} onClick={onStop}>
            结束
          </Button>
        ) : null}
        <Button size="sm" variant="line" onClick={onEdit}>
          编辑
        </Button>
        <Button size="sm" variant="ghost" onClick={onDelete}>
          删除
        </Button>
      </div>
    </article>
  );
}
