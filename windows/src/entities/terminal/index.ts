// entities/terminal 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { TerminalSession, type TerminalSpec } from "./model/terminal";
export { BrowserSession } from "./model/browser";
export { isLocalHost, resolveAddress } from "./lib/browser-address";
export { addTab, cornerPane, paneOf, panes, removeTab, selectTab, setRatio, shownIn, splitPane, type TermNode, type TermPane, type TermSplit } from "./lib/layout";
export { pastedImageName, shellPath } from "./lib/paths";
export { activity, commandHintShown, commandsFolded, compactBar, railShown, sessionMark, sessionNeedsUser, sessionsNeedingUser, sessionWord, statusLine, tabActivity, tabMark, type TabMark, tabOverflow, tabStripWidth, type TerminalActivity } from "./lib/panel-layout";
export { TabMarkSlot } from "./ui/TabMarkSlot";
