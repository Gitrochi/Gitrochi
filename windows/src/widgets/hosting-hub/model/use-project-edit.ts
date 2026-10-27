import { useRef, useState } from "react";
import { hubError, type HubAccess } from "@/entities/hosting";
import { saveProjectEdit, type ProjectAsk } from "../lib/project-workspace";

/** Editors retain their input and show failures beside the submit action. */
export function useProjectEdit(ask: ProjectAsk) {
  const pending = useRef(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState("");
  const run = async (
    title: string,
    body: string,
    action: (access: HubAccess) => Promise<unknown>,
    refresh?: "list" | "detail",
  ) => {
    if (pending.current) return false;
    pending.current = true;
    setBusy(true);
    setError("");
    try {
      return await saveProjectEdit(ask, title, body, action, refresh);
    } catch (failure) {
      setError(hubError(failure));
      return false;
    } finally {
      pending.current = false;
      setBusy(false);
    }
  };
  return { busy, error, run };
}
