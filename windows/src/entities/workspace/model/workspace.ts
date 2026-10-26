import { RepoStore } from "@/entities/repo";
import { samePath, settings } from "@/shared/config";
import { t } from "@/shared/i18n";
import { Observable } from "@/shared/lib";

/**
 * 열린 저장소 탭 목록. 여러 저장소·워크트리를 탭으로 열어 두고 오간다.
 * 앱을 다시 켜면 지난번에 열어 둔 탭들을 복원한다. (맥 버전 Workspace — 맥은 창 탭, 여기는 앱 안의 탭)
 */
class Workspace extends Observable {
  tabs: RepoStore[] = [];
  activeId: string | null = null;
  /** 시작할 때 탭을 복원하는 중(로딩 화면) */
  restoring = true;
  restoreStep = t("Preparing…");

  get active(): RepoStore | null {
    return this.tabs.find((tab) => tab.id === this.activeId) ?? this.tabs[0] ?? null;
  }

  private make(): RepoStore {
    const s = new RepoStore();
    s.openRepo = (path) => void this.openInNewTab(path);
    s.activateTab = () => this.select(s.id);
    s.showTab = (path) => {
      const other = this.tabs.find((tab) => tab !== s && samePath(tab.path, path));
      if (other) this.select(other.id);
      return !!other;
    };
    s.subscribe(() => {
      // 저장소가 바뀌면 탭 목록 저장
      this.persist();
      this.emit();
    });
    return s;
  }

  /** 지난번 탭들을 다시 연다. 다 열릴 때까지 로딩 화면을 보여 준다. */
  async restore() {
    const paths = settings.get<string[]>("openTabs", []);
    const selected = settings.get<string | null>("selectedTab", null);
    const valid: string[] = [];
    const { ipc } = await import("@/shared/api");
    for (const p of paths) if (!valid.some((v) => samePath(v, p)) && (await ipc.exists(p))) valid.push(p);

    if (!valid.length) {
      const s = this.make();
      s.booted = true;
      this.tabs = [s];
      this.activeId = s.id;
      this.restoring = false;
      this.markActive();
      this.emit();
      return;
    }
    this.tabs = valid.map(() => this.make());
    const sel = Math.max(0, valid.findIndex((p) => samePath(p, selected)));
    this.activeId = this.tabs[sel].id;
    this.markActive();
    this.emit();
    let done = 0;
    // 보이는 탭을 먼저, 나머지는 뒤에서 차례로
    const order = [sel, ...valid.map((_, i) => i).filter((i) => i !== sel)];
    for (const i of order) {
      this.restoreStep = valid.length > 1 ? t("Opening tab {0}/{1} · {2}", done + 1, valid.length, valid[i].split(/[\\/]/).pop()) : t("Opening repository…");
      this.emit();
      await this.tabs[i].openInPlace(valid[i]);
      done++;
      if (i === sel) {
        this.restoring = false;
        this.emit();
      }
    }
    this.restoring = false;
    this.persist();
    this.emit();
  }

  newTab(): RepoStore {
    const s = this.make();
    s.booted = true;
    this.tabs = [...this.tabs, s];
    this.select(s.id);
    return s;
  }

  /** 이미 열린 저장소면 그 탭으로, 아니면 새 탭에서 연다 */
  async openInNewTab(path: string) {
    const existing = this.tabs.find((tab) => samePath(tab.path, path));
    if (existing) {
      this.select(existing.id);
      return;
    }
    const empty = this.active && !this.active.path && !this.active.loading ? this.active : null;
    const s = empty ?? this.newTab();
    await s.openInPlace(path);
  }

  select(id: string) {
    if (this.activeId === id) return;
    this.activeId = id;
    this.markActive();
    const s = this.active;
    if (s?.path) settings.set("selectedTab", s.path);
    void s?.activated();
    this.emit();
  }

  /** 지금 보이는 탭만 파일 변경에 바로 반응한다 */
  private markActive() {
    for (const tab of this.tabs) tab.isActive = tab.id === this.activeId;
  }

  selectRelative(d: number) {
    if (this.tabs.length < 2) return;
    const i = this.tabs.findIndex((tab) => tab.id === this.activeId);
    this.select(this.tabs[(i + d + this.tabs.length) % this.tabs.length].id);
  }

  closeTab(id: string) {
    const i = this.tabs.findIndex((tab) => tab.id === id);
    if (i < 0) return;
    const s = this.tabs[i];
    s.close();
    this.tabs = this.tabs.filter((tab) => tab.id !== id);
    if (!this.tabs.length) {
      this.newTab();
    } else if (this.activeId === id) {
      this.select(this.tabs[Math.min(i, this.tabs.length - 1)].id);
    }
    this.persist();
    this.emit();
  }

  /** 이 탭만 남기고 나머지를 닫는다 */
  closeOthers(id: string) {
    const keep = this.tabs.find((tab) => tab.id === id);
    if (!keep) return;
    for (const tab of this.tabs) if (tab !== keep) tab.close();
    this.tabs = [keep];
    this.select(id);
    this.persist();
    this.emit();
  }

  /** 모든 탭을 닫고 빈 탭 하나만 둔다 */
  closeAll() {
    for (const tab of this.tabs) tab.close();
    this.tabs = [];
    this.newTab();
    this.persist();
    this.emit();
  }

  persist() {
    if (this.restoring) return;
    const paths: string[] = [];
    for (const tab of this.tabs) if (tab.path && !paths.some((p) => samePath(p, tab.path))) paths.push(tab.path);
    settings.set("openTabs", paths);
    const a = this.active;
    if (a?.path) settings.set("selectedTab", a.path);
  }
}

export const workspace = new Workspace();
