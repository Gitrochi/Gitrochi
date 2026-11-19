import { useEffect, useState } from "react";
import { searchEngineKey, searchEngines } from "@/entities/terminal";
import { ipc } from "@/shared/api";
import { dirname, displayPath, isWindows, settings, toWslPath, wslDistroOf } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { listDistros, type ToolId, toolList, tools, wslCapable } from "@/shared/platform";
import { Button, showMenuBelow, Spinner } from "@/shared/ui";

export function ToolsSettings() {
  useObserve(tools);
  useObserve(settings);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<ToolId | null>(null);
  const [distros, setDistros] = useState<string[]>([]);
  useEffect(() => {
    if (isWindows()) void listDistros().then(setDistros);
  }, []);
  const findInWsl = async (id: ToolId, distro: string) => {
    setError(null);
    setBusy(id);
    try {
      await tools.useWsl(id, distro);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setBusy(null);
  };
  const load = async (id: ToolId, title: string) => {
    setError(null);
    const current = tools.path(id);
    const picked = await ipc.pickFile(t("Choose the {0} executable", title), current ? dirname(current) : undefined);
    if (!picked) return;
    setBusy(id);
    try {
      // \\wsl.localhost\배포판\… 안의 파일이면 WSL 도구로
      const distro = wslDistroOf(picked);
      if (distro && wslCapable.includes(id)) await tools.useWslPath(id, distro, toWslPath(picked));
      else await tools.setCustom(id, picked);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setBusy(null);
  };
  return (
    <div className="col" style={{ gap: 10 }}>
      <span className="hint">
        {t("Install locations differ between PCs. If a tool isn't found automatically, use")}{" "}<b>{t("Locate")}</b>{t(" to choose the executable yourself. The chosen path is saved and used next time.")}</span>
      <div className="form-section">
        <span className="form-section-title">{t("Search engine")}</span>
        <select
          className="select"
          style={{ width: 260 }}
          value={settings.get<string>(searchEngineKey, "google")}
          onChange={(e) => settings.set(searchEngineKey, e.target.value)}
        >
          {searchEngines.map((engine) => (
            <option key={engine.id} value={engine.id}>
              {engine.title}
            </option>
          ))}
        </select>
        <span className="hint">{t("Text typed into a browser tab's address bar that isn't an address is searched with this engine.")}</span>
      </div>
      {toolList.map((tool) => {
        const st = tools.state[tool.id];
        const w = tools.wsl(tool.id);
        const canWsl = wslCapable.includes(tool.id) && distros.length > 0;
        return (
          <div key={tool.id} className="form-section" style={{ gap: 6, padding: 10 }}>
            <div className="row">
              <span style={{ fontWeight: 600 }}>{tool.title}</span>
              {tool.required && <span className="faint" style={{ fontSize: 11 }}>{t("Required")}</span>}
              <span className="spacer" />
              {w ? (
                <span className="chip-warn" style={{ color: "var(--accent)", background: "var(--accent-soft)" }}>
                  WSL · {w.distro}
                </span>
              ) : (
                <>
                  {st.source === "custom" && <span className="chip-warn" style={{ color: "var(--accent)", background: "var(--accent-soft)" }}>{t("Set manually")}</span>}
                  {st.source === "auto" && <span className="faint" style={{ fontSize: 11 }}>{t("Found automatically")}</span>}
                  {st.source === "none" && <span className="chip-warn">{t("None")}</span>}
                </>
              )}
            </div>
            <span className="hint">{tool.detail}</span>
            <div className="row">
              <span className="ellipsis grow mono" style={{ fontSize: 11.5 }}>
                {w ? w.path : st.path ? (st.path.startsWith("wsl:") ? `WSL · ${st.path.slice(4)}` : displayPath(st.path)) : "—"}
              </span>
              {busy === tool.id && <Spinner size={12} />}
              {!w && (
                <Button size="small" onClick={() => void load(tool.id, tool.title)}>
                  {t("Locate…")}</Button>
              )}
              {canWsl &&
                (w ? (
                  <Button size="small" onClick={() => tools.useWindows(tool.id)} tip={t("Uses the Windows install instead of WSL")}>
                    {t("Use the Windows one")}</Button>
                ) : (
                  <Button
                    size="small"
                    tip={t("Find in WSL|Finds {1} installed in WSL ({0}). If you have several distributions, use ▾", distros[0], tool.command)}
                    onClick={(e) =>
                      distros.length === 1
                        ? void findInWsl(tool.id, distros[0])
                        : showMenuBelow(e.currentTarget, distros.map((d) => ({ label: t("Find in {0}", d), onClick: () => void findInWsl(tool.id, d) })))
                    }
                  >
                    {t("Find in WSL")}</Button>
                ))}
              {tool.id === "shell" && distros.length > 0 && (
                <Button
                  size="small"
                  tip={t("Opens the terminal in a WSL distribution's shell (with the repository folder as a Linux path)")}
                  onClick={(e) => showMenuBelow(e.currentTarget, distros.map((d) => ({ label: `WSL · ${d}`, onClick: () => tools.setShellWsl(d) })))}
                >
                  {t("WSL shell…")}</Button>
              )}
              {st.source === "custom" && (
                <Button size="small" onClick={() => void tools.resetToAuto(tool.id)} tip={t("Clears the path you chose and finds it automatically again")}>
                  {t("Auto")}</Button>
              )}
              {st.source === "none" && tool.install && (
                <button className="link" onClick={() => void ipc.openUrl(tool.install!)}>
                  {t("Install")}</button>
              )}
            </div>
            {(w ? w.version : st.version) && <span className="faint" style={{ fontSize: 11 }}>{w ? w.version : st.version}</span>}
          </div>
        );
      })}
      {error && <span className="error-text">{error}</span>}
    </div>
  );
}
