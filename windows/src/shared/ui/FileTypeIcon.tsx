import { Braces, Container, Database, File, FileArchive, FileCode, FileText, GitBranch, Image, Lock, Palette, Settings, SquareTerminal } from "lucide-react";
import { fileIcon, type FileIconKind } from "@/shared/lib";

const glyphs: Record<FileIconKind, typeof File> = {
  code: FileCode, style: Palette, json: Braces, config: Settings, markdown: FileText, text: FileText, sql: Database, shell: SquareTerminal,
  image: Image, archive: FileArchive, pdf: FileText, lock: Lock, git: GitBranch, docker: Container, file: File,
};

/** The file's type as a 13px glyph in its colour, grey when it has none (macOS: FileTypeIcon in Views/Shared/FileTypeIcon.swift) */
export function FileTypeIcon({ path, size = 13 }: { path: string; size?: number }) {
  const { kind, color } = fileIcon(path);
  const Glyph = glyphs[kind];
  return <Glyph className="file-type-icon" size={size} style={{ color: color ?? "var(--text-2)", flex: "none" }} aria-hidden="true" />;
}
