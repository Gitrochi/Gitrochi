import { CircleCheck, KeyRound } from "@/shared/icons";
import { useState } from "react";
import { ai, type AIProviderId, aiProviders, providerById } from "@/entities/ai";
import { ipc } from "@/shared/api";
import { displayPath, isWindows } from "@/shared/config";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { tools } from "@/shared/platform";
import { Button, Spinner } from "@/shared/ui";

export function AISettings() {
  useObserve(ai);
  useObserve(tools);
  const [id, setId] = useState<AIProviderId>(ai.provider);
  const p = providerById(id);
  const [key, setKey] = useState("");
  const [models, setModels] = useState<string[]>([]);
  const [listing, setListing] = useState(false);
  const [testing, setTesting] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const select = (v: AIProviderId) => {
    setId(v);
    setModels([]);
    setResult(null);
    setError(null);
    setKey("");
  };
  const test = async () => {
    setTesting(true);
    setResult(null);
    try {
      const r = await ai.complete("Reply with exactly: OK", "ping", "low", id);
      setResult(t("✅ Response: ") + r.slice(0, 40));
    } catch (e) {
      setResult("❌ " + (e instanceof Error ? e.message : String(e)));
    }
    setTesting(false);
  };
  const fetchModels = async () => {
    setListing(true);
    setError(null);
    try {
      const list = await ai.listModels(id);
      setModels(list);
      if (!list.length) setError(t("No models were returned."));
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
    setListing(false);
  };
  const toolPath = p.tool ? tools.describe(p.tool) : null;
  return (
    <div className="col" style={{ gap: 14 }}>
      <div className="form-section">
        <span className="form-section-title">{t("AI for commit messages, commit explanations and PR descriptions")}</span>
        <div className="col" style={{ gap: 4 }}>
          {aiProviders.map((x) => {
            const problem = ai.problem(x.id);
            return (
              <label key={x.id} className="row" style={{ gap: 8, padding: "3px 0" }}>
                <input type="radio" name="ai" checked={id === x.id} onChange={() => select(x.id)} style={{ accentColor: "var(--accent)" }} />
                <span className="grow">{x.title}</span>
                {ai.provider === x.id ? (
                  <span className="chip-warn" style={{ color: "var(--accent)", background: "var(--accent-soft)" }}>
                    {t("In use")}</span>
                ) : (
                  !problem && <span className="faint" style={{ fontSize: 11 }}>{t("Ready")}</span>
                )}
              </label>
            );
          })}
        </div>
      </div>

      <div className="form-section">
        <div className="row">
          <span className="form-section-title grow">{p.title}</span>
          {ai.provider === id ? (
            <span className="row" style={{ color: "var(--green)", fontSize: 12 }}>
              <CircleCheck size={13} /> {" "}{t("Using this AI")}</span>
          ) : (
            <Button size="small" kind="primary" onClick={() => ai.setProvider(id)}>
              {t("Use this AI")}</Button>
          )}
        </div>
        {p.kind === "cli" && (
          <div className="form-row">
            <label>{t("Executable")}</label>
            <span className="ellipsis">{toolPath ? displayPath(toolPath) : <span className="error-text">{t("Not found — locate it in the Tools tab")}</span>}</span>
          </div>
        )}
        {id === "compatible" && (
          <div className="form-row">
            <label>{t("Server address")}</label>
            <input className="input" defaultValue={ai.baseURL} placeholder="http://localhost:11434/v1" onBlur={(e) => ai.setBaseURL(e.target.value)} spellCheck={false} />
          </div>
        )}
        {p.kind === "api" && (
          <div className="form-row">
            <label>{t("API key")}</label>
            {ai.hasKey[id] ? (
              <div className="row">
                <KeyRound size={14} /> <span className="grow">{t("Saved")}</span>
                <Button size="small" onClick={() => void ai.setKey(id, "")}>
                  {t("Delete")}</Button>
              </div>
            ) : (
              <div className="row">
                <input className="input" type="password" value={key} placeholder={p.keyHint} onChange={(e) => setKey(e.target.value)} />
                <Button disabled={!key.trim()} onClick={() => void ai.setKey(id, key).then(() => setKey(""))}>
                  {t("Save")}</Button>
              </div>
            )}
          </div>
        )}
        <div className="form-row">
          <label>{t("Model")}</label>
          <div className="row">
            <input className="input" list={`models-${id}`} value={ai.models[id] ?? p.defaultModel} placeholder={p.modelHint} onChange={(e) => ai.setModel(id, e.target.value)} spellCheck={false} />
            <datalist id={`models-${id}`}>
              {models.map((m) => (
                <option key={m} value={m} />
              ))}
            </datalist>
            {p.kind === "api" && (
              <Button size="small" disabled={listing} onClick={() => void fetchModels()} tip={t("Load model list|Fetches the models available with this key")}>
                {listing ? <Spinner size={11} /> : t("List")}
              </Button>
            )}
          </div>
        </div>
        {models.length > 0 && <span className="hint">{t("Got {0} models. Click the model field to choose one.", models.length)}</span>}
        {error && <span className="error-text">{error}</span>}
        <span className="hint">{p.note}</span>
        <div className="row">
          {p.keyURL && (
            <button className="link" onClick={() => void ipc.openUrl(p.keyURL!)}>
              {t("Create key")}</button>
          )}
          <span className="spacer" />
          {testing && <Spinner />}
          <Button disabled={testing} onClick={() => void test()}>
            {t("Test connection")}</Button>
        </div>
        {result && <span style={{ fontSize: 12, wordBreak: "break-word" }}>{result}</span>}
      </div>
      <span className="hint">{t("Your changes (diff) are sent to the chosen AI. Keys are stored in {0}.", isWindows() ? t("Windows Credential Manager") : t("Keychain"))}</span>
    </div>
  );
}
