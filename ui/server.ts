// The onetree dashboard server: loopback only, no dependencies, run with
//   node --experimental-strip-types server.ts [--port N] [--ttl S] [--interval S] [--onetree PATH] [--fixture FILE] [--token T] [--open]
// GET /api/snapshot answers from the last `onetree snapshot --all` at once and, when that is older than ttl seconds,
// starts a new run behind the answer; a timer keeps it fresh every interval seconds while someone has asked
// recently. ?refresh=now waits for a new run, ?refresh=full for one that also bypasses onetree's own caches.
// POST /api/action runs one of a fixed set of actions (rm, kill, gc, doctor, unlock), every argument checked
// against the last snapshot; it needs the token in the Authorization header and a JSON body, so a page on
// another origin cannot send one. Everything else is the Vite build in ./dist. GET calls take the token as
// `Authorization: Bearer` or ?t=.

import http from "node:http";
import { spawn } from "node:child_process";
import { createReadStream, existsSync } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import type { ActionRequest } from "./src/lib/actions.ts";

export interface Options {
  port?: number;
  host?: string;
  onetreeBin?: string;
  fixture?: string;
  /** seconds a snapshot is served without starting a new run behind it (default 60) */
  ttl?: number;
  /** seconds between background runs while someone has asked in the last ten minutes; 0 disables (default 60) */
  interval?: number;
  open?: boolean;
  dist?: string;
  token?: string;
}

export type Refresh = "cached" | "now" | "full";

export interface Running {
  port: number;
  url: string;
  token: string;
  close: () => Promise<void>;
}

const here = path.dirname(fileURLToPath(import.meta.url));
const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
};

