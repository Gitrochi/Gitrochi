import { useEffect, useRef, useState } from "react";
import {
  hubError,
  inspectHubProjectCreationCapabilities,
  type HostingHubStore,
  type HubAccess,
  type HubProjectCreationCapabilities,
} from "@/entities/hosting";
import type { ProjectCreationMode } from "../ui/ProjectCreationChooser";
/** Late responses never replace capability information for another account, owner, or creation mode. */
export function useProjectCreationCapabilities(
  hub: HostingHubStore,
  mode: ProjectCreationMode,
) {
  const [state, setState] = useState<{
      key: string;
      phase: "idle" | "loading" | "ready" | "error";
      value?: HubProjectCreationCapabilities;
      error?: string;
    }>({ key: "", phase: "idle" }),
    [retry, setRetry] = useState(0),
    request = useRef(0),
    context = hub.contextStamp,
    key = JSON.stringify([context, mode]);
  useEffect(() => {
    const id = ++request.current;
    if (mode === "local") {
      setState({ key, phase: "idle" });
      return;
    }
    if (hub.projectSource !== "remote") {
      setState({ key, phase: "loading" });
      return;
    }
    if (!hub.account || hub.account.provider !== "github") {
      setState({ key, phase: "idle" });
      return;
    }
    setState({ key, phase: "loading" });
    let access: HubAccess | undefined;
    void (async () => {
      try {
        access = await hub.access();
        const value = await inspectHubProjectCreationCapabilities(access);
        if (
          request.current === id &&
          hub.contextStamp === context &&
          access.stillCurrent?.() !== false
        )
          setState({ key, phase: "ready", value });
      } catch (error) {
        if (request.current === id && hub.contextStamp === context)
          setState({
            key,
            phase: "error",
            error: hubError(error, access?.token),
          });
      }
    })();
    return () => {
      request.current++;
    };
  }, [hub, context, mode, retry]);
  const visible =
    state.key === key
      ? state
      : {
          phase: mode === "local" ? ("idle" as const) : ("loading" as const),
          value: undefined,
          error: undefined,
        };
  return { ...visible, retry: () => setRetry((value) => value + 1) };
}
