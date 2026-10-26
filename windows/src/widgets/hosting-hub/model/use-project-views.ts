import { useCallback, useEffect, useRef, useState } from "react";
import {
  hubError,
  hubProjectViews,
  type HubAccess,
  type HubDetail,
  type HubProjectView,
} from "@/entities/hosting";
/** Reads only the captured project's shared view configuration. */
export function useProjectViews(
  detail: HubDetail,
  readAccess?: () => Promise<HubAccess>,
) {
  const source = useRef({ detail, readAccess });
  source.current = { detail, readAccess };
  const request = useRef(0),
    cursor = useRef<string>();
  const [views, setViews] = useState<HubProjectView[]>([]),
    [loading, setLoading] = useState(false),
    [error, setError] = useState(""),
    [more, setMore] = useState(false);
  const load = useCallback(async (append = false) => {
    const { detail, readAccess } = source.current;
    if (!readAccess) return;
    const id = ++request.current;
    setLoading(true);
    setError("");
    let token: string | undefined;
    try {
      const access = await readAccess();
      token = access.token;
      const result = await hubProjectViews(
        access,
        detail,
        append ? cursor.current : undefined,
      );
      if (id !== request.current) return;
      setViews((current) =>
        append
          ? [
              ...current,
              ...result.views.filter(
                (view) => !current.some((item) => item.id === view.id),
              ),
            ]
          : result.views,
      );
      cursor.current = result.cursor;
      setMore(result.more);
    } catch (failure) {
      if (id === request.current) setError(hubError(failure, token));
    } finally {
      if (id === request.current) setLoading(false);
    }
  }, []);
  useEffect(() => {
    setViews([]);
    cursor.current = undefined;
    void load();
    return () => {
      request.current++;
    };
  }, [detail.item.id, load]);
  return {
    views,
    loading,
    error,
    more,
    reload: useCallback(() => load(), [load]),
    loadMore: useCallback(() => load(true), [load]),
  };
}
