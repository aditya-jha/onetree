import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";
import os from "node:os";
import net from "node:net";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { start, summarize } from "./server.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixture = path.join(here, "fixtures", "snapshot.json");
const dist = path.join(here, "dist");

/** A onetree that answers `snapshot` with the fixture, `gc` and `doctor` with canned JSON, and echoes everything else. */
function stubOnetree(): string {
  const dir = mkdtempSync(path.join(os.tmpdir(), "onetree-stub-"));
  const bin = path.join(dir, "onetree");
  writeFileSync(
    bin,
    `#!/bin/sh
case "$1" in
  snapshot) cat "${fixture}" ;;
  gc) echo '[{"gc":{"action":"would-remove"}},{"gc":{"action":"keep"}},{"park":{"action":"none"}}]' ;;
  doctor) echo '{"ok":3,"failed":1,"checks":[]}'; exit 1 ;;
  *) echo "stub $*" ;;
esac
`,
  );
  chmodSync(bin, 0o755);
  return bin;
}

test("the snapshot needs the token, as a header or a query parameter", async () => {
  const s = await start({ port: 0, fixture, dist });
  try {
    const base = `http://127.0.0.1:${s.port}`;
    assert.equal((await fetch(`${base}/api/snapshot`)).status, 401);
    assert.equal((await fetch(`${base}/api/snapshot`, { headers: { authorization: "Bearer nope" } })).status, 401);
    const ok = await fetch(`${base}/api/snapshot`, { headers: { authorization: `Bearer ${s.token}` } });
    assert.equal(ok.status, 200);
    const snap = (await ok.json()) as { schema: number; repos: unknown[]; agents: unknown[]; events: unknown[] };
    assert.equal(snap.schema, 1);
    assert.ok(Array.isArray(snap.repos) && snap.repos.length > 0);
    assert.ok(Array.isArray(snap.agents));
    assert.ok(Array.isArray(snap.events));
    const viaQuery = await fetch(`${base}/api/health?t=${s.token}`);
    assert.equal(((await viaQuery.json()) as { ok: boolean }).ok, true);
    assert.equal((await fetch(`${base}/api/snapshot`, { method: "POST", headers: { authorization: `Bearer ${s.token}` } })).status, 405);
    assert.equal((await fetch(`${base}/api/nothing`, { headers: { authorization: `Bearer ${s.token}` } })).status, 404);
  } finally {
    await s.close();
  }
});

test("a request target that is no URL is a 400, and the server keeps serving", async () => {
  const s = await start({ port: 0, fixture, dist });
  try {
    const head = await new Promise<string>((resolve, reject) => {
      const c = net.connect(s.port, "127.0.0.1", () => c.write("GET //[ HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"));
      let got = "";
      c.on("data", (d) => (got += d)).on("end", () => resolve(got.split("\r\n")[0] ?? "")).on("error", reject);
    });
    assert.deepEqual([head, (await fetch(`http://127.0.0.1:${s.port}/api/snapshot`)).status], ["HTTP/1.1 400 Bad Request", 401]);
  } finally {
    await s.close();
  }
});

