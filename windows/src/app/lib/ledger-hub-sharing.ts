import { env, settings } from "@/shared/config";

/**
 * Settings › Ledger › Team hub (docs/ledger/DESIGN.md §14 D4): the Ledger is loaded and followed only when a person
 * turned sharing on (`LEDGER_HUB_SETTING`); otherwise nothing is read or sent. (macOS: App.swift)
 */
export async function startLedgerHubSharing() {
  if (env.selftest || !settings.get<boolean>("ledgerHubSharing", false)) return;
  const { ledgerHubSharing } = await import("@/entities/ledger");
  ledgerHubSharing.start();
}
