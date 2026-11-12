import { useCallback, useEffect, useMemo, useState } from "react";
import type { Snapshot } from "./lib/types.ts";
import { runAction, type ActionRequest, type ActionResult } from "./lib/actions.ts";
import { agentsAttention, agentsView, decisions } from "./lib/derive.ts";
import { ago, clock, homeOf } from "./lib/format.ts";
import { Button } from "./components/ui.tsx";
import { Fleet } from "./screens/Fleet.tsx";
import { Inbox } from "./screens/Inbox.tsx";
import { Agents } from "./screens/Agents.tsx";
import { Guard } from "./screens/Guard.tsx";
import { Health } from "./screens/Health.tsx";

export const TABS = ["Fleet", "Inbox", "Agents", "Guard", "Health"] as const;
export type Tab = (typeof TABS)[number];

export interface ScreenProps {
  snap: Snapshot;
  now: number;
  home: string | null;
  /** `focus` is a worktree path, a checkout path, or a pid. The hash keeps it so a refresh lands on the same row. */
  go: (tab: Tab, focus?: string) => void;
  focus: string | null;
  /** Ask the server to run one allowlisted action, then reload the snapshot. `command` is what the user was shown. */
  act: (req: ActionRequest, command: string) => Promise<ActionResult>;
}

interface Notice {
  ok: boolean;
  command: string;
  text: string;
}

/** The per-run token `onetree ui` puts in the URL; kept in sessionStorage so a reload without it still works. */
function token(): string | null {
  const t = new URL(location.href).searchParams.get("t");
  try {
    if (t) sessionStorage.setItem("onetree-token", t);
    return t ?? sessionStorage.getItem("onetree-token");
  } catch {
    return t;
  }
}

