export interface SelfTestCheck {
  name: string;
  ok: boolean;
  detail?: string;
}

type ReportFile = "selftest-progress.json" | "selftest-result.json";
type WriteReport = (file: ReportFile, content: string) => Promise<unknown>;

/** Persist progress independently of completion so a stalled check remains diagnosable. */
export class SelfTestRecorder {
  readonly errors: string[] = [];
  private current = "Environment";
  private checks: SelfTestCheck[] = [];
  private writes = Promise.resolve();

  constructor(private readonly write: WriteReport, private readonly os: string) {}

  private save(file: ReportFile, complete: boolean) {
    const checks = [...this.checks, ...this.errors.map((detail) => ({ name: "Uncaught application error", ok: false, detail }))];
    const content = JSON.stringify({ ok: complete && checks.length > 0 && checks.every((check) => check.ok), complete, stage: this.current, os: this.os, windows: this.os === "windows", checks, errors: [...this.errors], updatedAt: new Date().toISOString() }, null, 2);
    const pending = this.writes.then(() => this.write(file, content));
    // A failed diagnostic write must not prevent a later final report.
    this.writes = pending.then(() => {}, () => {});
    return pending;
  }

  progress(stage: string, checks?: readonly SelfTestCheck[]) {
    this.current = stage;
    if (checks) this.checks = checks.map((check) => ({ ...check }));
    return this.save("selftest-progress.json", false);
  }

  fail(error: unknown) {
    const detail = error instanceof Error ? error.stack ?? error.message : String(error);
    this.errors.push(`${this.current}: ${detail}`);
    return this.save("selftest-result.json", true);
  }

  finish(checks: readonly SelfTestCheck[]) {
    this.checks = checks.map((check) => ({ ...check }));
    this.current = "Complete";
    return this.save("selftest-result.json", true);
  }
}

let recorder: SelfTestRecorder | undefined;
export const selfTestRecorder = () => recorder;
export const setSelfTestRecorder = (value: SelfTestRecorder) => { recorder = value; };
export const selfTestProgress = (stage: string, checks?: readonly SelfTestCheck[]) => recorder?.progress(stage, checks);