test("the page and its assets are served from dist, unknown paths fall back to the page", async () => {
  const s = await start({ port: 0, fixture, dist });
  try {
    const base = `http://127.0.0.1:${s.port}`;
    const page = await fetch(base + "/");
    assert.equal(page.status, 200);
    assert.match(page.headers.get("content-type") ?? "", /text\/html/);
    const html = await page.text();
    assert.match(html, /<div id="root">/);
    const asset = /(\.\/)?assets\/[^"']+\.js/.exec(html)?.[0]?.replace(/^\.\//, "");
    assert.ok(asset, "the page references a built script");
    const js = await fetch(`${base}/${asset}`);
    assert.equal(js.status, 200);
    assert.match(js.headers.get("cache-control") ?? "", /immutable/);
    const spa = await fetch(`${base}/no/such/route`);
    assert.equal(spa.status, 200);
    assert.match(await spa.text(), /<div id="root">/);
    const secret = await fetch(`${base}/..%2Fserver.ts`);
    assert.doesNotMatch(await secret.text(), /export async function start/, "a path that climbs out of dist never serves the source");
  } finally {
    await s.close();
  }
});

test("a failing onetree is a 500 with its message, and the cache serves repeats", async () => {
  const s = await start({ port: 0, onetreeBin: path.join(here, "no-such-onetree"), dist });
  try {
    const r = await fetch(`http://127.0.0.1:${s.port}/api/snapshot`, { headers: { authorization: `Bearer ${s.token}` } });
    assert.equal(r.status, 500);
    assert.match(((await r.json()) as { error: string }).error, /ENOENT|no-such-onetree/);
  } finally {
    await s.close();
  }
  const cached = await start({ port: 0, fixture, dist, ttl: 60 });
  try {
    const h = { authorization: `Bearer ${cached.token}` };
    const a = await fetch(`http://127.0.0.1:${cached.port}/api/snapshot`, { headers: h });
    const b = await fetch(`http://127.0.0.1:${cached.port}/api/snapshot`, { headers: h });
    assert.equal(a.headers.get("x-snapshot-age"), "0");
    assert.ok(Number(b.headers.get("x-snapshot-age")) >= 0);
    assert.equal(await a.text(), await b.text());
  } finally {
    await cached.close();
  }
});

test("actions: header token and JSON only, arguments checked against the last snapshot, run through onetree", async () => {
  const s = await start({ port: 0, onetreeBin: stubOnetree(), dist });
  try {
    const base = `http://127.0.0.1:${s.port}`;
    const h = { authorization: `Bearer ${s.token}`, "content-type": "application/json" };
    const post = (body: unknown, headers: Record<string, string> = h) => fetch(`${base}/api/action`, { method: "POST", headers, body: JSON.stringify(body) });
    assert.equal((await post({ type: "gc" }, { "content-type": "application/json" })).status, 401);
    assert.equal((await fetch(`${base}/api/action?t=${s.token}`, { method: "POST", headers: { "content-type": "application/json" }, body: "{}" })).status, 401, "the query form of the token is for GET only");
    assert.equal((await post({ type: "gc" }, { authorization: h.authorization })).status, 415);
    assert.equal((await fetch(`${base}/api/action`, { method: "POST", headers: h, body: "{nope" })).status, 400);
    assert.equal((await post({ type: "reboot" })).status, 400);
    assert.equal((await post({ type: "rm", slug: "nope", repo: "shop-web" })).status, 400);
    assert.equal((await post({ type: "rm", slug: "../x", repo: "shop-web" })).status, 400);
    assert.equal((await post({ type: "kill", pids: [1] })).status, 400, "only pids the snapshot lists as sessions");
    assert.equal((await post({ type: "rm", slug: "rail-scroll-restore", repo: "shop-web", kill: [1] })).status, 400);
    assert.equal((await post({ type: "unlock", main: "/nope", path: "/nope" })).status, 400);

    await fetch(`${base}/api/snapshot`, { headers: h });
    const rm = await post({ type: "rm", slug: "order-history-api", repo: "shop-agent", force: true });
    assert.equal(rm.status, 200);
    const r = (await rm.json()) as { ok: boolean; command: string; stdout: string; killed: string[] };
    assert.equal(r.ok, true);
    assert.equal(r.command, "onetree rm order-history-api shop-agent --force");
    assert.match(r.stdout, /^stub rm order-history-api shop-agent --force/);
    assert.deepEqual(r.killed, []);
    const after = await fetch(`${base}/api/snapshot`, { headers: h });
    assert.equal(after.headers.get("x-snapshot-refreshing"), "1", "an action marks the snapshot stale, so a new run starts behind the next request");

    const gc = (await (await post({ type: "gc", dryRun: true })).json()) as { ok: boolean; command: string; summary: string };
    assert.equal(gc.ok, true);
    assert.equal(gc.command, "onetree gc --all --dry-run --json");
    assert.equal(gc.summary, "1 would be removed, 1 kept, 0 would be parked");
    const doc = (await (await post({ type: "doctor" })).json()) as { ok: boolean; summary: string; code: number };
    assert.equal(doc.ok, false);
    assert.equal(doc.code, 1);
    assert.equal(doc.summary, "3 ok, 1 failed");
    assert.equal((await fetch(`${base}/api/snapshot`, { method: "PUT", headers: h })).status, 405);
  } finally {
    await s.close();
  }
});

test("actions are refused while serving a fixture", async () => {
  const s = await start({ port: 0, fixture, dist });
  try {
    const r = await fetch(`http://127.0.0.1:${s.port}/api/action`, { method: "POST", headers: { authorization: `Bearer ${s.token}`, "content-type": "application/json" }, body: JSON.stringify({ type: "gc" }) });
    assert.equal(r.status, 400);
    assert.match(((await r.json()) as { error: string }).error, /fixture/);
  } finally {
    await s.close();
  }
});

/** A onetree whose every snapshot differs (run-1, run-2, …) and which logs its arguments. */
function stubCounting(): { bin: string; log: string } {
  const dir = mkdtempSync(path.join(os.tmpdir(), "onetree-count-"));
  const bin = path.join(dir, "onetree");
  const log = path.join(dir, "log");
  writeFileSync(
    bin,
    `#!/bin/sh
echo "$*" >> "${log}"
n=$(cat "${dir}/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "${dir}/n"
sleep 0.05
printf '{"schema":1,"generatedAt":"run-%s","host":"h","onetree":{"bin":"/x/onetree"},"repos":[],"agents":[],"doctor":null,"events":[]}' "$n"
`,
  );
  chmodSync(bin, 0o755);
  return { bin, log };
}
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const gen = async (r: Response) => ((await r.json()) as { generatedAt: string }).generatedAt;

test("a snapshot older than ttl is served at once and refreshed behind the answer", async () => {
  const { bin } = stubCounting();
  const s = await start({ port: 0, onetreeBin: bin, dist, ttl: 0.2, interval: 0 });
  try {
    const h = { authorization: `Bearer ${s.token}` };
    const u = `http://127.0.0.1:${s.port}/api/snapshot`;
    assert.equal(await gen(await fetch(u, { headers: h })), "run-1", "nothing cached: the first call waits for a run");
    await sleep(300);
    const stale = await fetch(u, { headers: h });
    assert.equal(await gen(stale), "run-1", "older than ttl: still answered from the cache");
    assert.equal(stale.headers.get("x-snapshot-refreshing"), "1", "with a run started behind it");
    await sleep(300);
    assert.equal(await gen(await fetch(u, { headers: h })), "run-2");
  } finally {
    await s.close();
  }
});

test("refresh=now waits for a new run; refresh=full also bypasses onetree's own caches", async () => {
  const { bin, log } = stubCounting();
  const s = await start({ port: 0, onetreeBin: bin, dist, ttl: 60, interval: 0 });
  try {
    const h = { authorization: `Bearer ${s.token}` };
    const u = `http://127.0.0.1:${s.port}/api/snapshot`;
    assert.equal(await gen(await fetch(u, { headers: h })), "run-1");
    assert.equal(await gen(await fetch(u, { headers: h })), "run-1", "within ttl: the same answer, no run");
    assert.equal(await gen(await fetch(`${u}?refresh=now`, { headers: h })), "run-2");
    assert.equal(await gen(await fetch(`${u}?refresh=full`, { headers: h })), "run-3");
    assert.equal(await gen(await fetch(`${u}?fresh=1`, { headers: h })), "run-4", "the old spelling still means now");
    assert.deepEqual(readFileSync(log, "utf8").trim().split("\n"), ["snapshot --all", "snapshot --all", "snapshot --all --fresh", "snapshot --all"]);
  } finally {
    await s.close();
  }
});

test("the background timer keeps the snapshot fresh while someone is looking", async () => {
  const { bin } = stubCounting();
  const s = await start({ port: 0, onetreeBin: bin, dist, ttl: 0.05, interval: 0.1 });
  try {
    const h = { authorization: `Bearer ${s.token}` };
    const u = `http://127.0.0.1:${s.port}/api/snapshot`;
    assert.equal(await gen(await fetch(u, { headers: h })), "run-1");
    await sleep(450);
    assert.notEqual(await gen(await fetch(u, { headers: h })), "run-1", "the timer ran at least once in the meantime");
    const health = (await (await fetch(`http://127.0.0.1:${s.port}/api/health`, { headers: h })).json()) as { interval: number; age: number | null; refreshing: boolean };
    assert.equal(health.interval, 0.1);
    assert.equal(typeof health.age, "number");
  } finally {
    await s.close();
  }
});

test("summarize reads gc and doctor output, and gives up on anything else", () => {
  assert.equal(summarize("gc", false, { code: 0, stdout: '[{"gc":{"action":"remove"}},{"park":{"action":"parked"}}]', stderr: "" }), "1 removed, 0 kept, 1 parked");
  assert.equal(summarize("doctor", false, { code: 0, stdout: '{"ok":37,"failed":0}', stderr: "" }), "37 ok, 0 failed");
  assert.equal(summarize("rm", false, { code: 0, stdout: "removed /x (feature/x, pr=MERGED)", stderr: "" }), null);
});

test("no browser opener on PATH (Linux without xdg-open): the server keeps serving", async () => {
  const path0 = process.env.PATH;
  process.env.PATH = mkdtempSync(path.join(os.tmpdir(), "onetree-nopath-"));   // spawn finds no open / xdg-open: ENOENT
  const s = await start({ port: 0, fixture, dist, open: true });
  process.env.PATH = path0;
  try {
    await new Promise((r) => setTimeout(r, 200));   // the spawn error arrives after start returns
    assert.equal((await fetch(`http://127.0.0.1:${s.port}/api/snapshot?t=${s.token}`)).status, 200);
  } finally {
    await s.close();
  }
});
