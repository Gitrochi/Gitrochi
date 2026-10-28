import { useEffect, useRef, useState } from "react";
import type { RepositoryTreeEntry } from "@/entities/git";
import { describe } from "@/shared/platform";
import { t } from "@/shared/i18n";
import { Spinner } from "@/shared/ui";
import { buildHTMLPreview, type PreviewBlobReader } from "../lib/html-preview";

/** An opaque, script-free document assembled only from the selected immutable tree. */
export function RepositoryHTMLPreview({ text, path, revision, entries, read }: { text: string; path: string; revision: string; entries: RepositoryTreeEntry[]; read: PreviewBlobReader }) {
  const [html, setHTML] = useState<string | null>(null), [error, setError] = useState<string | null>(null), request = useRef(0);
  useEffect(() => {
    const token = ++request.current; setHTML(null); setError(null);
    void buildHTMLPreview(text, path, entries, read).then((value) => { if (token === request.current) setHTML(value); }).catch((cause) => { if (token === request.current) setError(t(describe(cause))); });
    return () => { ++request.current; };
  }, [text, path, revision, entries, read]);
  return <div className="code-html-preview"><p>{t("Scripts and external resources are disabled in preview.")}</p>{error ? <div className="code-notice error-text" role="alert">{error}</div> : html ? <iframe title={t("Preview")} sandbox="" referrerPolicy="no-referrer" srcDoc={html}/> : <div className="code-loading"><Spinner/>{t("Loading…")}</div>}</div>;
}
