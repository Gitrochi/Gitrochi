import { Check, ChevronRight } from "@/shared/icons";
import { type ReactNode, type RefObject, useEffect, useLayoutEffect, useRef, useState } from "react";
import { keyLabel } from "@/shared/config";
import { laneColor, Observable, stableHash, useObserve } from "@/shared/lib";
import "./styles.css";
// MARK: 기본 컨트롤

export function Spinner({ size = 14 }: { size?: number }) {
  return <span className="spinner" style={{ width: size, height: size }} />;
}

type BtnProps = React.ButtonHTMLAttributes<HTMLButtonElement> & {
  kind?: "default" | "primary" | "danger";
  size?: "small" | "large";
  block?: boolean;
  tip?: string;
};

export function Button({ kind = "default", size, block, tip, className = "", ...rest }: BtnProps) {
  return (
    <button
      type="button"
      data-tip={tip}
      className={`btn ${kind !== "default" ? kind : ""} ${size ?? ""} ${block ? "block" : ""} ${className}`}
      {...rest}
    />
  );
}

export function IconButton({
  icon,
  tip,
  small,
  className = "",
  ...rest
}: React.ButtonHTMLAttributes<HTMLButtonElement> & { icon: ReactNode; tip?: string; small?: boolean }) {
  return (
    <button type="button" data-tip={tip} className={`icon-btn ${small ? "small" : ""} ${className}`} {...rest}>
      {icon}
    </button>
  );
}

export function Segmented<T extends string>({
  value,
  options,
  onChange,
  stretch,
}: {
  value: T;
  options: { value: T; label: ReactNode; tip?: string }[];
  onChange: (v: T) => void;
  stretch?: boolean;
}) {
  return (
    <div className={`segmented ${stretch ? "stretch" : ""}`}>
      {options.map((o) => (
        <button key={o.value} type="button" data-tip={o.tip} className={o.value === value ? "on" : ""} onClick={() => onChange(o.value)}>
          {o.label}
        </button>
      ))}
    </div>
  );
}

export function Checkbox({ checked, onChange, label, disabled, tip }: { checked: boolean; onChange: (v: boolean) => void; label: ReactNode; disabled?: boolean; tip?: string }) {
  return (
    <label className="check" data-tip={tip} style={{ opacity: disabled ? 0.5 : 1 }}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)} />
      {label}
    </label>
  );
}

export function Card({ children, gap, className = "" }: { children: ReactNode; gap?: number; className?: string }) {
  return (
    <div className={`card ${className}`} style={gap !== undefined ? { gap } : undefined}>
      {children}
    </div>
  );
}

/** 작성자 이니셜 원형 아바타(네트워크 없이 이메일로 색을 고정) */
export function Avatar({ name, email, size = 28, url }: { name: string; email: string; size?: number; url?: string | null }) {
  const [broken, setBroken] = useState(false);
  const letter = (name.trim()[0] ?? "?").toUpperCase();
  return (
    <span className="avatar" style={{ width: size, height: size, background: laneColor(stableHash(email.toLowerCase())), fontSize: size * 0.45 }}>
      {url && !broken ? <img src={url} width={size} height={size} onError={() => setBroken(true)} alt="" /> : letter}
    </span>
  );
}


export function LineStatText({ added, deleted }: { added: number; deleted: number }) {
  return (
    <span className="linestat">
      {added > 0 && <span className="a">+{added}</span>}
      {deleted > 0 && <span className="d">−{deleted}</span>}
    </span>
  );
}

export function ChangeBar({ added, deleted, width = 80 }: { added: number; deleted: number; width?: number }) {
  const total = Math.max(1, added + deleted);
  return (
    <span className="changebar" style={{ width }}>
      <span style={{ width: (width * added) / total, background: "var(--green)" }} />
      <span style={{ width: (width * deleted) / total, background: "var(--red)" }} />
    </span>
  );
}

// MARK: 대화상자

