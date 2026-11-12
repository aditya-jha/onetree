import { useMemo, useState } from "react";
import type { ScreenProps } from "../App.tsx";
import { decisions, headsUp, GROUPS, GROUP_ORDER, type Group } from "../lib/derive.ts";
import { plural, shorten } from "../lib/format.ts";
import { Button, Command, CopyButton, H1, RunButton } from "../components/ui.tsx";

const DISMISSED = "onetree-dismissed";
function readDismissed(): Set<string> {
  try {
    return new Set(JSON.parse(sessionStorage.getItem(DISMISSED) ?? "[]") as string[]);
  } catch {
    return new Set();
  }
}

export function Inbox({ snap, home, act, focus }: ScreenProps) {
  const [filter, setFilter] = useState<Group | "all">("all");
  const [dismissed, setDismissed] = useState<Set<string>>(readDismissed);
  const all = useMemo(() => decisions(snap), [snap]);
  const heads = useMemo(() => headsUp(snap), [snap]);
  const visible = all.filter((d) => !dismissed.has(d.id));
  const counts = new Map<Group, number>();
  for (const d of visible) counts.set(d.group, (counts.get(d.group) ?? 0) + 1);
  const shown = filter === "all" ? visible : visible.filter((d) => d.group === filter);

  function dismiss(id: string) {
    const next = new Set(dismissed);
    next.add(id);
    setDismissed(next);
    try {
      sessionStorage.setItem(DISMISSED, JSON.stringify([...next]));
    } catch {
      /* per-tab convenience only */
    }
  }

  return (
    <div className="space-y-5">
      <H1 note="grouped by the reason gc gave · dark buttons run on this machine after a confirmation, light ones copy a command">{`${visible.length} decision${visible.length === 1 ? "" : "s"} gc will not make for you`}</H1>

      <div className="flex flex-wrap items-center gap-2 border-b border-ink pb-4 font-mono text-xs">
        <FilterChip active={filter === "all"} onClick={() => setFilter("all")}>
          {`all ${visible.length}`}
        </FilterChip>
        {GROUP_ORDER.filter((g) => counts.get(g)).map((g) => (
          <FilterChip key={g} active={filter === g} onClick={() => setFilter(g)}>
            {`${GROUPS[g].title.split(":")[0]!.split(",")[0]!.toLowerCase()} ${counts.get(g)}`}
          </FilterChip>
        ))}
        {dismissed.size > 0 ? (
          <button
            type="button"
            className="ml-auto text-muted underline"
            onClick={() => {
              setDismissed(new Set());
              try {
                sessionStorage.removeItem(DISMISSED);
              } catch {
                /* ignore */
              }
            }}
          >
            {`show ${plural(dismissed.size, "kept item")}`}
          </button>
        ) : null}
      </div>

      {shown.length === 0 ? <div className="py-10 text-center text-sm text-muted">Nothing waiting on you. gc handles the rest on its own.</div> : null}

      {GROUP_ORDER.filter((g) => shown.some((d) => d.group === g)).map((g) => (
        <section key={g}>
          <div className="flex flex-wrap items-baseline gap-3 pb-1.5 pt-2">
            <span className="text-sm font-semibold">{GROUPS[g].title}</span>
            <span className="font-mono text-[11px] text-muted">{counts.get(g)}</span>
            <span className="text-xs text-muted">{GROUPS[g].why}</span>
          </div>
          {shown
            .filter((d) => d.group === g)
            .map((d) => (
              <div key={d.id} data-focus={d.id} className={`grid scroll-mt-16 grid-cols-[minmax(0,280px)_1fr_minmax(0,360px)] items-start gap-4 border-t border-hairline py-3 ${focus === d.id ? "bg-selected" : ""}`}>
                <div className="flex min-w-0 flex-col gap-0.5">
                  <span className="font-mono text-[11px] text-muted">{d.repo}</span>
                  <span className="truncate font-mono text-[13px] font-semibold" title={d.path}>
                    {d.slug}
                  </span>
                  <span className="truncate font-mono text-[11px] text-muted" title={d.branch ?? "(detached)"}>
                    {d.branch ?? "(detached)"}
                  </span>
                </div>
                <div className="flex min-w-0 flex-col gap-1 text-[13px]">
                  <span>{d.reason}</span>
                  <span className="text-muted">{d.unblock}</span>
                  {d.actions.find((a) => a.kind === "primary")?.command ? <div className="mt-1 truncate" title={d.actions.find((a) => a.kind === "primary")?.command}><Command>{shorten(d.actions.find((a) => a.kind === "primary")!.command!, home)}</Command></div> : null}
                </div>
                <div className="flex flex-wrap justify-end gap-1.5">
                  {d.actions.map((a) =>
                    a.run && a.command ? (
                      <RunButton key={a.label} label={a.label} command={a.command} kind={a.kind} confirm={a.confirm} onRun={() => act(a.run!, a.command!)} />
                    ) : a.command ? (
                      <CopyButton key={a.label} label={a.label} command={a.command} kind={a.kind} />
                    ) : (
                      <Button key={a.label} kind="quiet" onClick={() => dismiss(d.id)} title="Hide until this tab is closed">
                        {a.label}
                      </Button>
                    ),
                  )}
                </div>
              </div>
            ))}
        </section>
      ))}

      {heads.length > 0 ? (
        <section>
          <div className="flex items-baseline gap-3 pb-1.5 pt-3">
            <span className="text-sm font-semibold">Heads-up</span>
            <span className="text-xs text-muted">not a decision yet, will become one</span>
          </div>
          {heads.map((h) => (
            <div key={h.w.path} data-focus={h.w.path} className={`grid scroll-mt-16 grid-cols-[minmax(0,280px)_1fr] items-start gap-4 border-t border-dashed border-control py-3 ${focus === h.w.path ? "bg-selected" : ""}`}>
              <div className="flex min-w-0 flex-col gap-0.5">
                <span className="font-mono text-[11px] text-muted">{h.w.repo}</span>
                <span className="truncate font-mono text-[13px] font-semibold">{h.w.slug}</span>
                <span className="truncate font-mono text-[11px] text-muted">{h.agents.map((a) => `${a.agent} pid ${a.pid}`).join(", ") || plural(h.w.live, "process", "processes")}</span>
              </div>
              <div className="text-[13px]">{h.note}</div>
            </div>
          ))}
        </section>
      ) : null}
    </div>
  );
}

function FilterChip({ active, onClick, children }: { active: boolean; onClick: () => void; children: string }) {
  return (
    <button type="button" onClick={onClick} className={`rounded-edge border px-2.5 py-1 ${active ? "border-ink bg-ink text-ground" : "border-ink bg-paper hover:bg-selected"}`}>
      {children}
    </button>
  );
}
