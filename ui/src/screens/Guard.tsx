import { useMemo, useState } from "react";
import type { ScreenProps } from "../App.tsx";
import { guardView, repoLabel } from "../lib/derive.ts";
import { clock, day, plural } from "../lib/format.ts";
import { Empty, H1, Pill, Td, Th, Tile } from "../components/ui.tsx";

export function Guard({ snap }: ScreenProps) {
  const v = useMemo(() => guardView(snap), [snap]);
  const [agent, setAgent] = useState("all");
  const [repo, setRepo] = useState("all");
  const [rule, setRule] = useState("all");
  const [onlyRepeated, setOnlyRepeated] = useState(false);
  const [onlyCandidates, setOnlyCandidates] = useState(false);
  const repeatedKeys = new Set(v.repeated.map((r) => r.key));
  const rows = v.events.filter(
    (e) =>
      (agent === "all" || e.agent === agent) &&
      (repo === "all" || e.repo === repo) &&
      (rule === "all" || e.rule === rule) &&
      (!onlyRepeated || repeatedKeys.has(e.session ?? (e.pid ? `pid ${e.pid}` : "unknown"))) &&
      (!onlyCandidates || v.candidates.includes(e)),
  );
  const agents = [...new Set(v.events.map((e) => e.agent))];
  const repos = [...new Set(v.events.map((e) => e.repo))];

  return (
    <div className="space-y-5">
      <H1 note="every refusal the guard made in the last 24 hours, with the rule, the agent and the command">Guard activity</H1>

      {snap.events.length === 0 ? (
        <Empty>
          No events in the last 24 hours. The guard records each block, and gc each removal, in the event log once the installed onetree has this version: <code className="font-mono">onetree update</code>.
        </Empty>
      ) : null}

      <div className="flex flex-wrap gap-4">
        <Tile label="Blocked · 24h" value={v.total} />
        <Tile label="Rules hit" value={`${v.byRule.length} of ${v.rules.length}`} note={v.byRule.map(([r, n]) => `${r} ${n}`).slice(0, 3).join(" · ")} />
        <Tile label="Sessions blocked 3+ times" value={v.repeated.length} note="bouncing off the wall instead of learning the rules" tone={v.repeated.length ? "ink" : "hairline"} />
        <Tile label="False-positive candidates" value={v.candidates.length} note="blocked for mentioning a mirror path; check the command" />
      </div>

      <div className="flex flex-wrap items-center gap-2 border-b border-ink pb-3 font-mono text-xs">
        <span className="text-muted">filter</span>
        <Select value={agent} onChange={setAgent} options={["all", ...agents]} label="agent" />
        <Select value={repo} onChange={setRepo} options={["all", ...repos]} label="repo" show={(o) => (o === "all" ? o : repoLabel(o))} />
        <Select value={rule} onChange={setRule} options={["all", ...v.rules]} label="rule" />
        <Toggle on={onlyRepeated} onChange={setOnlyRepeated}>
          repeated by one session
        </Toggle>
        <Toggle on={onlyCandidates} onChange={setOnlyCandidates}>
          false-positive candidates
        </Toggle>
        <span className="ml-auto text-muted">{plural(rows.length, "event")}</span>
      </div>

      <table className="w-full border-collapse">
        <thead>
          <tr>
            <Th className="w-[120px]">Time</Th>
            <Th className="w-[160px]">Agent · session</Th>
            <Th className="w-[130px]">Repo</Th>
            <Th className="w-[240px]">Rule</Th>
            <Th>Command</Th>
          </tr>
        </thead>
        <tbody>
          {rows.map((e, i) => {
            const key = e.session ?? (e.pid ? `pid ${e.pid}` : "unknown");
            const isCandidate = v.candidates.includes(e);
            return (
              <tr key={`${e.t}-${i}`}>
                <Td mono className="text-muted" title={e.ts}>
                  {day(e.ts)} {clock(e.ts)}
                </Td>
                <Td mono title={e.session ?? undefined}>
                  {e.agent} · {e.session ? e.session.slice(0, 8) : e.pid ? `pid ${e.pid}` : "?"}
                </Td>
                <Td mono className={e.repo ? undefined : "text-muted"}>{repoLabel(e.repo)}</Td>
                <Td>
                  <span className="text-[13px]">{e.rule}</span>
                  {repeatedKeys.has(key) ? <span className="ml-2"><Pill tone="warn">repeated</Pill></span> : null}
                  {isCandidate ? <span className="ml-2"><Pill tone="auto">check</Pill></span> : null}
                </Td>
                <Td mono className="max-w-[420px] truncate" title={e.command || e.file}>
                  {e.tool === "Bash" || e.tool === "bash" || e.tool === "shell" ? e.command : `${e.tool} ${e.file}`}
                </Td>
              </tr>
            );
          })}
          {rows.length === 0 && v.total > 0 ? (
            <tr>
              <Td className="text-muted" colSpan={5}>
                No event matches these filters.
              </Td>
            </tr>
          ) : null}
        </tbody>
      </table>
      <p className="text-xs text-muted">Rules are the guard's own: {v.rules.join(" · ")}.</p>
    </div>
  );
}

function Select({ value, onChange, options, label, show = (o) => o }: { value: string; onChange: (v: string) => void; options: string[]; label: string; show?: (o: string) => string }) {
  return (
    <label className="flex items-center gap-1 rounded-edge border border-ink bg-paper px-2 py-1">
      <span className="text-muted">{label}:</span>
      <select value={value} onChange={(e) => onChange(e.target.value)} className="bg-transparent font-mono text-xs">
        {options.map((o) => (
          <option key={o} value={o}>
            {show(o)}
          </option>
        ))}
      </select>
    </label>
  );
}

function Toggle({ on, onChange, children }: { on: boolean; onChange: (v: boolean) => void; children: string }) {
  return (
    <label className={`flex cursor-pointer items-center gap-1.5 rounded-edge border px-2 py-1 ${on ? "border-ink bg-ink text-ground" : "border-ink bg-paper"}`}>
      <input type="checkbox" checked={on} onChange={(e) => onChange(e.target.checked)} className="sr-only" />
      {on ? "☑" : "☐"} {children}
    </label>
  );
}
