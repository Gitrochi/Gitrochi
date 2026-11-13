import { avatars } from "@/entities/avatar";
import { workspace } from "@/entities/workspace";
import { settings } from "@/shared/config";
import { defaultLanguage, languages, t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Checkbox, Segmented, theme, themeModes } from "@/shared/ui";

/** 화면: 언어, 테마(시스템·라이트·다크) */
export function AppearanceSettings() {
  useObserve(theme);
  useObserve(settings);
  useObserve(avatars);
  const choice = settings.get<string>("language", defaultLanguage);
  return (
    <div className="col" style={{ gap: 14 }}>
      <div className="form-section">
        <span className="form-section-title">{t("Language")}</span>
        <select
          className="select"
          style={{ width: 260 }}
          value={choice}
          onChange={async (e) => {
            settings.set("language", e.target.value);
            await settings.flush();
            // 화면 글자는 시작할 때 정하므로 창을 다시 불러온다(열린 탭은 다시 열린다). 터미널 셸은 남지 않게 먼저 끝낸다.
            for (const tab of workspace.tabs) for (const term of tab.terminals) term.terminate();
            window.location.reload();
          }}
        >
          <option value="system">{t("Follow system language")}</option>
          {languages.map((l) => (
            <option key={l.code} value={l.code}>
              {l.name}
            </option>
          ))}
        </select>
        <span className="hint">{t("The window reloads to apply the change. When there's no commit history to follow, the AI also writes in this language.")}</span>
      </div>
      <div className="form-section">
        <span className="form-section-title">{t("Theme")}</span>
        <Segmented value={theme.mode} onChange={(m) => theme.setMode(m)} options={themeModes.map((m) => ({ value: m.id, label: m.title }))} />
        <span className="hint">{t("System follows your Windows setting (app mode light or dark). The graph, terminal and title bar change with it.")}</span>
      </div>
      <div className="form-section">
        <span className="form-section-title">{t("Commit graph")}</span>
        <Checkbox checked={avatars.enabled} onChange={(v) => avatars.setEnabled(v)} label={t("Show author profile pictures")} />
        <span className="hint">{t("Looks for a GitHub profile, then a connected self-hosted GitLab profile, then Gravatar, and uses initials if none is found. An email hash is sent to Gravatar.")}</span>
      </div>
    </div>
  );
}
