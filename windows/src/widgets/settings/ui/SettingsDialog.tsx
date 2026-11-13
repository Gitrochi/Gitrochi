import { useState } from "react";
import { t } from "@/shared/i18n";
import { Button, Modal, Segmented } from "@/shared/ui";
import { AISettings } from "./AISettings";
import { AboutSettings } from "./AboutSettings";
import { AccountsSettings } from "./AccountsSettings";
import { AppearanceSettings } from "./AppearanceSettings";
import { CLISettings } from "./CLISettings";
import { RulesSettings } from "./RulesSettings";
import { ToolsSettings } from "./ToolsSettings";

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
        ) : (
          <AboutSettings />
        )}
      </div>
    </Modal>
  );
}

export type SettingsTab = "accounts" | "ai" | "rules" | "tools" | "cli" | "appearance" | "about";
