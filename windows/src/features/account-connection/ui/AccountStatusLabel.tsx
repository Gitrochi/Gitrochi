import { TriangleAlert } from "lucide-react";
import { Check, Clock, KeyRound, Lock, ShieldLock } from "@/shared/icons";
import { t } from "@/shared/i18n";
import { StatusPill, type StatusTone } from "@/shared/ui";
import { type AccountStatus, accountStatusIcon, accountStatusTitle } from "@/entities/hosting";
import "./account-status.css";

const tone = (status: AccountStatus): StatusTone => (status === "signedIn" ? "passed" : status === "checking" ? "neutral" : "waiting");

/** Each state its own drawing: a shield for the organization's approval, a key for the system's, a warning for an expired sign-in */
function StatusIcon({ status, size }: { status: AccountStatus; size: number }) {
  const icon = accountStatusIcon(status);
  return icon === "shield" ? <ShieldLock size={size} /> : icon === "key" ? <KeyRound size={size} /> : icon === "warning" ? <TriangleAlert size={size} /> : icon === "clock" ? <Clock size={size} /> : <Check size={size} />;
}

/** A row's second line: the state's 12 px icon and its words in the state's tone (macOS: AccountStatusLabel) */
export function AccountStatusLabel({ status }: { status: AccountStatus }) {
  return (
    <span className="account-status-label status-tone" data-tone={tone(status)} data-status={status}>
      <StatusIcon status={status} size={12} />
      <span>{accountStatusTitle(status)}</span>
    </span>
  );
}

/** The same state as a badge, where a row has room for one (macOS: AccountStatusPill) */
export function AccountStatusPill({ status }: { status: AccountStatus }) {
  return <StatusPill tone={tone(status)} icon={<StatusIcon status={status} size={11} />} data-status={status}>{accountStatusTitle(status)}</StatusPill>;
}

/** A Git identity the repository's rules fix: a lock, never one of the approval drawings (macOS: LockedLabel) */
export function LockedLabel({ text }: { text?: string }) {
  return (
    <span className="account-status-label locked" data-status="locked">
      <Lock size={12} />
      <span>{text ?? t("Locked")}</span>
    </span>
  );
}
