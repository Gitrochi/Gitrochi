import { Channel, invoke } from "@tauri-apps/api/core";
import { env, settings } from "@/shared/config";
import { Observable } from "@/shared/lib";
import { betaEndpoint, type ReleaseEntry } from "./release-version";

const releasesAPI = "https://api.github.com/repos/Gitrochi/Gitrochi/releases?per_page=20";

export interface UpdateInfo {
  version: string;
  current: string;
  notes: string | null;
  date: string | null;
}

type UpdateEvent = { kind: "progress"; downloaded: number; total: number | null } | { kind: "finished" };

/**
 * 자동 업데이트: 켤 때와 하루에 한 번 GitHub Releases 를 확인하고, 새 버전이 있으면 알린다.
 * 설치 파일은 서명이 맞을 때만 설치된다(서명 열쇠는 릴리스를 만드는 쪽만 갖고 있다).
 */
class Updater extends Observable {
  state: "idle" | "checking" | "available" | "none" | "downloading" | "installing" | "error" = "idle";
  info: UpdateInfo | null = null;
  downloaded = 0;
  total: number | null = null;
  error: string | null = null;
  /** 새 버전 안내 창을 띄울지 */
  prompt = false;
  lastChecked: number | null = null;

  get autoCheck() {
    return settings.get("autoUpdate", true);
  }

  setAutoCheck(v: boolean) {
    settings.set("autoUpdate", v);
    this.emit();
  }

  /** Pre-releases are offered too. Turning it off keeps the beta until the next release, which is newer. */
  get beta() {
    return settings.get("betaUpdates", false);
  }

  setBeta(v: boolean) {
    settings.set("betaUpdates", v);
    this.emit();
  }

  private async endpoint(): Promise<string | null> {
    if (!this.beta) return null;
    const response = await fetch(releasesAPI, { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error(`GitHub ${response.status}`);
    return betaEndpoint((await response.json()) as ReleaseEntry[]);
  }

  /** 앱을 켤 때: 자동 확인이 켜져 있으면 조용히 확인하고, 하루에 한 번 다시 */
  start() {
    if (env.selftest) return;
    const run = () => {
      if (this.autoCheck) void this.check(false);
    };
    setTimeout(run, 8000);
    setInterval(run, 24 * 3600 * 1000);
  }

  async check(manual: boolean) {
    if (this.state === "checking" || this.state === "downloading" || this.state === "installing") return;
    this.state = "checking";
    this.error = null;
    this.emit();
    try {
      const info = await invoke<UpdateInfo | null>("update_check", { endpoint: await this.endpoint() });
      this.lastChecked = Date.now();
      this.info = info;
      this.state = info ? "available" : "none";
      const skipped = settings.get<string | null>("skippedUpdate", null);
      // 자동 확인에서는 건너뛰기로 한 버전은 다시 묻지 않는다
      this.prompt = !!info && (manual || skipped !== info.version);
    } catch (e) {
      this.state = "error";
      this.error = String(e);
      this.prompt = manual;
    }
    this.emit();
  }

  skip() {
    if (this.info) settings.set("skippedUpdate", this.info.version);
    this.dismiss();
  }

  dismiss() {
    this.prompt = false;
    this.emit();
  }

  async install() {
    this.state = "downloading";
    this.downloaded = 0;
    this.total = null;
    this.error = null;
    this.emit();
    const ch = new Channel<UpdateEvent>();
    ch.onmessage = (e) => {
      if (e.kind === "progress") {
        this.downloaded = e.downloaded;
        this.total = e.total;
      } else this.state = "installing";
      this.emit();
    };
    try {
      await invoke("update_install", { onEvent: ch });
      await settings.flush();
      await invoke("app_restart");
    } catch (e) {
      this.state = "error";
      this.error = String(e);
      this.emit();
    }
  }
}

export const updater = new Updater();
