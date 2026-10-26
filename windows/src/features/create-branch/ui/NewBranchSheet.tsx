import { useState } from "react";
import type { ProjectTaskReference } from "@/entities/git";
import type { RepoStore } from "@/entities/repo";
import { t } from "@/shared/i18n";
import { validBranchName } from "@/shared/lib";
import { Checkbox, Frame, Row } from "@/shared/ui";

export function NewBranchSheet({ store, close, start, label, suggestedName, projectTask }: { store: RepoStore; close: () => void; start: string; label: string; suggestedName?: string; projectTask?: ProjectTaskReference }) {
  const [name, setName] = useState(suggestedName ?? "");
  const [checkout, setCheckout] = useState(true);
  return (
    <Frame title={t("New branch")} confirm={t("Create")} canConfirm={validBranchName(name)} close={close} onConfirm={() => void store.createBranch(name.trim(), start, checkout, projectTask)}>
      <Row label={t("Name")}>
        <input className="input" autoFocus value={name} placeholder={t("feature/new-feature")} onChange={(e) => setName(e.target.value)} spellCheck={false} />
      </Row>
      <Row label={t("Start point")}>
        <span className="mono">{label}</span>
      </Row>
      <Row label="">
        <Checkbox checked={checkout} onChange={setCheckout} label={t("Check out after creating")} />
      </Row>
    </Frame>
  );
}
