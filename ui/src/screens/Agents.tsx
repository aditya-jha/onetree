import type { ScreenProps } from "../App.tsx";
import { agentAction, agentsView, isDesktopController } from "../lib/derive.ts";
import { ago, plural, shorten } from "../lib/format.ts";
import { Card, CopyButton, Eyebrow, H1, Pill, RunButton, Td, Th } from "../components/ui.tsx";

export function Agents({ snap, now, home, go, act, focus }: ScreenProps) {
  const v = agentsView(snap);
  const guardable = v.shared.filter((s) => s.kind === "main");
  const desktopShared = v.shared.some((s) => s.agents.some(isDesktopController));
  const desktopMerged = v.inMerged.some((x) => isDesktopController(x.a));
  return (
    <div className="space-y-5">
      <H1 note="shared checkouts and merged worktrees first">{plural(v.sessions.length, "live agent session")}</H1>

      <div className="grid gap-4 md:grid-cols-3">
        <Card tone={v.shared.length ? "ink" : "hairline"}>
          <Eyebrow>Invariant · one session per checkout</Eyebrow>
          <div className="mt-1 text-sm font-semibold">{v.shared.length ? `Broken in ${plural(v.shared.length, "place")}` : "Holding"}</div>
          <div className="mt-1 text-[13px]">
            {v.shared.length
              ? `${v.shared.map((s) => `${s.repo} ${s.kind === "main" ? "main" : s.path.split("/").pop()}: ${plural(s.agents.length, "session")}`).join("; ")}. End the ones you are not using. A dark End session is older than a day; a quiet one may be you. Guarding only affects the next start, and it locks the checkout these sessions are already in.`
              : "No two sessions share an unguarded checkout."}
          </div>
          {desktopShared ? <div className="mt-1 text-[13px]">Close a Codex Desktop thread in the app. Ending its pid would leave helpers in the checkout.</div> : null}
          {guardable.length ? (
            <div className="mt-2 flex flex-wrap gap-1.5">
              {guardable.map((s) => (
                <CopyButton key={s.path} label={`Copy guard · ${s.repo}`} command={`onetree init --guard ${s.repo}`} kind="secondary" />
              ))}
            </div>
          ) : null}
        </Card>
        <Card>
          <Eyebrow>Invariant · no agent writes in a mirror</Eyebrow>
          <div className="mt-1 text-sm font-semibold">Holding</div>
          <div className="mt-1 text-[13px]">
            {v.inMirror.length ? `${plural(v.inMirror.length, "session")} sit in a locked mirror. Reading is allowed there; the guard blocks anything else.` : "No session sits in a locked mirror."}
          </div>
          {v.inMirror.length ? (
            <button type="button" onClick={() => go("Guard")} className="mt-2 font-mono text-[11px] underline">
              guard activity
            </button>
          ) : null}
        </Card>
        <Card tone={v.inMerged.length ? "ink" : "hairline"}>
          <Eyebrow>Sessions sitting in merged worktrees</Eyebrow>
          <div className="mt-1 text-sm font-semibold">{v.inMerged.length ? `${plural(v.inMerged.length, "session")} done and still open` : "None"}</div>
          <div className="mt-1 text-[13px]">
            {v.inMerged.length
              ? `${v.inMerged.map((x) => `${x.worktree?.slug} (${x.a.agent} ${x.a.pid})`).join(", ")}. End session & remove is the same action as Inbox.${desktopMerged ? " Close a Codex Desktop thread in the app; ending its pid would leave helpers behind." : ""}`
              : "Every session sits in unfinished work."}
          </div>
          {v.inMerged[0]?.worktree ? (
            <button type="button" onClick={() => go("Inbox", v.inMerged[0]!.worktree!.path)} className="mt-2 font-mono text-[11px] underline">
              resolve in Inbox
            </button>
          ) : null}
        </Card>
      </div>

      <table className="w-full border-collapse">
        <thead>
          <tr>
            <Th className="w-[120px]">Agent</Th>
            <Th className="w-[70px]">PID</Th>
            <Th className="w-[130px]">Repo</Th>
            <Th className="w-[300px]">Where</Th>
            <Th className="w-[220px]">Branch / PR</Th>
            <Th className="w-[110px]">Since</Th>
            <Th>Status</Th>
          </tr>
        </thead>
        <tbody>
          {v.sessions.map((view) => {
            const { a, status, tone, worktree, main } = view;
            const action = agentAction(view, now);
            const hit = focus != null && (focus === a.path || focus === String(a.pid) || focus === worktree?.path);
            return (
              <tr key={a.pid} data-focus={a.path ?? String(a.pid)} className={`scroll-mt-16 ${hit ? "bg-selected" : ""}`}>
                <Td className="font-medium">{a.agent}</Td>
                <Td mono>{a.pid}</Td>
                <Td mono>{a.repo ?? "—"}</Td>
                <Td mono className="max-w-[300px] truncate" title={a.cwd}>
                  {main ? (main.guard ? "main (locked mirror)" : "main (unguarded)") : shorten(a.path ?? a.cwd, home)}
                </Td>
                <Td mono className="max-w-[220px] truncate text-muted" title={worktree?.branch ?? main?.branch ?? undefined}>
                  {worktree ? (worktree.pr?.state === "MERGED" || worktree.pr?.state === "OPEN" || worktree.pr?.state === "CLOSED" ? `PR ${worktree.pr.state.toLowerCase()} · ${worktree.branch ?? "(detached)"}` : (worktree.branch ?? "(detached)")) : (main?.branch ?? "—")}
                </Td>
                <Td mono className="text-muted" title={a.startedAt}>
                  {ago(a.started, now)}
                </Td>
                <Td>
                  <span className="flex flex-wrap items-center gap-2">
                    <Pill tone={tone} title={a.session ? `session ${a.session}` : "no session id recorded"}>
                      {status}
                    </Pill>
                    {action ? (
                      <RunButton label={action.label} kind={action.kind} command={action.command} confirm={action.confirm} onRun={() => act(action.run, action.command)} />
                    ) : null}
                    {isDesktopController(a) && (view.attention === "shared" || view.attention === "merged") ? <span className="text-[11px] text-muted">close in Codex</span> : null}
                    {worktree && view.attention === "merged" ? (
                      <button type="button" onClick={() => go("Inbox", worktree.path)} className="font-mono text-[11px] underline">
                        Inbox
                      </button>
                    ) : null}
                  </span>
                </Td>
              </tr>
            );
          })}
          {v.sessions.length === 0 ? (
            <tr>
              <Td className="text-muted" colSpan={7}>
                No agent process has its cwd in a registered repo, and the session hook recorded nothing.
              </Td>
            </tr>
          ) : null}
        </tbody>
      </table>
      <p className="text-xs text-muted">
        A session id on hover means the SessionStart hook recorded this process; that is the identity when it exists. Otherwise the process name is used (claude, codex, pi). Codex Desktop threads are listed as their `cua-repl.mjs` controller, one row per thread, so two threads in one checkout stay visible. The page does not offer End session for Desktop controller rows, even when a session id is recorded: close the thread in the Codex app, because killing the controller would leave helpers in the checkout and gc would still keep the worktree. A session outside every registered repo is shown with its real cwd and age, and is not ended from here: it may be a terminal you still want. Unrelated Node is ignored.
      </p>
    </div>
  );
}
