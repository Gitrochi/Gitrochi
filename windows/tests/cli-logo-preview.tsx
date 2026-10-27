/** 브라우저 점검: /tests/cli-logo-preview.html. 서비스 호출은 메모리에만 두며 사용자 설정을 바꾸지 않는다. */
import "../src/app/styles/global.css";
import { createRoot } from "react-dom/client";
import { gitch } from "../src/entities/gitch";
import { loadLanguage, t } from "../src/shared/i18n";
import { CLISettings } from "../src/widgets/settings/ui/CLISettings";

await loadLanguage("ko");
let saved = true;
let failSave = false;
let saves = 0;
const pause = () => new Promise((resolve) => setTimeout(resolve, 75));
Object.defineProperty(gitch, "bundled", { configurable: true, get: () => "C:/Gitrochi/resources/gitch" });
gitch.version = async () => "0.3.12";
gitch.installed = async () => null;
gitch.installedIsBundled = async () => false;
gitch.hasConfig = async () => true;
gitch.bash = async () => "C:/Program Files/Git/bin/bash.exe";
gitch.accounts = async () => [];
gitch.logo = async () => { await pause(); return saved; };
gitch.setLogo = async (enabled) => {
  saves++;
  await pause();
  if (failSave) throw new Error("Fixture: 설정을 저장할 수 없습니다.");
  saved = enabled;
  return saved;
};

function setTheme(value: "light" | "dark") { document.documentElement.dataset.theme = value; }
setTheme(new URLSearchParams(location.search).get("theme") === "dark" ? "dark" : "light");
function Preview() {
  return <main style={{ margin: "24px auto", maxWidth: 700, padding: "0 20px 32px" }}>
    <h2 style={{ fontSize: 18, marginBottom: 12 }}>CLI 설정 · 작은 눈 로고</h2>
    <div className="row" style={{ marginBottom: 14 }}>
      <button className="btn small" onClick={() => setTheme("light")}>밝게</button>
      <button className="btn small" onClick={() => setTheme("dark")}>어둡게</button>
      <button className="btn small" onClick={() => void checks()}>UI 점검 실행</button>
    </div>
    <div id="logo-fixture"><CLISettings /></div>
    <pre id="logo-checks" style={{ whiteSpace: "pre-wrap", fontSize: 12 }} />
  </main>;
}
const waitFor = async (test: () => boolean) => {
  for (let i = 0; i < 100; i++) { if (test()) return; await new Promise((resolve) => setTimeout(resolve, 25)); }
  throw new Error("UI check timed out");
};
async function checks() {
  const output = document.getElementById("logo-checks")!;
  const host = document.getElementById("logo-fixture")!;
  const checkbox = () => host.querySelector<HTMLInputElement>('input[type="checkbox"]');
  const button = (label: string) => Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((b) => b.textContent?.includes(label));
  const assert = (condition: boolean, reason: string) => { if (!condition) throw new Error(reason); };
  try {
    await waitFor(() => checkbox()?.disabled === false);
    assert(checkbox()!.checked, "Saved on state missing");
    assert(button(t("Enable terminal command…"))?.disabled === true, "Account-free appearance setting must not enable installation");
    checkbox()!.click();
    await waitFor(() => checkbox()?.disabled === true);
    await waitFor(() => checkbox()?.disabled === false && !checkbox()!.checked);
    assert(!saved && saves === 1, "Checkbox did not persist the off state");
    checkbox()!.click();
    await waitFor(() => checkbox()?.disabled === false && checkbox()!.checked && saves === 2);
    saved = false;
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => checkbox()?.disabled === false && !checkbox()!.checked);
    saved = true;
    window.dispatchEvent(new Event("focus"));
    await waitFor(() => checkbox()?.disabled === false && checkbox()!.checked);
    failSave = true;
    checkbox()!.click();
    await waitFor(() => host.querySelector('[role="alert"]') !== null && checkbox()?.disabled === false);
    assert(checkbox()!.checked && saved, "Failed save changed the displayed state");
    failSave = false;
    button(t("Retry"))!.click();
    await waitFor(() => host.querySelector('[role="alert"]') === null && checkbox()?.disabled === false);
    assert(host.textContent!.includes("gitch logo on"), "Terminal instructions missing");
    output.textContent = "PASS: checkbox on/off, pending guard, focus refresh, save failure, retry, account-free appearance, installation guard.";
    output.dataset.result = "pass";
  } catch (error) { output.textContent = String(error); output.dataset.result = "fail"; }
}
createRoot(document.getElementById("root")!).render(<Preview />);
