import { describe, expect, it } from "vitest";
import { backupSize, DemoLedgerBackend, type LedgerBackend, LedgerError, type LedgerMethod, type LedgerMethods, LedgerStore, shownBackups } from "@/entities/ledger";

describe("backups to restore", () => {
  it("writes sizes in decimal units like macOS's file byte counts", () => {
    expect(backupSize(512, "en")).toBe("512 bytes");
    expect(backupSize(266_240, "en")).toBe("266 kB");
    expect(backupSize(4_718_592, "en")).toBe("4.7 MB");
    expect(backupSize(2_500_000_000, "en")).toBe("2.5 GB");
    expect(backupSize(266_240, "ko")).toContain("266");
  });

  it("lists the newest five until every backup is asked for", () => {
    const files = Array.from({ length: 8 }, (_, i) => i);
    expect(shownBackups(files, false)).toEqual([0, 1, 2, 3, 4]);
    expect(shownBackups(files, true)).toEqual(files);
    expect(shownBackups([1, 2], false)).toEqual([1, 2]);
  });

  it("the demo lists example backups and a safety copy but never restores", async () => {
    const demo = new DemoLedgerBackend({ empty: true, now: () => Date.UTC(2026, 10, 3, 12) });
    const { backups } = await demo.call("backups", {});
    expect(backups.map((b) => b.kind)).toEqual(["backup", "backup", "safety"]);
    expect(backups[0].modifiedAt).toBeGreaterThan(backups[1].modifiedAt);
    await expect(demo.call("restore", { path: backups[0].path })).rejects.toMatchObject({ code: "NOT_ALLOWED" });
  });

  it("a restore reads the restored ledger at once and forgets the selection", async () => {
    const demo = new DemoLedgerBackend({ empty: true });
    const calls: string[] = [];
    let rev = 1;
    const backend: LedgerBackend = {
      kind: "native",
      call: <M extends LedgerMethod>(method: M, args: LedgerMethods[M]["args"]): Promise<LedgerMethods[M]["result"]> => {
        calls.push(method);
        if (method === "backup") return Promise.resolve({ created: false, path: "", size: 0, removed: [] } as LedgerMethods[M]["result"]);
        if (method === "rev") return Promise.resolve({ rev } as LedgerMethods[M]["result"]);
        if (method === "restore") {
          const { path } = args as LedgerMethods["restore"]["args"];
          if (path.endsWith("newer.sqlite3")) return Promise.reject(new LedgerError("SCHEMA_MISMATCH", "written by a newer Gitrochi"));
          rev = 40;
          return Promise.resolve({ ok: true, dryRun: false, path, contents: { schema: 8, rev: 12, sessions: 3, events: 9 }, safety: { path: "backups/ledger-before-restore-20261103-120000.sqlite3", created: true, size: 4096, removed: [] }, rev } as LedgerMethods[M]["result"]);
        }
        return demo.call(method, args);
      },
    };
    const store = new LedgerStore(backend);
    await store.refresh(true);
    store.select("S1103-01");
    const result = await store.restore("backups/ledger-20261102-0930.sqlite3");
    expect(result.safety?.path).toContain("before-restore");
    expect(store.selectedId).toBeNull();
    expect(calls.lastIndexOf("state")).toBeGreaterThan(calls.indexOf("restore"));
    await expect(store.restore("backups/newer.sqlite3")).rejects.toMatchObject({ code: "SCHEMA_MISMATCH" });
    store.dispose();
  });
});
