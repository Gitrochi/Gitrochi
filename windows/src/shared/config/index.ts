// shared/config 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { basename, dirname, displayPath, env, initEnv, isMac, isTemporaryPath, isWindows, joinPath, keyLabel, samePath, samePathKey, slash, toWslPath, wslDistroOf } from "./env";
export { addRecent, recents, removeRecent, settings } from "./settings";
