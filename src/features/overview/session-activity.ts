export type ActivityKind = "session" | "feedback" | "playlist" | "audit";

export type RecentActivity = {
  id: string;
  kind: ActivityKind;
  title: string;
  detail: string | null;
  occurred_at: string;
};

export type SessionActivityRow = {
  id: string;
  status: string;
  started_at: string;
  ended_at: string | null;
  end_reason?: string | null;
  app_version?: string | null;
  operators?: { display_name?: string | null } | null;
};

function capitalizeName(name?: string | null): string {
  const normalized = name?.trim();
  if (!normalized) return "Operador";
  return normalized
    .toLocaleLowerCase("pt-BR")
    .split(/\s+/)
    .map((word) => (
      word.length <= 2 && /^(de|da|do|e)$/.test(word)
        ? word
        : word.charAt(0).toLocaleUpperCase("pt-BR") + word.slice(1)
    ))
    .join(" ");
}

function formatDuration(startedAt: string, endedAt: string): string | null {
  const started = new Date(startedAt).getTime();
  const ended = new Date(endedAt).getTime();
  if (!Number.isFinite(started) || !Number.isFinite(ended) || ended < started) return null;

  const minutes = Math.max(1, Math.round((ended - started) / 60_000));
  if (minutes < 60) return `${minutes} min`;

  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes > 0 ? `${hours}h ${remainingMinutes}min` : `${hours}h`;
}

function sessionDetail(session: SessionActivityRow, includeDuration: boolean): string | null {
  const parts: string[] = [];
  if (includeDuration && session.ended_at) {
    const duration = formatDuration(session.started_at, session.ended_at);
    if (duration) parts.push(`Duração: ${duration}`);
  }
  if (session.app_version) parts.push(`App v${session.app_version}`);
  return parts.length > 0 ? parts.join(" · ") : null;
}

function endTitle(session: SessionActivityRow, who: string): string {
  switch (session.end_reason) {
    case "operator_logout":
      return `Sessão de ${who} foi encerrada no App`;
    case "admin_stuck_call_recovery":
      return `Sessão de ${who} foi encerrada pelo Admin`;
    case "superseded_by_new_login":
      return `Sessão anterior de ${who} foi substituída por um novo login`;
    default:
      if (session.status === "expired") return `Sessão de ${who} expirou`;
      if (session.status === "revoked") return `Sessão de ${who} foi revogada`;
      return `Sessão de ${who} foi encerrada`;
  }
}

export function buildSessionActivityItems(
  startedSessions: SessionActivityRow[],
  endedSessions: SessionActivityRow[],
): RecentActivity[] {
  const items: RecentActivity[] = [];

  for (const session of startedSessions) {
    const who = capitalizeName(session.operators?.display_name);
    items.push({
      id: `sess-start-${session.id}`,
      kind: "session",
      title: `Sessão de ${who} foi iniciada`,
      detail: sessionDetail(session, false),
      occurred_at: session.started_at,
    });
  }

  for (const session of endedSessions) {
    if (!session.ended_at) continue;
    const who = capitalizeName(session.operators?.display_name);
    items.push({
      id: `sess-end-${session.id}`,
      kind: "session",
      title: endTitle(session, who),
      detail: sessionDetail(session, true),
      occurred_at: session.ended_at,
    });
  }

  return items;
}
