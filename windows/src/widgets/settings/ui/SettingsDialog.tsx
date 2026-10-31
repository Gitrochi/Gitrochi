import { lazy, Suspense, useState } from "react";
import { destinationEnabled } from "@/entities/git";
import { t } from "@/shared/i18n";
import { Button, Modal, Segmented, Spinner } from "@/shared/ui";
import { AISettings } from "./AISettings";
import { AboutSettings } from "./AboutSettings";
import { AccountsSettings } from "./AccountsSettings";
import { AppearanceSettings } from "./AppearanceSettings";
import { CLISettings } from "./CLISettings";
import { RulesSettings } from "./RulesSettings";
import { ToolsSettings } from "./ToolsSettings";

// Only with the Ledger preview, and loaded on demand like the Ledger page, so the start-up bundle stays as it was
const LedgerSettings = lazy(() => import("./LedgerSettings").then((module) => ({ default: module.LedgerSettings })));

/** Ctrl+, 설정: 계정(GitHub·GitLab), AI, 규칙, 도구(실행 파일 위치), CLI(gitch), 화면(테마), 업데이트 */
export function SettingsDialog({ onClose, initialTab = "accounts" }: { onClose: () => void; initialTab?: SettingsTab }) {
  const [tab, setTab] = useState<SettingsTab>(initialTab);
  return (
    <Modal title={t("Settings")} width={640} onClose={onClose} footer={<Button onClick={onClose}>{t("Close")}</Button>}>
      <Segmented
        value={tab}
        onChange={setTab}
        options={[
          { value: "accounts", label: t("Accounts") },
          { value: "ai", label: "AI" },
          { value: "rules", label: t("Rules") },
          { value: "tools", label: t("Tool locations") },
          { value: "cli", label: "CLI" },
          { value: "appearance", label: t("Appearance") },
          ...(destinationEnabled("ledger") ? [{ value: "ledger" as const, label: t("Ledger") }] : []),
          { value: "about", label: t("Update") },
        ]}
      />
      <div style={{ minHeight: 420 }}>
        {tab === "accounts" ? (
          <AccountsSettings />
        ) : tab === "ai" ? (
          <AISettings />
        ) : tab === "rules" ? (
          <RulesSettings />
        ) : tab === "tools" ? (
          <ToolsSettings />
        ) : tab === "cli" ? (
          <CLISettings />
        ) : tab === "appearance" ? (
          <AppearanceSettings />
        ) : tab === "ledger" && destinationEnabled("ledger") ? (
          <Suspense fallback={<Spinner />}>
            <LedgerSettings />
          </Suspense>
        ) : (
          <AboutSettings />
        )}
      </div>
    </Modal>
  );
}

export type SettingsTab = "accounts" | "ai" | "rules" | "tools" | "cli" | "appearance" | "ledger" | "about";
