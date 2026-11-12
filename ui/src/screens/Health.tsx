import { useState } from "react";
import type { ScreenProps } from "../App.tsx";
import { doctorFixes, healthView } from "../lib/derive.ts";
import { ago, clock, day, plural, shorten } from "../lib/format.ts";
import { Card, CopyButton, H2, RunButton, Td, Th } from "../components/ui.tsx";

export function Health({ snap, now, home, act }: ScreenProps) {
  const v = healthView(snap);
  const [open, setOpen] = useState<Set<string>>(() => new Set(["Guarded mains"]));
  const [repo, setRepo] = useState(snap.repos[0]?.info.repo ?? "");
  const info = snap.repos.find((r) => r.info.repo === repo)?.info;
  const doctor = snap.doctor;
  const fixes = doctorFixes(doctor?.checks ?? []);

  function toggle(name: string) {
    const next = new Set(open);
    if (next.has(name)) next.delete(name);
    else next.add(name);
    setOpen(next);
  }

  return (
    <div className="grid gap-8 lg:grid-cols-[560px_1fr]">
      <section className="space-y-0">
        <H2
          note={doctor ? `${doctor.ok} ok · ${doctor.failed} failed · ran with the snapshot` : "doctor did not run"}
          right={<RunButton label="Run doctor" command="onetree doctor --json" kind="secondary" onRun={() => act({ type: "doctor" }, "onetree doctor --json")} />}
        >
          Doctor
        </H2>
        {v.groups.map((g) => (
          <div key={g.name}>
            <button type="button" onClick={() => toggle(g.name)} className="flex h-[38px] w-full items-center gap-3 border-b border-hairline text-left text-[13px] hover:bg-raised">
              <span className={`w-8 font-mono text-xs ${g.ok === g.checks.length ? "" : "text-critical"}`}>{g.ok === g.checks.length ? "ok" : "FAIL"}</span>
              <span className="w-[200px] font-medium">{g.name}</span>
              <span className="font-mono text-xs text-muted">
                {g.ok} of {g.checks.length}
              </span>
              <span className="ml-auto font-mono text-xs text-muted">{open.has(g.name) ? "−" : "+"}</span>
            </button>
            {open.has(g.name)
              ? g.checks.map((c) => (
                  <div key={c.name} className="flex items-center gap-3 border-b border-hairline py-1.5 pl-11 font-mono text-xs">
                    <span className={c.ok ? "text-muted" : "text-critical"}>{c.ok ? "ok" : "FAIL"}</span>
                    <span className={c.ok ? "" : "text-critical"}>{shorten(c.name, home)}</span>
                  </div>
                ))
              : null}
          </div>
        ))}
        {doctor && doctor.failed > 0 ? (
          <div className="mt-3 space-y-2">
            {fixes.map((f) => (
              <div key={f.command} className="flex flex-wrap items-center gap-3 rounded-edge border border-critical/40 bg-critical-tint px-3.5 py-2.5 text-xs text-critical">
                <span className="min-w-0 flex-1">{f.note}</span>
                <CopyButton label={f.label} command={f.command} kind="secondary" />
              </div>
            ))}
            {fixes.length === 0 ? (
              <div className="rounded-edge border border-critical/40 bg-critical-tint px-3.5 py-2.5 text-xs text-critical">{plural(doctor.failed, "check")} failing. Reinstalling does not fix these.</div>
            ) : null}
          </div>
        ) : null}
      </section>

      <div className="space-y-6">
        <Card>
          <H2 note="launchd com.onetree.gc · every 60 min">gc job</H2>
          <div className="mt-3 grid grid-cols-2 gap-3 font-mono text-xs sm:grid-cols-4">
            <div>
              <div className="text-muted">last run</div>
              <div title={v.lastRun?.ts}>{v.lastRun ? `${clock(v.lastRun.ts)} · ${ago(v.lastRun.t, now)}` : "none in 24h"}</div>
            </div>
            <div>
              <div className="text-muted">result</div>
              <div>{v.lastRun ? `kept ${v.lastRun.kept} · removed ${v.lastRun.removed} · parked ${v.lastRun.parked}` : "—"}</div>
            </div>
            <div>
              <div className="text-muted">took</div>
              <div>{v.lastRun ? `${v.lastRun.seconds}s` : "—"}</div>
            </div>
            <div>
              <div className="text-muted">runs in 24h</div>
              <div>{v.runs.length}</div>
            </div>
          </div>
          <div className="mt-3 flex gap-2">
            <RunButton label="Run gc now" command="onetree gc --all --json" kind="primary" onRun={() => act({ type: "gc" }, "onetree gc --all --json")} />
            <RunButton label="Dry run" command="onetree gc --all --dry-run --json" kind="secondary" onRun={() => act({ type: "gc", dryRun: true }, "onetree gc --all --dry-run --json")} />
            <CopyButton label="Dry run" command="onetree gc --all --dry-run" kind="secondary" />
            <CopyButton label="Open log" command="open ~/Library/Logs/onetree.log" kind="quiet" />
          </div>
        </Card>

        <section>
          <H2 note="the audit trail, newest first">Recent removals</H2>
          <table className="w-full border-collapse">
            <tbody>
              {v.removals.map((e, i) => (
                <tr key={`${e.t}-${i}`}>
                  <Td mono className="w-[110px] text-muted" title={e.ts}>
                    {day(e.ts)} {clock(e.ts)}
                  </Td>
                  <Td mono className="max-w-[360px] truncate" title={String(e.path)}>
                    {String(e.repo)}/{String(e.path).split("/").pop()}
                  </Td>
                  <Td mono className="text-muted">
                    {String(e.code)} · by {e.cmd}
                  </Td>
                </tr>
              ))}
              {v.parks.map((e, i) => (
                <tr key={`p-${e.t}-${i}`}>
                  <Td mono className="w-[110px] text-muted" title={e.ts}>
                    {day(e.ts)} {clock(e.ts)}
                  </Td>
                  <Td mono>{String(e.repo)} main</Td>
                  <Td mono className="text-muted">
                    {String(e.action)} · {String(e.reason)}
                  </Td>
                </tr>
              ))}
              {v.removals.length + v.parks.length === 0 ? (
                <tr>
                  <Td className="text-muted" colSpan={3}>
                    Nothing removed or parked in the last 24 hours.
                  </Td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </section>

        <section>
          <H2
            note="effective value and where it came from"
            right={
              <select value={repo} onChange={(e) => setRepo(e.target.value)} className="rounded-edge border border-ink bg-paper px-2 py-1 font-mono text-xs">
                {snap.repos.map((r) => (
                  <option key={r.info.repo} value={r.info.repo}>
                    {r.info.repo}
                  </option>
                ))}
              </select>
            }
          >
            Config
          </H2>
          {info ? (
            <table className="w-full border-collapse">
              <thead>
                <tr>
                  <Th className="w-[130px]">Key</Th>
                  <Th>Value</Th>
                  <Th className="w-[200px]">From</Th>
                </tr>
              </thead>
              <tbody>
                {(
                  [
                    ["guard", String(info.guard)],
                    ["integration", info.integration],
                    ...(info.remotes
                      ? ([
                          ["remote", `${info.remotes.base.name} · ${info.remotes.base.slug ?? "no url"}`, info.remotes.base.source],
                          ["pushRemote", `${info.remotes.push.name} · ${info.remotes.push.slug ?? "no url"}`, info.remotes.push.source],
                          ["ghUser", info.remotes.ghUser.login ?? "gh's active account", info.remotes.ghUser.source],
                        ] as [string, string, string][])
                      : []),
                    ["root", shorten(info.root, home)],
                    ["branchPrefix", info.branchPrefix],
                    ["copy", info.copy.join(" ") || "(none)"],
                    ["keep", info.keep.join(" ") || "(none)"],
                    ["keepSource", shorten(info.keepSource, home)],
                    ...(info.writable ? ([["writable", writableText(info.writable.paths, info.lockIgnored), info.writable.source]] as [string, string, string][]) : []),
                    ...(info.deps ? ([["deps", `${info.deps.manager}, ${info.deps.state}: ${info.deps.detail}`, "node_modules"]] as [string, string, string][]) : []),
                    ["bootstrap", info.bootstrap ?? "auto: lockfile-based"],
                    ["stale", info.stale === null ? "?" : `${info.stale}h`],
                  ] as [string, string, string?][]
                ).map(([k, val, from]) => {
                  const src = from ?? info.sources[k];
                  return (
                    <tr key={k}>
                      <Td mono>{k}</Td>
                      <Td mono className="max-w-[360px] truncate" title={val}>
                        {val}
                      </Td>
                      <Td mono className={src === "default" ? "text-control" : ""}>
                        {sourceLabel(src, info.remotes?.base.name)}
                      </Td>
                    </tr>
                  );
                })}
                {info.remotes?.ignoredFromFile.length ? (
                  <tr>
                    <Td mono>ignored</Td>
                    <Td mono>{info.remotes.ignoredFromFile.join(" ")}</Td>
                    <Td mono className="text-caution">committed .onetree sets per-clone keys</Td>
                  </tr>
                ) : null}
                <tr>
                  <Td mono>committed .onetree</Td>
                  <Td mono>{info.committedFile ? "present" : "none in this repo"}</Td>
                  <Td mono className="text-control">
                    —
                  </Td>
                </tr>
              </tbody>
            </table>
          ) : null}
        </section>
      </div>
    </div>
  );
}

/** What stays writable in a guarded mirror: gitignored paths by default, only the listed ones with lockIgnored (or from an older onetree). */
function writableText(paths: string[], lockIgnored: boolean | undefined): string {
  const listed = paths.join(" ");
  if (lockIgnored === false) return listed ? `gitignored paths, and listed: ${listed}` : "gitignored paths";
  return listed || "(none)";
}

function sourceLabel(s: string | undefined, base = "origin"): string {
  switch (s) {
    case "local":
      return ".git/config [onetree]";
    case "file":
      return "committed .onetree";
    case "global":
      return "~/.config/onetree/config";
    case "remote-head":
      return `${base}/HEAD`;
    case "upstream-convention":
      return "upstream ≠ origin (fork)";
    case "remote.pushDefault":
      return "git remote.pushDefault";
    case "default":
      return "default";
    default:
      return s ?? "?";
  }
}