export function runOnetree(bin: string, args: string[]): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, ONETREE_NO_EVENTS: "" } });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d: Buffer) => (stdout += d.toString()));
    child.stderr.on("data", (d: Buffer) => (stderr += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

function send(res: http.ServerResponse, status: number, obj: unknown): void {
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(obj));
}

function readJson(req: http.IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c: Buffer) => {
      data += c.toString();
      if (data.length > 65536) {
        reject(new Error("body too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(data || "null"));
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

type Outcome = { code: number; stdout: string; stderr: string };
interface SnapRows {
  repos: { worktrees: { slug: string; repo: string; path: string; main: string }[] }[];
  agents: { pid: number }[];
}
const NAME = /^[A-Za-z0-9._-]+$/;

/** A one-line reading of an action's output for the page's notice bar. */
export function summarize(type: string, dryRun: boolean, r: Outcome): string | null {
  try {
    const j: unknown = JSON.parse(r.stdout);
    if (type === "gc" && Array.isArray(j)) {
      const list = j as { gc?: { action: string }; park?: { action: string } }[];
      const removed = list.filter((x) => x.gc?.action === "remove" || x.gc?.action === "would-remove").length;
      const kept = list.filter((x) => x.gc?.action === "keep").length;
      const parked = list.filter((x) => x.park && x.park.action !== "none" && x.park.action !== "leave").length;
      return dryRun ? `${removed} would be removed, ${kept} kept, ${parked} would be parked` : `${removed} removed, ${kept} kept, ${parked} parked`;
    }
    if (type === "doctor" && j && typeof j === "object") {
      const d = j as { ok?: number; failed?: number };
      return `${d.ok ?? "?"} ok, ${d.failed ?? "?"} failed`;
    }
  } catch {
    /* not JSON: the raw output is shown instead */
  }
  return null;
}

export async function start(opts: Options = {}): Promise<Running> {
  const host = opts.host ?? "127.0.0.1";
  const token = opts.token ?? randomBytes(16).toString("hex");
  const ttl = (opts.ttl ?? 60) * 1000;
  const dist = path.resolve(opts.dist ?? path.join(here, "dist"));
  const onetreeBin = opts.onetreeBin ?? process.env.ONETREE_BIN ?? "onetree";

  const interval = (opts.interval ?? 60) * 1000;
  const ATTENTION = 10 * 60 * 1000; // keep refreshing in the background this long after the last request

  let cache: { at: number; body: string } | null = null;
  let inflight: Promise<string> | null = null;
  let lastSeen = 0;
  const age = (): number => (cache ? Date.now() - cache.at : Infinity);

  /** One `onetree snapshot` at a time. `full` also bypasses onetree's own caches of PR states, fetches and the doctor report. */
  function run(full: boolean): Promise<string> {
    if (inflight) return inflight;
    inflight = (async () => {
      let body: string;
      if (opts.fixture) body = await readFile(opts.fixture, "utf8");
      else {
        const r = await runOnetree(onetreeBin, ["snapshot", "--all", ...(full ? ["--fresh"] : [])]);
        if (r.code !== 0) throw new Error(`onetree snapshot exited ${r.code}: ${r.stderr.trim() || "no output"}`);
        body = r.stdout;
      }
      JSON.parse(body);
      cache = { at: Date.now(), body };
      return body;
    })().finally(() => {
      inflight = null;
    });
    return inflight;
  }

  /** What the page gets: the last snapshot at once, with a new run started behind it when it is older than ttl. */
  async function snapshot(mode: Refresh): Promise<string> {
    lastSeen = Date.now();
    if (mode !== "cached") {
      if (inflight) await inflight.catch(() => undefined); // let a background run finish, then run the one that was asked for
      return run(mode === "full");
    }
    if (!cache) return run(false);
    if (age() >= ttl && !inflight) void run(false).catch(() => undefined);
    return cache.body;
  }

  const timer =
    interval > 0
      ? setInterval(() => {
          if (cache && Date.now() - lastSeen < ATTENTION && age() >= ttl && !inflight) void run(false).catch(() => undefined);
        }, Math.max(50, interval))
      : null;
  timer?.unref();

  const authorized = (req: http.IncomingMessage, url: URL): boolean => req.headers.authorization === `Bearer ${token}` || url.searchParams.get("t") === token;

  const bad = (error: string) => ({ status: 400, result: { error } });
  async function perform(body: unknown): Promise<{ status: number; result: unknown }> {
    if (opts.fixture) return bad("actions are disabled while serving a fixture");
    const req = (body ?? {}) as Partial<ActionRequest> & Record<string, unknown>;
    const snap = JSON.parse(await snapshot("cached")) as SnapRows;
    const worktrees = snap.repos.flatMap((r) => r.worktrees);
    const known = (pid: unknown): pid is number => Number.isInteger(pid) && snap.agents.some((a) => a.pid === pid);
    let command: string;
    let exec: () => Promise<Outcome>;
    const killed: string[] = [];
    const killAll = (pids: number[]) => {
      for (const p of pids) {
        try {
          process.kill(p, "SIGTERM");
          killed.push(String(p));
        } catch (e) {
          killed.push(`${p}: ${(e as Error).message}`);
        }
      }
    };
    switch (req.type) {
      case "rm": {
        if (typeof req.slug !== "string" || !NAME.test(req.slug) || typeof req.repo !== "string" || !NAME.test(req.repo)) return bad("rm needs a slug and a repo");
        if (!worktrees.some((w) => w.slug === req.slug && w.repo === req.repo)) return bad(`no worktree ${req.slug} in ${req.repo} in the last snapshot`);
        const pids = Array.isArray(req.kill) ? req.kill : [];
        for (const p of pids) if (!known(p)) return bad(`pid ${String(p)} is not a session in the last snapshot`);
        const args = ["rm", req.slug, req.repo, ...(req.force ? ["--force"] : [])];
        command = `${pids.length ? `kill ${pids.join(" ")} && ` : ""}onetree ${args.join(" ")}`;
        exec = async () => {
          if (pids.length) {
            killAll(pids as number[]);
            await new Promise((r) => setTimeout(r, 800));
          }
          return runOnetree(onetreeBin, args);
        };
        break;
      }
      case "kill": {
        const pids = Array.isArray(req.pids) ? req.pids : [];
        if (!pids.length) return bad("kill needs pids");
        for (const p of pids) if (!known(p)) return bad(`pid ${String(p)} is not a session in the last snapshot`);
        command = `kill ${pids.join(" ")}`;
        exec = async () => {
          killAll(pids as number[]);
          const failed = killed.filter((k) => k.includes(":"));
          return { code: failed.length ? 1 : 0, stdout: failed.length ? "" : `sent SIGTERM to ${pids.join(", ")}`, stderr: failed.join("\n") };
        };
        break;
      }
      case "gc": {
        const args = ["gc", "--all", ...(req.dryRun ? ["--dry-run"] : []), "--json"];
        command = `onetree ${args.join(" ")}`;
        exec = () => runOnetree(onetreeBin, args);
        break;
      }
      case "doctor":
        command = "onetree doctor --json";
        exec = () => runOnetree(onetreeBin, ["doctor", "--json"]);
        break;
      case "unlock": {
        const w = worktrees.find((x) => x.path === req.path && x.main === req.main);
        if (!w) return bad("unlock needs a worktree path and its main checkout from the last snapshot");
        command = `git -C ${w.main} worktree unlock ${w.path}`;
        exec = () => runOnetree("git", ["-C", w.main, "worktree", "unlock", w.path]);
        break;
      }
      default:
        return bad(`unknown action ${String(req.type)}`);
    }
    const r = await exec();
    if (cache) cache.at = 0; // stale: the next request gets the old picture at once and a new run behind it; the page asks for `now`
    return { status: 200, result: { ok: r.code === 0, code: r.code, stdout: r.stdout, stderr: r.stderr, command, summary: summarize(String(req.type), !!req.dryRun, r), killed } };
  }

  const server = http.createServer(async (req, res) => {
    let url: URL;
    try {
      url = new URL(req.url ?? "/", `http://${host}`);
    } catch {
      return send(res, 400, { error: "invalid request target" });   // an async handler that throws would end the process
    }
    try {
      if (url.pathname.startsWith("/api/")) {
        if (!authorized(req, url)) return send(res, 401, { error: "missing or wrong token; open the URL onetree ui printed" });
        if (req.method === "POST" && url.pathname === "/api/action") {
          if (req.headers.authorization !== `Bearer ${token}`) return send(res, 401, { error: "actions need the token in the Authorization header" });
          if (!/^application\/json/.test(req.headers["content-type"] ?? "")) return send(res, 415, { error: "actions take a JSON body" });
          let body: unknown;
          try {
            body = await readJson(req);
          } catch {
            return send(res, 400, { error: "invalid JSON" });
          }
          const { status, result } = await perform(body);
          return send(res, status, result);
        }
        if (req.method !== "GET") return send(res, 405, { error: "GET, or POST /api/action" });
        if (url.pathname === "/api/snapshot") {
          const q = url.searchParams.get("refresh") ?? (url.searchParams.get("fresh") === "1" ? "now" : "cached");
          const body = await snapshot(q === "full" ? "full" : q === "now" ? "now" : "cached");
          res.writeHead(200, {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "x-snapshot-age": String(Math.max(0, Math.round((Date.now() - (cache?.at ?? Date.now())) / 1000))),
            "x-snapshot-refreshing": inflight ? "1" : "0",
          });
          return res.end(body);
        }
        if (url.pathname === "/api/health") {
          return send(res, 200, { ok: true, onetree: onetreeBin, fixture: opts.fixture ?? null, ttl: ttl / 1000, interval: interval / 1000, age: cache ? Math.round(age() / 1000) : null, refreshing: !!inflight, node: process.versions.node });
        }
        return send(res, 404, { error: "not found" });
      }
      const rel = path.normalize(decodeURIComponent(url.pathname === "/" ? "/index.html" : url.pathname)).replace(/^(\.\.[/\\])+/, "");
      const full = path.join(dist, rel);
      if (!full.startsWith(dist + path.sep) && full !== dist) {
        res.writeHead(403);
        return res.end();
      }
      const isFile = existsSync(full) && (await stat(full)).isFile();
      const file = isFile ? full : path.join(dist, "index.html");
      if (!existsSync(file)) {
        res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
        return res.end(`onetree ui: no build in ${dist}. Run: cd ${here} && npm ci && npm run build\n`);
      }
      const immutable = isFile && rel.startsWith(`${path.sep}assets${path.sep}`);
      res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream", "cache-control": immutable ? "public, max-age=31536000, immutable" : "no-store" });
      createReadStream(file).pipe(res);
    } catch (e) {
      send(res, 500, { error: String((e as Error).message ?? e) });
    }
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(opts.port ?? 7180, host, () => resolve());
  });
  const port = (server.address() as { port: number }).port;
  const url = `http://${host}:${port}/?t=${token}`;
  if (opts.open) spawn(process.platform === "darwin" ? "open" : "xdg-open", [url], { stdio: "ignore", detached: true }).on("error", () => {}).unref();   // no opener (a server without xdg-open): the URL is printed anyway
  return {
    port,
    url,
    token,
    close: () => {
      if (timer) clearInterval(timer);
      return new Promise((r) => server.close(() => r()));
    },
  };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const get = (flag: string): string | undefined => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const opts: Options = {
    port: get("--port") !== undefined ? Number(get("--port")) : undefined,
    ttl: get("--ttl") !== undefined ? Number(get("--ttl")) : undefined,
    interval: get("--interval") !== undefined ? Number(get("--interval")) : undefined,
    fixture: get("--fixture"),
    onetreeBin: get("--onetree"),
    token: get("--token"),
    open: args.includes("--open"),
  };
  start(opts)
    .then((r) => {
      console.log(`onetree ui: ${r.url}`);
      console.log(`snapshot: ${opts.fixture ? `fixture ${opts.fixture}` : `${opts.onetreeBin ?? process.env.ONETREE_BIN ?? "onetree"} snapshot --all, served for ${opts.ttl ?? 60}s and refreshed behind the page every ${opts.interval ?? 60}s while it is open`}; ctrl-c to stop`);
    })
    .catch((e: Error) => {
      console.error(`onetree ui: ${e.message ?? e}`);
      process.exit(1);
    });
}
