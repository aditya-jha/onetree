// What the page may ask the server to run. The server allows nothing else, checks every
// argument against the last snapshot, and only ever calls onetree, git and kill.

export type ActionRequest =
  | { type: "rm"; slug: string; repo: string; force?: boolean; kill?: number[] }
  | { type: "kill"; pids: number[] }
  | { type: "gc"; dryRun?: boolean }
  | { type: "doctor" }
  | { type: "unlock"; main: string; path: string };

export interface ActionResult {
  ok: boolean;
  code: number;
  stdout: string;
  stderr: string;
  command: string;
  summary: string | null;
  killed: string[];
  error?: string;
}

export async function runAction(req: ActionRequest, token: string | null): Promise<ActionResult> {
  const r = await fetch("/api/action", {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(req),
  });
  const body = (await r.json().catch(() => ({}))) as Partial<ActionResult> & { error?: string };
  if (!r.ok) {
    return { ok: false, code: r.status, stdout: "", stderr: "", command: body.command ?? "", summary: null, killed: [], error: body.error ?? r.statusText };
  }
  return { ok: !!body.ok, code: body.code ?? -1, stdout: body.stdout ?? "", stderr: body.stderr ?? "", command: body.command ?? "", summary: body.summary ?? null, killed: body.killed ?? [] };
}
