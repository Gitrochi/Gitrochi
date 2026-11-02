/** Retain a missing selection so refreshing never implicitly chooses a new session. */
export function sessionSelection(sessions, project, selected, connected) {
  const available = sessions.filter((session) => session.project === project.trim());
  const missing = Boolean(selected && !available.some((session) => session.id === selected));
  return { available, selected, missing, unavailable: missing && !connected };
}
