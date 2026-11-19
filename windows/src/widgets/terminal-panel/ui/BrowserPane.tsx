import { ArrowLeft, ArrowRight, ExternalLink, RotateCw } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import type { RepoStore } from "@/entities/repo";
import type { BrowserSession } from "@/entities/terminal";
import { t } from "@/shared/i18n";
import { useObserve } from "@/shared/lib";
import { IconButton } from "@/shared/ui";

/** App layers drawn over the page's box: the native webview would cover them, so it steps aside while one is open */
const overlays = '.menu, [role="dialog"], [aria-modal="true"]';

/**
 * A browser tab's body: back, forward, reload, the address and the system browser, then the page. The page is a
 * native child webview kept over the box below the bar. macOS: BrowserToolbar and BrowserHost in TerminalBrowser.swift
 */
export function BrowserPane({ page, store }: { page: BrowserSession; store: RepoStore }) {
  useObserve(page);
  const box = useRef<HTMLDivElement>(null);
  const field = useRef<HTMLInputElement>(null);
  const [address, setAddress] = useState(page.address);
  const [editing, setEditing] = useState(false);

  useEffect(() => {
    if (!editing) setAddress(page.address);
  }, [page.address, editing]);

  useEffect(() => {
    if (!page.address) field.current?.focus();
  }, [page]);

  // Every frame: follow the box and hide while it is off screen or covered. Each change crosses to the native side once.
  useEffect(() => {
    let frame = 0;
    const tick = () => {
      const el = box.current;
      const r = el?.getBoundingClientRect();
      const shown = !!el && !!r && el.offsetParent !== null && !document.hidden && r.width > 1 && r.height > 1 && !document.querySelector(overlays);
      page.place(shown && r ? { x: Math.round(r.left), y: Math.round(r.top), width: Math.round(r.width), height: Math.round(r.height) } : null);
      frame = requestAnimationFrame(tick);
    };
    tick();
    return () => {
      cancelAnimationFrame(frame);
      page.place(null);
    };
  }, [page]);

  const go = () => {
    page.open(address);
    setEditing(false);
    field.current?.blur();
    page.focus();
  };

  return (
    <div className="browser-pane" onMouseDownCapture={() => store.activeTerminalID !== page.id && store.selectBrowser(page)}>
      <div className="browser-bar">
        <IconButton small icon={<ArrowLeft size={14} />} aria-label={t("Back")} tip={t("Back")} onClick={() => page.back()} />
        <IconButton small icon={<ArrowRight size={14} />} aria-label={t("Forward")} tip={t("Forward")} onClick={() => page.forward()} />
        <IconButton small icon={<RotateCw size={13} />} aria-label={t("Reload")} tip={t("Reload")} onClick={() => page.reload()} />
        <input
          ref={field}
          className="browser-address"
          value={address}
          placeholder={t("Search or enter address")}
          aria-label={t("Search or enter address")}
          spellCheck={false}
          onFocus={(e) => {
            setEditing(true);
            e.currentTarget.select();
          }}
          onBlur={() => setEditing(false)}
          onChange={(e) => setAddress(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") go();
            else if (e.key === "Escape") {
              setAddress(page.address);
              e.currentTarget.blur();
            }
          }}
        />
        <IconButton small icon={<ExternalLink size={13} />} aria-label={t("Open in browser")} tip={t("Open in browser")} disabled={!page.address} onClick={() => page.openExternally()} />
      </div>
      <div ref={box} className="browser-page" />
    </div>
  );
}
