import { changeId, type FileChange, fileName } from "../model/types";

export type TreeRow = { id: string; depth: number } & ({ kind: "folder"; path: string; name: string; files: FileChange[] } | { kind: "file"; change: FileChange });

interface Node {
  dirs: Map<string, Node>;
  files: FileChange[];
}

const natural = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true, sensitivity: "base" });

/** 경로를 폴더 트리로 펼친 행. 파일 없이 폴더 하나만 든 폴더는 한 줄로 합친다(src/main/java). macOS: FileTree.rows */
export function treeRows(changes: FileChange[], collapsed: Set<string>): TreeRow[] {
  const root: Node = { dirs: new Map(), files: [] };
  for (const c of changes) {
    let node = root;
    for (const dir of c.path.split("/").slice(0, -1)) {
      if (!node.dirs.has(dir)) node.dirs.set(dir, { dirs: new Map(), files: [] });
      node = node.dirs.get(dir)!;
    }
    node.files.push(c);
  }
  const allFiles = (n: Node): FileChange[] => [...n.files, ...[...n.dirs.values()].flatMap(allFiles)];
  const out: TreeRow[] = [];
  const emit = (n: Node, prefix: string, depth: number) => {
    for (const name of [...n.dirs.keys()].sort(natural)) {
      let child = n.dirs.get(name)!;
      let label = name;
      let path = prefix ? prefix + "/" + name : name;
      while (!child.files.length && child.dirs.size === 1) {
        const [k, v] = [...child.dirs.entries()][0];
        label += "/" + k;
        path += "/" + k;
        child = v;
      }
      out.push({ id: "d:" + path, depth, kind: "folder", path, name: label, files: allFiles(child) });
      if (!collapsed.has(path)) emit(child, path, depth + 1);
    }
    for (const f of [...n.files].sort((a, b) => natural(fileName(a.path), fileName(b.path)))) out.push({ id: "f:" + changeId(f), depth, kind: "file", change: f });
  };
  emit(root, "", 0);
  return out;
}
