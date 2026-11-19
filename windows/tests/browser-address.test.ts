import { describe, expect, it } from "vitest";
import { isLocalHost, resolveAddress, searchURL } from "../src/entities/terminal/lib/browser-address";

describe("browser tab address bar", () => {
  it("opens dev servers over plain http", () => {
    expect(resolveAddress("localhost:3000")).toBe("http://localhost:3000");
    expect(resolveAddress("127.0.0.1:8080/api?x=1")).toBe("http://127.0.0.1:8080/api?x=1");
    expect(resolveAddress("app.localhost")).toBe("http://app.localhost");
    expect(resolveAddress("192.168.0.10")).toBe("http://192.168.0.10");
    expect(isLocalHost("[::1]:5173")).toBe(true);
  });
  it("opens names with a dot over https and keeps full addresses", () => {
    expect(resolveAddress("example.com")).toBe("https://example.com");
    expect(resolveAddress("example.com:8443/docs")).toBe("https://example.com:8443/docs");
    expect(resolveAddress(" https://example.com/a ")).toBe("https://example.com/a");
    expect(resolveAddress("about:blank")).toBe("about:blank");
  });
  it("searches anything else", () => {
    expect(resolveAddress("git rebase onto")).toBe(searchURL + "git%20rebase%20onto");
    expect(resolveAddress("readme")).toBe(searchURL + "readme");
    expect(resolveAddress("file:///etc/passwd")).toBe(searchURL + encodeURIComponent("file:///etc/passwd"));
    expect(resolveAddress("a..b")).toBe(searchURL + "a..b");
    expect(resolveAddress("   ")).toBeNull();
  });
});
