import { ipc } from "@/shared/api";
import { Observable } from "@/shared/lib";
import { env, joinPath } from "./env";

/** 앱 설정(<데이터 폴더>/settings.json). 토큰은 여기 두지 않고 자격 증명 관리자에 둔다. */
class Settings extends Observable {
  private data: Record<string, unknown> = {};
  private timer: ReturnType<typeof setTimeout> | null = null;

  private get file() {
    return joinPath(env.dataDir, "settings.json");
  }

  async load() {
    try {
      const text = await ipc.readText(this.file);
      if (text) this.data = JSON.parse(text);
    } catch {
      this.data = {};
    }
  }

  get<T>(key: string, fallback: T): T {
    return (this.data[key] as T) ?? fallback;
  }

  set(key: string, value: unknown) {
    if (JSON.stringify(this.data[key]) === JSON.stringify(value)) return;
    if (value === undefined) delete this.data[key];
    else this.data[key] = value;
    this.emit();
    this.scheduleSave();
  }

  private scheduleSave() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.flush(), 300);
  }

  async flush() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    await ipc.writeText(this.file, JSON.stringify(this.data, null, 2)).catch(() => {});
  }
}

export const settings = new Settings();

// MARK: 최근 저장소

export function recents(): string[] {
  return settings.get<string[]>("recentRepositories", []);
}

export function addRecent(path: string) {
  const list = [path, ...recents().filter((p) => p !== path)].slice(0, 12);
  settings.set("recentRepositories", list);
  const opened = { ...settings.get<Record<string, number>>("recentRepositoryOpened", {}), [path]: Date.now() };
  settings.set("recentRepositoryOpened", Object.fromEntries(Object.entries(opened).filter(([p]) => list.includes(p))));
}

/** When the repository was last opened; undefined for one opened before this was recorded (Home shows it) */
export function recentOpened(path: string): number | undefined {
  return settings.get<Record<string, number>>("recentRepositoryOpened", {})[path];
}

export function removeRecent(path: string) {
  settings.set(
    "recentRepositories",
    recents().filter((p) => p !== path),
  );
}
