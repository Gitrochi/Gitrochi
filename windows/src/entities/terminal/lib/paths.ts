import { toWslPath } from "@/shared/config";

/** A path typed into the shell: quoted when it has spaces or shell characters; a WSL shell gets /mnt/c/… (macOS: ShellView.shellEscape) */
export function shellPath(p: string, wsl: boolean): string {
  const path = wsl ? toWslPath(p) : p;
  return /[\s"'&|<>()^$`;]/.test(path) ? `"${path}"` : path;
}

/** A name for a pasted image: the clipboard gives every one "image.png" */
export function pastedImageName(file: { name: string; type: string }, at: Date, suffix = ""): string {
  if (file.name && file.name !== "image.png") return file.name;
  const stamp = at.toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
  const ext = file.type === "image/jpeg" ? "jpg" : file.type.startsWith("image/") ? file.type.slice(6) : "png";
  return `gitrochi-image-${stamp}${suffix}.${ext}`;
}
