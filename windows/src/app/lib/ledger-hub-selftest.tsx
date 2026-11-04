import { createElement } from "react";
import { createRoot } from "react-dom/client";
import type { LedgerBackend, LedgerHubTransport } from "@/entities/ledger";
import { settings } from "@/shared/config";
import { t } from "@/shared/i18n";

const ensure = (value: unknown, message: string) => { if (!value) throw new Error(message); };
async function until(test: () => unknown) {
  const end = Date.now() + 4000;
  while (Date.now() < end) { if (test()) return true; await new Promise((resolve) => setTimeout(resolve, 25)); }
  return !!test();
}

const KEYS = ["ledgerHubSharing", "ledgerHubComputer", "teamHubEndpoint"] as const;
const canonical = (value: unknown): string => JSON.stringify(value, (_key, v: unknown) => (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : 1))) : v));
const SHARED = ["branch", "changed", "client", "ledger", "related", "repo"];
const LEDGER = ["kind", "lastActivity", "project", "role", "session", "title", "verdict"];

/**
 * Settings › Ledger › Team hub and the inspector's hub overlaps, against a fake core and a fake hub: off by default with
 * nothing read or sent, what is shared spelled out, the core's bodies posted unchanged, overlaps with another computer's
 * session shown as a pill, and everything withdrawn when sharing is turned off.
 */
export async function ledgerHubSelfTest(): Promise<[boolean, string]> {
  const [{ LedgerHubSharing }, { HubSharingSection }, { HubOverlaps }] = await Promise.all([import("@/entities/ledger"), import("@/widgets/settings"), import("@/widgets/ledger-workspace")]);
  const saved = KEYS.map((key) => [key, settings.get<unknown>(key, undefined)] as const);
  for (const key of KEYS) settings.set(key, undefined);
  const calls: string[] = [], posts: Record<string, unknown>[] = [], withdrawals: string[] = [];
  const presence = { repo: "example.com/team/app", branch: "feature/retry", changed: ["src/retry.ts", "REQ-12"], related: [], client: "ledger/selftest01/S1103-01",
    ledger: { session: "S1103-01", project: "app", title: "Retry policy", kind: "research", role: "research", verdict: "active", lastActivity: "2026-11-03T09:00:00Z" } };
  const backend = { kind: "native", async call(method: string) {
    calls.push(method);
    if (method === "rev") return { rev: 7 };
    if (method === "hub_share") return { rev: 7, sessions: [{ sessionId: "S1103-01", repo: "example.com/team/app", client: presence.client, presence }], unshared: [] };
    throw new Error(`unexpected ${method}`);
  } } as unknown as LedgerBackend;
  const other = { member: "sam", client: "ledger/f00dfeed/S1103-07", branch: "feature/cache", head: "" };
  const transport: LedgerHubTransport = {
    async secret(name) { calls.push("secret:" + name); return "grh_selftest"; },
    async publish(_endpoint, body) {
      posts.push(JSON.parse(body) as Record<string, unknown>);
      return { status: 200, text: "", member: "alex", overlaps: [{ kind: "same-file", a: { member: "alex", client: presence.client, branch: "feature/retry", head: "" }, b: other, paths: ["REQ-12"] }] };
    },
    async withdraw(_endpoint, repo, client) { withdrawals.push(`${repo} ${client}`); return { status: 204, text: "" }; },
  };
  const sharing = new LedgerHubSharing(() => backend, transport);
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-10000px;top:0;width:340px;height:600px";
  document.body.append(host);
  const root = createRoot(host);
  const render = () => root.render(createElement("div", null, createElement(HubSharingSection, { sharing }), createElement(HubOverlaps, { sessionId: "S1103-01", sharing })));
  const box = () => host.querySelector<HTMLInputElement>("[data-ledger-section='team-hub'] input[type='checkbox']");
  try {
    render();
    ensure(await until(() => box()), "The Team hub section did not render");
    ensure(!box()!.checked && box()!.disabled, "Sharing must start off, and cannot be turned on without a connected hub");
    ensure(host.textContent?.includes(t("Connect a team hub under Work validation › Team overlap evidence first.")), "The section did not say where to connect a hub");
    ensure(host.querySelector("[data-ledger-hub='what-is-shared']")?.textContent?.includes(t("What is shared")), "What is shared is not next to the switch");
    sharing.start();
    await sharing.pass();
    ensure(calls.length === 0 && posts.length === 0, "Something was read or sent while sharing was off");

    settings.set("teamHubEndpoint", "https://hub.example.com");
    settings.set("ledgerHubComputer", "selftest01");
    render();
    ensure(await until(() => box() && !box()!.disabled), "A connected hub did not enable the switch");
    box()!.click();
    ensure(await until(() => host.textContent?.includes(t("Sessions shared with {0}: {1}", "hub.example.com", 1))), `Sharing did not report its status: ${host.textContent}`);
    ensure(calls[0] === "secret:teamHub:https://hub.example.com", "The hub token was not read from the credential store entry the hub panel keeps");
    ensure(posts.length === 1 && JSON.stringify(Object.keys(posts[0]).sort()) === JSON.stringify(SHARED), `Posted fields: ${JSON.stringify(posts[0])}`);
    ensure(JSON.stringify(Object.keys(posts[0].ledger as object).sort()) === JSON.stringify(LEDGER), "The session's shared fields changed on the way");
    ensure(canonical(posts[0]) === canonical(presence), "The core's body was not sent as it is");
    const pill = t("Also touched on another computer by {0} · {1}", "S1103-07", "sam");
    ensure(await until(() => host.querySelector(".ledger-hub-overlap .status-pill")?.textContent?.includes(pill)), "The other computer's session did not show as a pill");
    const row = host.querySelector<HTMLElement>(".ledger-hub-overlap")!;
    ensure(row.getBoundingClientRect().width <= 340, "The overlap row widened the inspector");

    box()!.click();
    ensure(await until(() => withdrawals.length === 1 && !host.querySelector(".ledger-hub-overlap")), "Turning sharing off did not withdraw the session and clear its overlaps");
    ensure(withdrawals[0] === "example.com/team/app ledger/selftest01/S1103-01" && settings.get("ledgerHubSharing", false) === false, "The wrong entry was withdrawn, or the switch stayed on");
    return [true, "Off by default with nothing sent, disclosure beside the switch, unchanged core bodies, the overlap pill, and withdrawal when turned off"];
  } catch (cause) {
    return [false, cause instanceof Error ? cause.message : String(cause)];
  } finally {
    await sharing.stop();
    root.unmount();
    host.remove();
    for (const [key, value] of saved) settings.set(key, value);
  }
}