/** Escape closes the topmost dialog only. `.modal-backdrop` is what marks an open dialog for the keyboard handlers. */
export function useDialogEscape(backdrop: RefObject<HTMLElement | null>, onClose: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        const dialogs = document.querySelectorAll(".modal-backdrop");
        if (dialogs[dialogs.length - 1] !== backdrop.current) return;
        if ((e.target as Element | null)?.closest?.('.code-editor[data-search-open="true"]')) return;
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [backdrop, onClose]);
}

export function Modal({
  title,
  children,
  footer,
  width = 500,
  onClose,
}: {
  title?: ReactNode;
  children?: ReactNode;
  footer?: ReactNode;
  width?: number;
  onClose: () => void;
}) {
  const backdrop = useRef<HTMLDivElement>(null);
  useDialogEscape(backdrop, onClose);
  return (
    <div ref={backdrop} className="modal-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="modal" style={{ width }} role="dialog">
        {title && <div className="modal-title">{title}</div>}
        {children && <div className="modal-body">{children}</div>}
        {footer && <div className="modal-footer">{footer}</div>}
      </div>
    </div>
  );
}

// MARK: 메뉴(우클릭·▾ 버튼)

export type MenuItem =
  | "divider"
  | {
      label: string;
      onClick?: () => void;
      disabled?: boolean;
      danger?: boolean;
      checked?: boolean;
      shortcut?: string;
      submenu?: MenuItem[];
      /** 마우스를 올리면 뜨는 설명(data-tip 형식) */
      tip?: string;
    };

class MenuState extends Observable {
  items: MenuItem[] | null = null;
  x = 0;
  y = 0;
  show(items: MenuItem[], x: number, y: number) {
    this.items = items.filter((it, i, a) => it !== "divider" || (i > 0 && i < a.length - 1 && a[i - 1] !== "divider"));
    this.x = x;
    this.y = y;
    this.emit();
  }
  hide() {
    if (!this.items) return;
    this.items = null;
    this.emit();
  }
}

export const menuState = new MenuState();

export function showContextMenu(e: React.MouseEvent, items: MenuItem[]) {
  e.preventDefault();
  e.stopPropagation();
  if (items.length) menuState.show(items, e.clientX, e.clientY);
}

export function showMenuBelow(el: HTMLElement, items: MenuItem[]) {
  const r = el.getBoundingClientRect();
  menuState.show(items, r.left, r.bottom + 4);
}

/** flipX: 하위 메뉴일 때 부모 메뉴의 왼쪽 끝 — 오른쪽에 자리가 없으면 부모를 덮지 않게 그 왼쪽으로 연다 */
function MenuList({ items, x, y, flipX, onDone }: { items: MenuItem[]; x: number; y: number; flipX?: number; onDone: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x, y });
  const [open, setOpen] = useState<number | null>(null);
  const [subPos, setSubPos] = useState({ x: 0, y: 0, flipX: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const r = el.getBoundingClientRect();
    const fits = x + r.width <= window.innerWidth - 6;
    const left = !fits && flipX != null ? flipX - r.width - 2 : x;
    setPos({
      x: Math.max(4, Math.min(left, window.innerWidth - r.width - 6)),
      y: Math.max(4, Math.min(y, window.innerHeight - r.height - 6)),
    });
  }, [x, y, flipX]);
  return (
    <>
      <div className="menu" ref={ref} style={{ left: pos.x, top: pos.y }} onMouseDown={(e) => e.stopPropagation()}>
        {items.map((it, i) =>
          it === "divider" ? (
            <div key={i} className="menu-sep" />
          ) : (
            <div
              key={i}
              className={`menu-item ${it.disabled ? "disabled" : ""} ${it.danger ? "danger" : ""} ${open === i ? "open" : ""}`}
              data-tip={it.tip}
              onMouseEnter={(e) => {
                if (it.submenu && !it.disabled) {
                  const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
                  setSubPos({ x: r.right + 2, y: r.top - 4, flipX: ref.current?.getBoundingClientRect().left ?? r.left });
                  setOpen(i);
                } else setOpen(null);
              }}
              onClick={() => {
                if (it.disabled || it.submenu) return;
                onDone();
                it.onClick?.();
              }}
            >
              <span className="check-mark">{it.checked ? <Check size={13} /> : null}</span>
              <span className="label">{it.label}</span>
              {it.shortcut && <span className="shortcut">{keyLabel(it.shortcut)}</span>}
              {it.submenu && <ChevronRight size={13} />}
            </div>
          ),
        )}
      </div>
      {open !== null && items[open] !== "divider" && (items[open] as { submenu?: MenuItem[] }).submenu && (
        <MenuList items={(items[open] as { submenu: MenuItem[] }).submenu} x={subPos.x} y={subPos.y} flipX={subPos.flipX} onDone={onDone} />
      )}
    </>
  );
}

