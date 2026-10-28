// Git reads GIT_CONFIG_PARAMETERS after indexed runtime configuration. A final
// literal override also reaches child processes without changing user settings.
const readOnlyGraphScript = 'export GIT_CONFIG_PARAMETERS="${GIT_CONFIG_PARAMETERS:+$GIT_CONFIG_PARAMETERS }\'core.fsmonitor=false\'"\nexec "$0" "$@"';

/** Preserve inherited configuration and pass all command arguments without evaluation. */
export function readOnlyGraphArguments(bash: string, executable: string, args: readonly string[]): string[] {
  const portable = (path: string) => /^[a-z]:[\\/]/i.test(path) ? path.replaceAll("\\", "/") : path;
  return ["-c", readOnlyGraphScript, portable(bash), portable(executable), ...args];
}
