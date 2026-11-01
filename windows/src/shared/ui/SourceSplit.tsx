import { type ReactNode, useRef, useState } from "react";
import { t } from "@/shared/i18n";
import "./source-split.css";

/** A themed, keyboard-resizable hairline between source and its preview. */
export function SourceSplit({ first, second }: { first: ReactNode; second: ReactNode }) {
  const host = useRef<HTMLDivElement>(null), [ratio, setRatio] = useState(56);
  const move = (x: number) => { const bounds = host.current?.getBoundingClientRect(); if (bounds) setRatio(Math.max(30, Math.min(72, (x - bounds.left) / bounds.width * 100))); };
  return <div ref={host} className="source-split" style={{ gridTemplateColumns: `minmax(0, ${ratio}fr) 5px minmax(0, ${100 - ratio}fr)` }}><div className="source-split-first">{first}</div><div className="source-split-divider" role="separator" tabIndex={0} aria-label={t("Resize code and diagram")} aria-orientation="vertical" aria-valuenow={Math.round(ratio)} aria-valuemin={30} aria-valuemax={72} onDoubleClick={() => setRatio(56)} onPointerDown={(event) => { event.preventDefault(); event.currentTarget.setPointerCapture(event.pointerId); }} onPointerMove={(event) => { if (event.currentTarget.hasPointerCapture(event.pointerId)) move(event.clientX); }} onKeyDown={(event) => { if (["ArrowLeft", "ArrowRight", "Home"].includes(event.key)) { event.preventDefault(); setRatio((value) => event.key === "Home" ? 56 : Math.max(30, Math.min(72, value + (event.key === "ArrowRight" ? 3 : -3)))); } }} /><div className="source-split-second">{second}</div></div>;
}
