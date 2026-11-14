import { useState } from "react";
import { t } from "@/shared/i18n";
import { Button, Modal } from "@/shared/ui";
import { AISettings } from "./AISettings";
import { AboutSettings } from "./AboutSettings";
import { AccountsSettings } from "./AccountsSettings";
import { AppearanceSettings } from "./AppearanceSettings";
import { CLISettings } from "./CLISettings";
import { RulesSettings } from "./RulesSettings";
import { ToolsSettings } from "./ToolsSettings";
import { SettingsNavigation, type SettingsTab } from "./SettingsNavigation";

export type { SettingsTab } from "./SettingsNavigation";

/** Settings keep the same category order and symbols as the macOS preferences window. */
export function SettingsDialog({ onClose, initialTab = "accounts" }: { onClose: () => void; initialTab?: SettingsTab }) {
  const [tab, setTab] = useState<SettingsTab>(initialTab);
  return (
    <Modal title={t("Settings")} width={640} onClose={onClose} footer={<Button onClick={onClose}>{t("Close")}</Button>}>
      <SettingsNavigation value={tab} onChange={setTab} />
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
        ) : (
          <AboutSettings />
        )}
      </div>
    </Modal>
  );
}