export function MenuHost() {
  const m = useObserve(menuState);
  useEffect(() => {
    if (!m.items) return;
    const close = () => m.hide();
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("mousedown", close);
    window.addEventListener("blur", close);
    window.addEventListener("resize", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", close);
      window.removeEventListener("blur", close);
      window.removeEventListener("resize", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [m.items, m]);
  if (!m.items) return null;
  return <MenuList items={m.items} x={m.x} y={m.y} onDone={() => m.hide()} />;
}

// MARK: 마우스를 올리면 뜨는 설명(data-tip="제목|설명|단축키")

export function TooltipHost() {
  const [tip, setTip] = useState<{ text: string; x: number; y: number } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const current = useRef<Element | null>(null);
  useEffect(() => {
    const clear = () => {
      if (timer.current) clearTimeout(timer.current);
      timer.current = null;
      current.current = null;
      setTip(null);
    };
    const over = (e: MouseEvent) => {
      const el = (e.target as Element | null)?.closest?.("[data-tip]");
      if (el === current.current) return;
      clear();
      if (!el) return;
      const text = el.getAttribute("data-tip");
      if (!text) return;
      current.current = el;
      timer.current = setTimeout(() => {
        const r = el.getBoundingClientRect();
        setTip({ text, x: r.left + r.width / 2, y: r.bottom + 6 });
      }, 350);
    };
    window.addEventListener("mouseover", over);
    window.addEventListener("mousedown", clear);
    window.addEventListener("wheel", clear, { passive: true });
    window.addEventListener("keydown", clear);
    return () => {
      window.removeEventListener("mouseover", over);
      window.removeEventListener("mousedown", clear);
      window.removeEventListener("wheel", clear);
      window.removeEventListener("keydown", clear);
    };
  }, []);
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x: 0, y: 0 });
  useLayoutEffect(() => {
    if (!tip || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    let y = tip.y;
    if (y + r.height > window.innerHeight - 6) y = tip.y - r.height - 40;
    setPos({ x: Math.max(6, Math.min(tip.x - r.width / 2, window.innerWidth - r.width - 6)), y });
  }, [tip]);
  if (!tip) return null;
  const [title, detail, shortcut] = tip.text.split("|");
  return (
    <div className="tooltip" ref={ref} style={{ left: pos.x, top: pos.y }}>
      {detail !== undefined ? (
        <>
          <b>{title}</b>
          {shortcut && <span className="kbd">{keyLabel(shortcut)}</span>}
          {"\n"}
          {detail}
        </>
      ) : (
        title
      )}
    </div>
  );
}

/** data-tip 문자열 만들기: 제목 · 설명 · 단축키 */
export const tip = (title: string, detail?: string, shortcut?: string) => [title, detail ?? "", shortcut ?? ""].join("|").replace(/\|\|$/, "");

export function Empty({ title, detail, icon }: { title: string; detail?: string; icon?: ReactNode }) {
  return (
    <div className="empty">
      {icon}
      <div className="big">{title}</div>
      {detail && <div style={{ whiteSpace: "pre-line" }}>{detail}</div>}
    </div>
  );
}
