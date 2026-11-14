import { Contrast, Cpu, RefreshCw, ShieldCheck, SlidersHorizontal } from "lucide-react";
import { designIcon } from "@/shared/icons";
import { t } from "@/shared/i18n";
import "./settings-navigation.css";

export type SettingsTab = "accounts" | "ai" | "rules" | "tools" | "cli" | "appearance" | "about";

const categories = [
  { value: "accounts", title: "Accounts", icon: designIcon("account"), strokeWidth: 1.5 },
  { value: "ai", title: "AI", icon: Cpu, strokeWidth: 2.25 },
  { value: "rules", title: "Rules", icon: ShieldCheck, strokeWidth: 2.25 },
  { value: "tools", title: "Tool locations", icon: SlidersHorizontal, strokeWidth: 2.25 },
  { value: "cli", title: "CLI", icon: designIcon("terminal"), strokeWidth: 1.5 },
  { value: "appearance", title: "Appearance", icon: Contrast, strokeWidth: 2.25 },
  { value: "about", title: "Update", icon: RefreshCw, strokeWidth: 2.25 },
] as const;

/** Mirrors the compact monochrome category strip in macOS SettingsView. */
export function SettingsNavigation({ value, onChange }: { value: SettingsTab; onChange: (value: SettingsTab) => void }) {
  return (
    <nav className="settings-navigation" aria-label={t("Settings")}>
      {categories.map(({ value: category, title, icon: Icon, strokeWidth }) => (
        <button
          key={category}
          type="button"
          className="settings-category"
          aria-current={value === category ? "page" : undefined}
          onClick={() => onChange(category)}
          data-tip={t(title)}
        >
          <span className="settings-category-icon"><Icon size={20} strokeWidth={strokeWidth} aria-hidden="true" /></span>
          <span>{t(title)}</span>
        </button>
      ))}
    </nav>
  );
}