function locationState(): { tab: Tab; focus: string | null } {
  const hash = location.hash.replace(/^#/, "");
  const i = hash.indexOf("/");
  const name = i === -1 ? hash : hash.slice(0, i);
  if (!(TABS as readonly string[]).includes(name)) return { tab: "Fleet", focus: null };
  return { tab: name as Tab, focus: i === -1 ? null : decodeURIComponent(hash.slice(i + 1)) };
}

function Count({ n }: { n: number }) {
  return <span className="rounded-full bg-ink px-1.5 font-mono text-[11px] leading-4 text-ground">{n}</span>;
}

export default function App() {
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [tab, setTab] = useState<Tab>(() => locationState().tab);
  const [focus, setFocus] = useState<string | null>(() => locationState().focus);
  const [now, setNow] = useState(() => Date.now() / 1000);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [updating, setUpdating] = useState(false);

  /** cached: whatever the server has, at once. now: wait for a new run. full: a new run that also bypasses onetree's caches. */
  const load = useCallback(async (mode: "cached" | "now" | "full" = "cached") => {
    if (mode !== "cached") setBusy(true);
    setErr(null);
    try {
      const t = token();
      const r = await fetch(`/api/snapshot${mode === "cached" ? "" : `?refresh=${mode}`}`, { headers: t ? { authorization: `Bearer ${t}` } : {} });
      if (!r.ok) {
        const body = (await r.json().catch(() => ({}))) as { error?: string };
        throw new Error(r.status === 401 ? "No token. Open the URL that `onetree ui` printed." : `${r.status}: ${body.error ?? r.statusText}`);
      }
      setUpdating(r.headers.get("x-snapshot-refreshing") === "1");
      setSnap((await r.json()) as Snapshot);
      setNow(Date.now() / 1000);
    } catch (e) {
      setErr(String((e as Error).message ?? e));
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    void load();
    const refresh = setInterval(() => void load(), 20_000); // the server answers from its cache at once and refreshes behind it
    const tick = setInterval(() => setNow(Date.now() / 1000), 10_000);
    const onHash = () => {
      const next = locationState();
      setTab(next.tab);
      setFocus(next.focus);
    };
    addEventListener("hashchange", onHash);
    return () => {
      clearInterval(refresh);
      clearInterval(tick);
      removeEventListener("hashchange", onHash);
    };
  }, [load]);

  const go = useCallback((t: Tab, id?: string) => {
    setTab(t);
    setFocus(id ?? null);
    history.replaceState(null, "", id ? `#${t}/${encodeURIComponent(id)}` : `#${t}`);
    scrollTo({ top: 0 });
  }, []);

  useEffect(() => {
    if (!focus || !snap) return;
    const el = document.querySelector(`[data-focus="${CSS.escape(focus)}"]`);
    el?.scrollIntoView({ block: "center" });
  }, [focus, tab, snap]);

  const act = useCallback(
    async (req: ActionRequest, command: string) => {
      const r = await runAction(req, token());
      const text = r.error ?? r.summary ?? (r.ok ? r.stdout.trim() || "done" : r.stderr.trim() || r.stdout.trim() || `exit ${r.code}`);
      const killed = r.killed.length ? ` (kill: ${r.killed.join(", ")})` : "";
      setNotice({ ok: r.ok, command: r.command || command, text: text + killed });
      await load("now");
      return r;
    },
    [load],
  );

  const inbox = useMemo(() => (snap ? decisions(snap).length : 0), [snap]);
  const agentN = useMemo(() => (snap ? agentsAttention(agentsView(snap)) : 0), [snap]);
  const healthN = snap?.doctor?.failed ?? 0;
  const home = useMemo(() => (snap ? homeOf(snap.onetree.bin) : null), [snap]);
  const generated = snap ? Date.parse(snap.generatedAt) / 1000 : null;

  return (
    <div className="min-h-screen">
      <header className="sticky top-0 z-10 flex h-14 items-center gap-6 border-b border-ink bg-ground/95 px-6 backdrop-blur sm:px-8">
        <div className="font-mono text-base font-semibold">onetree</div>
        <nav className="flex h-14 items-stretch gap-5 text-sm">
          {TABS.map((t) => (
            <button key={t} type="button" onClick={() => go(t)} className={`flex items-center gap-1.5 border-b-2 ${tab === t ? "border-ink font-semibold" : "border-transparent text-body hover:text-ink"}`}>
              {t}
              {t === "Inbox" && inbox > 0 ? <Count n={inbox} /> : null}
              {t === "Agents" && agentN > 0 ? <Count n={agentN} /> : null}
              {t === "Health" && healthN > 0 ? <Count n={healthN} /> : null}
            </button>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-3 font-mono text-xs text-muted">
          {snap && generated ? (
            <span title={snap.generatedAt}>
              snapshot {clock(snap.generatedAt)} · {ago(generated, now)}
              {updating ? " · updating" : ""}
            </span>
          ) : null}
          <Button kind="secondary" onClick={() => void load("full")} disabled={busy} title="Run onetree snapshot again, ignoring every cache (slower)">
            {busy ? "Refreshing…" : "Refresh"}
          </Button>
        </div>
      </header>

      <main className="mx-auto max-w-[1280px] px-6 py-6 sm:px-8">
        {err ? (
          <div className="mb-5 rounded-edge border border-critical/40 bg-critical-tint px-4 py-3 text-sm text-critical">
            Could not load the snapshot: {err}
            {snap ? " Showing the previous one." : ""}
          </div>
        ) : null}
        {notice ? (
          <div className={`mb-5 flex items-start gap-3 rounded-edge border px-4 py-3 text-sm ${notice.ok ? "border-positive/40 bg-positive-tint text-positive" : "border-critical/40 bg-critical-tint text-critical"}`}>
            <div className="min-w-0 flex-1">
              <code className="block truncate font-mono text-[11px] opacity-80" title={notice.command}>
                $ {notice.command}
              </code>
              <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap font-sans text-[13px]">{notice.text}</pre>
            </div>
            <Button kind="quiet" onClick={() => setNotice(null)} title="Dismiss">
              ×
            </Button>
          </div>
        ) : null}
        {!snap ? (
          <div className="py-24 text-center text-sm text-muted">{err ? "Nothing to show yet." : "Running onetree snapshot…"}</div>
        ) : tab === "Fleet" ? (
          <Fleet snap={snap} now={now} home={home} go={go} act={act} focus={focus} />
        ) : tab === "Inbox" ? (
          <Inbox snap={snap} now={now} home={home} go={go} act={act} focus={focus} />
        ) : tab === "Agents" ? (
          <Agents snap={snap} now={now} home={home} go={go} act={act} focus={focus} />
        ) : tab === "Guard" ? (
          <Guard snap={snap} now={now} home={home} go={go} act={act} focus={focus} />
        ) : (
          <Health snap={snap} now={now} home={home} go={go} act={act} focus={focus} />
        )}
      </main>
    </div>
  );
}
