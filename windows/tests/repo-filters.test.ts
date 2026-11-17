import { afterEach, describe, expect, it, vi } from "vitest";
vi.hoisted(() => vi.stubGlobal("matchMedia", () => ({ matches: false, addEventListener() {}, removeEventListener() {} })));
vi.mock("@/entities/terminal", () => ({ TerminalSession: class {} }));
import type { Branch, Tag } from "@/entities/git";
import { RepoStore } from "@/entities/repo";
import { settings } from "@/shared/config";

// The graph's filters on the store: pins and hidden refs per repository (macOS: RepoStore+Filters.swift)
const branch = (name: string, isRemote = false): Branch => ({ name, target: "c-" + name, upstream: null, ahead: 0, behind: 0, upstreamGone: false, isCurrent: false, isRemote });
const tag = (name: string, target = "c-" + name): Tag => ({ name, target });
const internals = (store: RepoStore) => store as unknown as { logScope: string[]; loadGraphFilters(): void };

/** Settings kept in memory, so nothing reaches the settings file */
function memorySettings() {
  const memory = new Map<string, unknown>();
  vi.spyOn(settings, "get").mockImplementation(<T,>(key: string, fallback: T) => (memory.has(key) ? memory.get(key) : fallback) as T);
  vi.spyOn(settings, "set").mockImplementation((key: string, value: unknown) => {
    if (value === undefined) memory.delete(key);
    else memory.set(key, value);
  });
  return memory;
}

function openStore() {
  const store = new RepoStore();
  store.path = "/repo";
  internals(store).loadGraphFilters();
  return store;
}

afterEach(() => vi.restoreAllMocks());

describe("pins", () => {
  it("keep the local branches pinned before remotes and tags could be, and nothing else of their names", () => {
    const memory = memorySettings();
    memory.set("pinnedBranches", { "/repo": ["main", "v1.0"] });
    const store = openStore();
    expect(store.isPinned(branch("main")) && store.isPinned(branch("v1.0"))).toBe(true);
    expect(store.isPinned(branch("origin/main", true)) || store.isTagPinned(tag("v1.0")) || store.isTagPinned(tag("main"))).toBe(false);
  });

  it("pin a local branch, a remote branch and a tag of one name apart, and store each where it belongs", () => {
    const memory = memorySettings();
    const store = openStore();
    store.setPinned(branch("main"), true);
    store.setPinned(branch("origin/main", true), true);
    store.setTagPinned(tag("main"), true);
    expect(memory.get("pinnedBranches")).toEqual({ "/repo": ["main"] });
    expect(memory.get("pinnedRefs")).toEqual({ "/repo": ["refs/remotes/origin/main", "refs/tags/main"] });
    store.setPinned(branch("main"), false);
    expect(store.isPinned(branch("main"))).toBe(false);
    expect(store.isPinned(branch("origin/main", true)) && store.isTagPinned(tag("main"))).toBe(true);
    expect(memory.get("pinnedBranches")).toEqual({});
    // a repository opened again reads the same pins
    const again = openStore();
    expect([...again.pinnedRefs].sort()).toEqual(["refs/remotes/origin/main", "refs/tags/main"]);
  });
});

describe("hidden tags", () => {
  it("leave the log scope and the graph's chips at once, apart from a branch of their name, and come back with the branches", async () => {
    const memory = memorySettings();
    const store = openStore();
    const reload = vi.spyOn(store, "reload").mockResolvedValue(undefined);
    store.headBranch = "main";
    store.headHash = "c-main";
    store.localBranches = [branch("main"), branch("v1.0")];
    store.tags = [tag("v1.0", "c-main"), tag("v2.0")];
    const chips = (target: string) => store.refsByCommit.get(target)?.map((r) => `${r.kind}:${r.name}`) ?? [];

    await store.setTagHidden(tag("v1.0", "c-main"), true);
    expect(internals(store).logScope).toEqual(["--exclude=refs/tags/v1.0", "--exclude=refs/stash", "--all"]);
    expect(memory.get("graphHiddenRefs")).toEqual({ "/repo": ["refs/tags/v1.0"] });
    // the commits other refs reach stay, so the reload may keep the walk; the chip has gone already
    expect(chips("c-main")).toEqual(["local:main"]);
    expect(chips("c-v1.0")).toEqual(["local:v1.0"]);
    expect(chips("c-v2.0")).toEqual(["tag:v2.0"]);
    expect(store.isTagHidden(tag("v1.0")) && !store.isHidden(branch("v1.0"))).toBe(true);
    expect(reload).toHaveBeenCalledTimes(1);

    await store.setHidden(branch("v1.0"), true);
    expect(internals(store).logScope).toEqual(["--exclude=refs/heads/v1.0", "--exclude=refs/tags/v1.0", "--exclude=refs/stash", "--all"]);
    expect(chips("c-v1.0")).toEqual([]);

    await store.showAllBranches();
    expect(internals(store).logScope).toEqual(["--exclude=refs/stash", "--all"]);
    expect(chips("c-main")).toEqual(["local:main", "tag:v1.0"]);
    expect(store.isTagHidden(tag("v1.0"))).toBe(false);
    expect(memory.get("graphHiddenRefs")).toEqual({});
  });
});
