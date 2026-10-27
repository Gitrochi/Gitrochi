/** Isolated real component check. The self-test replaces transport and account access in memory. */
import { loadLanguage } from "../src/shared/i18n";
import { workspacePanelsSelfTest } from "../src/app/lib/workspace-panels-selftest";
import "../src/app/styles/global.css";
const params = new URLSearchParams(location.search);
await loadLanguage(params.get("lang") ?? "ko");
const result = await workspacePanelsSelfTest();
const output = document.createElement("pre");
output.id = "workspace-selftest-result";
output.dataset.passed = String(result[0]);
output.style.whiteSpace = "pre-wrap";
output.textContent = result[1];
document.getElementById("root")!.append(output);
