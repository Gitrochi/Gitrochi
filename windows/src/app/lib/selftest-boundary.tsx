import { Component, type ErrorInfo, type ReactNode } from "react";
import { selfTestRecorder } from "./selftest-report";

/** React 18 reports uncaught render errors through a boundary, not a root callback. */
export class SelfTestBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };

  static getDerivedStateFromError() { return { failed: true }; }

  componentDidCatch(error: Error, info: ErrorInfo) {
    const detail = new Error(`${error.stack ?? error.message}\n${info.componentStack ?? ""}`);
    void selfTestRecorder()?.fail(detail).catch(console.error);
  }

  render() { return this.state.failed ? <pre>Self-test render failed. See selftest-result.json.</pre> : this.props.children; }
}
