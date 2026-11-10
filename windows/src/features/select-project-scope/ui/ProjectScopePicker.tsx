import { useLayoutEffect, useState } from "react";
import type { HostAccount } from "@/entities/git";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { Button, Spinner } from "@/shared/ui";
import { accounts, hubProjectOrganization, ProjectOrganizationState, type HubProjectScope } from "@/entities/hosting";
import "./project-scope-picker.css";

/** One owner picker is shared by Projects, Home, and project creation. GitLab accounts choose between the open repository and their groups, since GitLab has no personal boards. */
export function ProjectScopePicker({ account, repositoryOwner, scope, disabled = false, onChange, label = "Project scope", ariaLabel = label }: {
  account: HostAccount;
  repositoryOwner: string | null;
  scope: HubProjectScope;
  disabled?: boolean;
  onChange: (scope: HubProjectScope) => void;
  label?: string;
  ariaLabel?: string;
}) {
  useObserve(accounts);
  const [state] = useState(() => new ProjectOrganizationState()), catalog = useObserve(state);
  const [other, setOther] = useState(false), [login, setLogin] = useState("");
  useLayoutEffect(() => { void catalog.activate(account, accounts.revision); return () => { void catalog.activate(null, accounts.revision); }; }, [catalog, account.id, accounts.revision]);
  useLayoutEffect(() => { setOther(false); setLogin(""); }, [account.id]);
  const gitlab = account.provider === "gitlab", organization = hubProjectOrganization(scope, account.provider), entered = hubProjectOrganization(`organization:${login.trim()}`, account.provider);
  const ownerLabel = (owner: string) => gitlab ? t("Group: {0}", owner) : t("Organization: {0}", owner);
  const matching = catalog.items.find(item => item.id.toLowerCase() === organization?.toLowerCase());
  const selectedScope = matching ? `organization:${matching.id}` : scope;
  const openOrganization = () => { if (entered && !disabled) { const owner = catalog.items.find(item => item.id.toLowerCase() === entered.toLowerCase())?.id ?? entered; onChange(`organization:${owner}`); setOther(false); } };
  return <div className="project-scope-picker"><label className="hub-project-scope"><span>{t(label)}</span><select className="select" aria-label={t(ariaLabel)} value={selectedScope} disabled={disabled} onChange={event => { if (event.target.value === "other") setOther(true); else { setOther(false); onChange(event.target.value as HubProjectScope); } }}>
    {gitlab ? scope === "personal" && <option value="personal" disabled>{t("Choose a group")}</option> : <option value="personal">{t("My projects: @{0}", account.username)}</option>}
    {repositoryOwner && <option value="repository">{gitlab ? t("Repository: {0}", repositoryOwner) : t("Repository owner: {0}", repositoryOwner)}</option>}
    {organization && !catalog.items.some(item => item.id.toLowerCase() === organization.toLowerCase()) && <option value={scope}>{ownerLabel(organization)}</option>}
    {catalog.items.map(item => <option key={item.id} value={`organization:${item.id}`}>{ownerLabel(item.id)}</option>)}
    {!catalog.loading && !catalog.error && !catalog.items.length && <option disabled>{gitlab ? t("No groups found") : t("No organizations found")}</option>}
    <option value="other">{gitlab ? t("Other group…") : t("Other organization…")}</option>
  </select></label>
    {other && <div className="project-scope-manual"><label><span>{gitlab ? t("Group path") : t("Organization login")}</span><input className="input" aria-label={gitlab ? t("Group path") : t("Organization login")} value={login} disabled={disabled} onChange={event => setLogin(event.target.value)} onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); openOrganization(); } }}/></label><Button size="small" disabled={disabled || !entered} onClick={openOrganization}>{gitlab ? t("Open") : t("Open organization")}</Button></div>}
    {catalog.loading && <span className="hint" role="status"><Spinner/>{gitlab ? t("Loading…") : t("Loading organizations…")}</span>}
    {catalog.error && <span className="hint error-text" role="alert">{catalog.error}<Button size="small" disabled={disabled || catalog.loading} onClick={() => void catalog.load(catalog.items.length > 0)}>{gitlab ? t("Retry") : t("Retry organizations")}</Button></span>}
    {!catalog.loading && !catalog.error && catalog.more && <Button size="small" disabled={disabled} onClick={() => void catalog.load(true)}>{gitlab ? t("Load more") : t("Load more organizations")}</Button>}
  </div>;
}
