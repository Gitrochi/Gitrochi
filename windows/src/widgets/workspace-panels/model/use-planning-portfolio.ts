import { useLayoutEffect, useRef, useState } from "react";
import {
  hubError,
  type HubAccess,
  type ProjectPortfolioState,
} from "@/entities/hosting";
import { t } from "@/shared/i18n";
/** Independent reads are cancelled before painting another source or account. */
export function usePlanningPortfolio(
  data: ProjectPortfolioState,
  context: string,
  selection: string[] | null,
  canRead: boolean,
  fixture: boolean,
  resolveAccess: (current: () => boolean) => Promise<HubAccess>,
) {
  const active = useRef(true),
    current = useRef(context),
    [readError, setReadError] = useState("");
  current.current = context;
  const isCurrent = () => active.current && current.current === context;
  const readAccess = async () => {
    const access = await resolveAccess(isCurrent);
    if (!isCurrent())
      throw new Error(
        t("The repository or account changed. Reopen this action."),
      );
    return access;
  };
  const load = async (append = false) => {
    setReadError("");
    try {
      await data.load(await readAccess(), context, append);
    } catch (error) {
      if (isCurrent()) setReadError(hubError(error));
    }
  };
  const refresh = async () => {
    if (!data.projects.length) return load();
    setReadError("");
    try {
      await data.refresh(await readAccess(), context);
    } catch (error) {
      if (isCurrent()) setReadError(hubError(error));
    }
  };
  useLayoutEffect(() => {
    active.current = true;
    setReadError("");
    if (!fixture) {
      data.reset(context);
      if (selection !== null) data.setSelected(selection);
      if (canRead) void load();
    }
    return () => {
      active.current = false;
      if (!fixture) data.reset(`${context}:inactive`);
    };
  }, [context, fixture]);
  return { readError, setReadError, isCurrent, readAccess, load, refresh };
}
