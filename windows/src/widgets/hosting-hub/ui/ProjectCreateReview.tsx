import { useEffect, useRef } from "react";
import { Globe2, LockKeyhole, ShieldCheck } from "lucide-react";
import { t } from "@/shared/i18n";
import { Button, Spinner } from "@/shared/ui";
export function ProjectCreateReview({
  title,
  owner,
  account,
  plan,
  isPublic,
  busy,
  disabled,
  error,
  confirm,
  cancel,
}: {
  title: string;
  owner: string;
  account: string;
  plan: string;
  isPublic: boolean;
  busy: boolean;
  disabled: boolean;
  error?: string;
  confirm: () => void;
  cancel: () => void;
}) {
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => { panel.current?.focus(); }, []);
  return (
    <div
      ref={panel}
      tabIndex={-1}
      className="project-create-review"
      role="alertdialog"
      onKeyDown={(event) => {
        if (event.key === "Escape" && !busy) { event.preventDefault(); cancel(); }
      }}
      aria-label={t("Create project?")}
    >
      <div className="project-create-review-icon">
        {isPublic ? <Globe2 size={24} /> : <LockKeyhole size={24} />}
      </div>
      <h3>{t("Create project?")}</h3>
      <h2>{title}</h2>
      <dl>
        <div>
          <dt>{t("Owner")}</dt>
          <dd>{owner}</dd>
        </div>
        <div>
          <dt>{t("Account")}</dt>
          <dd>{account}</dd>
        </div>
        <div>
          <dt>{t("Reported plan")}</dt>
          <dd>{plan}</dd>
        </div>
        <div>
          <dt>{t("Visibility")}</dt>
          <dd>{isPublic ? t("Public project") : t("Private project")}</dd>
        </div>
      </dl>
      <p>
        <ShieldCheck size={14} />
        {isPublic
          ? t(
              "Anyone can view this public project. Repository items keep their own access rules.",
            )
          : t("Only people with project access can view this private project.")}
      </p>
      {error && (
        <div className="project-create-error" role="alert">
          {error}
        </div>
      )}
      <footer>
        <Button disabled={busy} onClick={cancel}>
          {t("Cancel")}
        </Button>
        <Button kind="primary" aria-label={t(isPublic ? "Create public project" : "Create private project")} disabled={busy || disabled} onClick={confirm}>
          {busy ? <Spinner /> : null}
          {t(isPublic ? "Create public project" : "Create private project")}
        </Button>
      </footer>
    </div>
  );
}
