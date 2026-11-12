import type { ScreenProps } from "../App.tsx";
import { baseRemote, fleet } from "../lib/derive.ts";
import { plural, shorten, short } from "../lib/format.ts";
import { Mono, Pill, Td, Th } from "../components/ui.tsx";

function Chip({ children, onClick, solid = false }: { children: string; onClick?: () => void; solid?: boolean }) {
  const cls = `rounded-edge border px-2.5 py-1 font-mono text-xs ${solid ? "border-ink bg-ink text-ground" : "border-ink bg-paper text-ink"} ${onClick ? "hover:bg-selected" : ""}`;
  return onClick ? (
    <button type="button" onClick={onClick} className={cls}>
      {children}
    </button>
  ) : (
    <span className={cls}>{children}</span>
  );
}

export function Fleet({ snap, home, go }: ScreenProps) {
  const f = fleet(snap);
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center gap-2">
        <Chip>{plural(f.counts.repos, "repo")}</Chip>
        <Chip>{`${f.counts.guarded} locked ${f.counts.guarded === 1 ? "mirror" : "mirrors"}`}</Chip>
        <Chip>{plural(f.counts.worktrees, "worktree")}</Chip>
        <Chip solid onClick={() => go("Inbox")}>{`${f.counts.decisions} need a decision`}</Chip>
        <Chip onClick={() => go("Agents")}>{plural(f.counts.sessions, "agent session")}</Chip>
        <span className="ml-auto text-xs text-muted">state = what gc concluded, not raw columns</span>
      </div>

      {f.repos.map(({ repo, rows, mainAgents, mainState }) => (
        <section key={repo.info.repo}>
          <div className="flex flex-wrap items-baseline gap-x-3.5 gap-y-1 border-b border-ink pb-1.5">
            <span className="text-[15px] font-semibold">{repo.info.repo}</span>
            <Pill tone={repo.main.guard ? "decide" : "ok"}>{repo.main.guard ? "locked mirror" : "unguarded"}</Pill>
            <Mono muted>integration {repo.info.integration}</Mono>
            <Mono muted>
              {repo.main.behind === 0 ? `${baseRemote(repo)} ${short(repo.main.head)} · up to date` : repo.main.behind ? `${repo.main.behind} behind ${baseRemote(repo)}` : `${baseRemote(repo)} unknown`}
            </Mono>
            <Mono muted className="ml-auto text-[11px]">
              {shorten(repo.info.worktreeDir, home)}
            </Mono>
          </div>
          <table className="w-full border-collapse">
            <thead>
              <tr>
                <Th className="w-[230px]">Worktree</Th>
                <Th className="w-[270px]">Branch</Th>
                <Th>State</Th>
                <Th className="w-[90px]">PR</Th>
                <Th right className="w-[60px]">
                  Dirty
                </Th>
                <Th right className="w-[80px]">
                  Unpushed
                </Th>
                <Th className="w-[170px]">Live</Th>
                <Th className="w-[70px]"></Th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <Td mono>{repo.main.guard ? "main (mirror)" : "main"}</Td>
                <Td mono className="text-muted">
                  {repo.main.branch ?? "(detached)"}
                </Td>
                <Td>
                  <Pill tone={mainState.tone}>{mainState.label}</Pill>
                </Td>
                <Td mono className="text-muted">
                  —
                </Td>
                <Td mono right>
                  {repo.main.dirty}
                </Td>
                <Td mono right className="text-muted">
                  —
                </Td>
                <Td mono>{live(repo.main.live, mainAgents.map((a) => a.agent))}</Td>
                <Td mono>
                  {mainAgents.length > 1 && !repo.main.guard ? (
                    <button type="button" onClick={() => go("Agents", repo.main.path)} className="text-[11px] underline">
                      agents
                    </button>
                  ) : null}
                </Td>
              </tr>
              {rows.map(({ w, state, agents }) => (
                <tr key={w.path}>
                  <Td mono title={w.path}>
                    {w.slug}
                  </Td>
                  <Td mono className="max-w-[270px] truncate text-muted" title={w.branch ?? "(detached)"}>
                    {w.branch ?? "(detached)"}
                  </Td>
                  <Td>
                    <Pill tone={state.tone} title={w.gc.reason}>
                      {state.label}
                    </Pill>
                  </Td>
                  <Td mono className="text-muted" title={w.pr?.head ?? undefined}>
                    {w.pr?.state === "NONE" || w.pr?.state === "UNKNOWN" ? "—" : w.pr?.state.toLowerCase()}
                  </Td>
                  <Td mono right>
                    {w.dirty}
                  </Td>
                  <Td mono right>
                    {w.unpushed ?? "?"}
                  </Td>
                  <Td mono>{live(w.live, agents.map((a) => a.agent))}</Td>
                  <Td mono>
                    {state.tone === "decide" ? (
                      <button type="button" onClick={() => go("Inbox", w.path)} className="text-[11px] underline">
                        decide
                      </button>
                    ) : null}
                  </Td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ))}
    </div>
  );
}

function live(n: number, agents: string[]): string {
  if (n === 0) return "—";
  const tally = new Map<string, number>();
  for (const a of agents) tally.set(a, (tally.get(a) ?? 0) + 1);
  const named = [...tally.entries()].map(([a, c]) => `${a} ×${c}`);
  const rest = n - agents.length;
  if (named.length === 0) return `${n} proc`;
  return named.join(" · ") + (rest > 0 ? ` (+${rest})` : "");
}
