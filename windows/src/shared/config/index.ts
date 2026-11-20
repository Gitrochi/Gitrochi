// shared/config 의 공개 API — 다른 조각은 이 파일로만 가져온다
export { basename, dirname, displayPath, env, fromWslPath, initEnv, isMac, isTemporaryPath, isWindows, joinPath, keyLabel, samePath, samePathKey, slash, toWslPath, wslDistroOf } from "./env";
export { addRecent, keepRunningInBackground, recentOpened, recents, removeRecent, setKeepRunningInBackground, settings } from "./settings";
