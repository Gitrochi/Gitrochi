// entities/terminal 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { TerminalSession, type TerminalSpec } from "./model/terminal";
export { addTab, cornerPane, paneOf, panes, removeTab, selectTab, setRatio, shownIn, splitPane, type TermNode, type TermPane, type TermSplit } from "./lib/layout";
