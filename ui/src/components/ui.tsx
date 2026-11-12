import { useState, type ReactNode } from "react";
import type { Tone } from "../lib/derive.ts";

const PILL: Record<Tone | "critical", string> = {
  ok: "border border-hairline text-body",
  auto: "border border-dashed border-control text-muted",
  decide: "border border-ink bg-ink text-ground",
  warn: "border border-caution/40 bg-caution-tint text-caution",
  muted: "border border-hairline text-muted",
  critical: "border border-critical/40 bg-critical-tint text-critical",
};

export function Pill({ tone, children, title }: { tone: Tone | "critical"; children: ReactNode; title?: string }) {
  return (
    <span title={title} className={`inline-block whitespace-nowrap rounded-edge px-2 py-0.5 font-mono text-[11px] leading-4 ${PILL[tone]}`}>
      {children}
    </span>
  );
}

const BTN: Record<"primary" | "secondary" | "quiet", string> = {
  primary: "border-ink bg-ink text-ground hover:bg-body",
  secondary: "border-ink bg-paper text-ink hover:bg-selected",
  quiet: "border-hairline bg-paper text-muted hover:text-ink hover:bg-selected",
};

export function Button({ kind = "secondary", onClick, children, title, disabled }: { kind?: keyof typeof BTN; onClick?: () => void; children: ReactNode; title?: string; disabled?: boolean }) {
  return (
    <button type="button" title={title} disabled={disabled} onClick={onClick} className={`rounded-edge border px-2.5 py-1.5 text-xs leading-4 whitespace-nowrap disabled:opacity-50 ${BTN[kind]}`}>
      {children}
    </button>
  );
}

async function copy(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

/** A button that asks the server to run one allowlisted action, after a confirmation when the action is destructive. */
export function RunButton({ label, kind = "primary", command, confirm, onRun }: { label: string; kind?: keyof typeof BTN; command: string; confirm?: string; onRun: () => Promise<unknown> }) {
  const [busy, setBusy] = useState(false);
  return (
    <Button
      kind={kind}
      disabled={busy}
      title={`Runs on this machine:\n${command}`}
      onClick={async () => {
        if (confirm && !window.confirm(`${confirm}\n\n$ ${command}`)) return;
        setBusy(true);
        try {
          await onRun();
        } finally {
          setBusy(false);
        }
      }}
    >
      {busy ? "Running…" : label}
    </Button>
  );
}

/** A button that puts a shell command on the clipboard, for the things the page cannot or should not run itself. */
export function CopyButton({ label, command, kind = "secondary" }: { label: string; command: string; kind?: keyof typeof BTN }) {
  const [state, setState] = useState<"idle" | "copied" | "failed">("idle");
  return (
    <Button
      kind={kind}
      title={`Copy to clipboard:\n${command}`}
      onClick={async () => {
        setState((await copy(command)) ? "copied" : "failed");
        setTimeout(() => setState("idle"), 1500);
      }}
    >
      {state === "copied" ? "Copied" : state === "failed" ? "Select below" : label}
    </Button>
  );
}

export function Command({ children }: { children: string }) {
  return (
    <code className="block cursor-text select-all font-mono text-[11px] leading-4 text-muted" title="the command to run">
      $ {children}
    </code>
  );
}

export function Card({ children, tone = "hairline", className = "" }: { children: ReactNode; tone?: "hairline" | "ink" | "dashed"; className?: string }) {
  const border = tone === "ink" ? "border-ink" : tone === "dashed" ? "border-dashed border-control" : "border-hairline";
  return <div className={`rounded-edge border bg-paper px-4 py-3.5 ${border} ${className}`}>{children}</div>;
}

export function Eyebrow({ children }: { children: ReactNode }) {
  return <div className="font-mono text-[11px] uppercase tracking-[0.06em] text-muted">{children}</div>;
}

export function H1({ children, note }: { children: ReactNode; note?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
      <h1 className="text-xl font-semibold tracking-tight">{children}</h1>
      {note ? <span className="text-sm text-muted">{note}</span> : null}
    </div>
  );
}

export function H2({ children, note, right }: { children: ReactNode; note?: ReactNode; right?: ReactNode }) {
  return (
    <div className="flex items-baseline gap-3 border-b border-ink pb-2">
      <h2 className="text-base font-semibold">{children}</h2>
      {note ? <span className="text-xs text-muted">{note}</span> : null}
      {right ? <span className="ml-auto">{right}</span> : null}
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="rounded-edge border border-dashed border-control px-4 py-6 text-center text-sm text-muted">{children}</div>;
}

export function Tile({ label, value, note, tone = "hairline" }: { label: string; value: ReactNode; note?: ReactNode; tone?: "hairline" | "ink" }) {
  return (
    <Card tone={tone} className="min-w-44">
      <Eyebrow>{label}</Eyebrow>
      <div className="mt-1 font-mono text-2xl font-semibold leading-8">{value}</div>
      {note ? <div className="mt-0.5 text-xs text-muted">{note}</div> : null}
    </Card>
  );
}

export function Mono({ children, muted = false, className = "" }: { children: ReactNode; muted?: boolean; className?: string }) {
  return <span className={`font-mono text-xs ${muted ? "text-muted" : ""} ${className}`}>{children}</span>;
}

export function Th({ children, right = false, className = "" }: { children?: ReactNode; right?: boolean; className?: string }) {
  return <th className={`pb-1.5 pr-3 text-left font-mono text-[11px] font-normal uppercase tracking-[0.06em] text-muted ${right ? "text-right" : ""} ${className}`}>{children}</th>;
}

export function Td({ children, right = false, className = "", mono = false, title, colSpan }: { children?: ReactNode; right?: boolean; className?: string; mono?: boolean; title?: string; colSpan?: number }) {
  return (
    <td title={title} colSpan={colSpan} className={`border-t border-hairline py-2 pr-3 align-middle text-[13px] ${right ? "text-right" : ""} ${mono ? "font-mono text-xs" : ""} ${className}`}>
      {children}
    </td>
  );
}
