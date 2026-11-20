import type { TerminalSpec } from "../model/terminal";

/**
 * What the terminal host keeps beside a session so a relaunched app can rebuild its tab: the repository it belongs
 * to and how it was started (to start it again once it ends).
 */
export type TerminalMeta = {
  app: "gitrochi";
  repository: string;
  spec: Pick<TerminalSpec, "directory" | "program" | "args" | "env" | "title" | "cwd">;
};

export function terminalMeta(repository: string, spec: TerminalSpec): TerminalMeta {
  const { directory, program, args, env, title, cwd } = spec;
  return { app: "gitrochi", repository, spec: { directory, program, args, env, title, cwd } };
}

const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every((x) => typeof x === "string");
const optional = (v: unknown, ok: (v: unknown) => boolean) => v === undefined || v === null || ok(v);

/** The meta a session came back with, when it is one of ours and well formed */
export function readTerminalMeta(value: unknown): TerminalMeta | null {
  if (!value || typeof value !== "object") return null;
  const m = value as Record<string, unknown>;
  const spec = m.spec as Record<string, unknown> | undefined;
  if (m.app !== "gitrochi" || typeof m.repository !== "string" || !spec || typeof spec.directory !== "string") return null;
  const env = spec.env;
  const valid =
    optional(spec.program, (v) => typeof v === "string") &&
    optional(spec.args, strings) &&
    optional(spec.title, (v) => typeof v === "string") &&
    optional(spec.cwd, (v) => typeof v === "string") &&
    optional(env, (v) => typeof v === "object" && Object.values(v as object).every((x) => typeof x === "string"));
  if (!valid) return null;
  const pick = <T>(v: unknown) => (v === null || v === undefined ? undefined : (v as T));
  return {
    app: "gitrochi",
    repository: m.repository,
    spec: {
      directory: spec.directory,
      program: pick<string>(spec.program),
      args: pick<string[]>(spec.args),
      env: pick<Record<string, string>>(env),
      title: pick<string>(spec.title),
      cwd: pick<string>(spec.cwd),
    },
  };
}

/** The host's sessions that belong in this repository's panel and are not in it yet, oldest first */
export function sessionsToRestore<S extends { id: string; meta: unknown }>(
  sessions: S[],
  repository: string,
  shown: ReadonlySet<string>,
  same: (a: string, b: string) => boolean,
): { session: S; meta: TerminalMeta }[] {
  return sessions.flatMap((session) => {
    const meta = readTerminalMeta(session.meta);
    return meta && !shown.has(session.id) && same(meta.repository, repository) ? [{ session, meta }] : [];
  });
}
