import { settings } from "@/shared/config";

/** Drags a column edge and stores the new width (the page list, and the repository screen's side columns) */
export const resizeColumn = (key: string, start: number, min: number, max: number, sign: 1 | -1) => (e: React.MouseEvent) => {
  e.preventDefault();
  const x0 = e.clientX;
  const move = (ev: MouseEvent) => settings.set(key, Math.min(max, Math.max(min, start + sign * (ev.clientX - x0))));
  const up = () => {
    window.removeEventListener("mousemove", move);
    window.removeEventListener("mouseup", up);
    document.body.style.cursor = "";
  };
  document.body.style.cursor = "col-resize";
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", up);
};
