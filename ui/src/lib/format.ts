export function ago(t: number, now: number): string {
  const s = Math.max(0, Math.round(now - t));
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m}m ago`;
  const h = Math.round(m / 60);
  if (h < 48) return `${h}h ago`;
  return `${Math.round(h / 24)}d ago`;
}

export function short(sha: string | null | undefined): string {
  return sha ? sha.slice(0, 7) : "—";
}

export function clock(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

export function day(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString([], { month: "short", day: "2-digit" });
}

/** The home directory as `onetree snapshot` sees it, from the installed binary's path. */
export function homeOf(bin: string): string | null {
  const m = /^(.*?)\/\.local\/bin\/onetree$/.exec(bin) ?? /^(\/(?:Users|home)\/[^/]+)\//.exec(bin);
  return m?.[1] ?? null;
}

export function shorten(p: string | null | undefined, home: string | null): string {
  if (!p) return "—";
  return home && p.startsWith(home) ? "~" + p.slice(home.length) : p;
}

/** A branch `onetree auto` or the Claude wrapper invented, which the rules say to rename before the first push. */
export function isPlaceholder(branch: string | null | undefined): boolean {
  return !!branch && /(^|\/)(claude|pi|codex|dsh)-\d{6}-\d{6}$/.test(branch);
}

export function plural(n: number, one: string, many = one + "s"): string {
  return `${n} ${n === 1 ? one : many}`;
}
