import { describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import { RepositoryConfirmationGuard } from "../src/entities/repo/lib/confirmation-guard";
import { RepoStore } from "../src/entities/repo";

describe("repository confirmation lifetime", () => {
  it("runs a confirmed operation exactly once even when called twice before completion", async () => {
    const guard = new RepositoryConfirmationGuard(), operation = vi.fn(async () => {}), action = guard.wrap("repo", () => "repo", operation);
    await Promise.all([action(), action()]); expect(operation).toHaveBeenCalledTimes(1);
  });
  it("cancels a callback retained after switching repositories", async () => {
    const guard = new RepositoryConfirmationGuard(), operation = vi.fn(); let path = "first";
    const action = guard.wrap(path, () => path, operation); path = "second";
    await action(); expect(operation).not.toHaveBeenCalled();
  });
  it("cancels callbacks retained after reopening the same path", async () => {
    const guard = new RepositoryConfirmationGuard(), operation = vi.fn(), old = guard.wrap("repo", () => "repo", operation);
    guard.invalidate(); await old(); expect(operation).not.toHaveBeenCalled();
    await guard.wrap("repo", () => "repo", operation)(); expect(operation).toHaveBeenCalledTimes(1);
  });
  it("does not retry a failed destructive operation on a repeated click", async () => {
    const guard = new RepositoryConfirmationGuard(), operation = vi.fn(async () => { throw new Error("failed"); }), action = guard.wrap("repo", () => "repo", operation);
    await expect(action()).rejects.toThrow("failed"); await action(); expect(operation).toHaveBeenCalledTimes(1);
  });
  it("protects direct store assignments and ask() through the same setter", async () => {
    const store = new RepoStore(), direct = vi.fn(), asked = vi.fn(); store.path = "first";
    store.confirm = { title: "Delete", message: "Fixture", actionTitle: "Delete", action: direct };
    const old = store.confirm; store.path = "second"; await old?.action(); expect(direct).not.toHaveBeenCalled();
    store.ask({ title: "Delete", message: "Fixture", actionTitle: "Delete", action: asked });
    const current = store.confirm; await current?.action(); await current?.action(); expect(asked).toHaveBeenCalledTimes(1);
  });
  it("invalidates retained store confirmations on a full reset at the same path", async () => {
    const store = new RepoStore(), operation = vi.fn(); store.path = "repo";
    store.confirm = { title: "Delete", message: "Fixture", actionTitle: "Delete", action: operation };
    const old = store.confirm;
    (store as unknown as { resetState(): void }).resetState();
    store.path = "repo"; await old?.action(); expect(operation).not.toHaveBeenCalled(); expect(store.confirm).toBeNull();
  });
});
