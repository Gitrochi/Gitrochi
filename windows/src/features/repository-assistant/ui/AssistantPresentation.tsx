import type { ReactNode } from "react";
import { Modal } from "@/shared/ui";

export function AssistantPresentation({ embedded = false, title, width, onClose, footer, children }: { embedded?: boolean; title: string; width: number; onClose: () => void; footer: ReactNode; children: ReactNode }) {
  if (!embedded) return <Modal title={title} width={width} onClose={onClose} footer={footer}>{children}</Modal>;
  return <section className="col" style={{ height: "100%", minHeight: 0 }}>
    <header style={{ padding: "22px 24px 12px", borderBottom: "1px solid var(--border)" }}><h1 style={{ fontSize: 22, margin: 0 }}>{title}</h1></header>
    <div className="col" style={{ flex: 1, minHeight: 0, overflow: "auto", gap: 12, padding: "18px 24px" }}>{children}</div>
    <footer className="row" style={{ gap: 8, padding: "12px 24px", borderTop: "1px solid var(--border)" }}>{footer}</footer>
  </section>;
}
