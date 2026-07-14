import { supabase } from "@/lib/supabase";
import { unitLabel } from "@/lib/unit-label";

/* ========================================================================== *
 * Visão Geral — agregações da operação (dados reais do Supabase).
 * Todas as leituras dependem das policies is_admin() já existentes.
 * Métricas opcionais fazem fallback seguro (null) sem quebrar a tela.
 * ========================================================================== */

/* ------------------------------- Datas ----------------------------------- */

function startOfTodayISO(): string {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

/** Minutos decorridos desde um ISO (ou null se sem data). */
export function minutesSince(iso: string | null): number | null {
  if (!iso) return null;
  return Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 60_000));
}

/** "há 48 min", "há 1h", "há 2h", "há 3d". */
export function fmtRelative(iso: string | null): string {
  if (!iso) return "—";
  const mins = minutesSince(iso) ?? 0;
  if (mins < 1) return "agora";
  if (mins < 60) return `há ${mins} min`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `há ${hrs}h`;
  const days = Math.floor(hrs / 24);
  return `há ${days}d`;
}

/** Tempo já decorrido dentro de um status: "12 min", "1h20", "2d". */
export function fmtDuration(iso: string | null): string {
  const mins = minutesSince(iso);
  if (mins === null) return "—";
  if (mins < 60) return `${mins} min`;
  const hrs = Math.floor(mins / 60);
  const rem = mins % 60;
  if (hrs < 24) return rem ? `${hrs}h${String(rem).padStart(2, "0")}` : `${hrs}h`;
  const days = Math.floor(hrs / 24);
  return `${days}d`;
}

/** Capitaliza nome próprio: "KARLOS EDUARDO" -> "Karlos Eduardo". */
export function capitalizeName(name: string | null | undefined): string {
  if (!name) return "Operador";
  return name
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .map((w) => (w.length <= 2 && /^(de|da|do|e)$/.test(w) ? w : w.charAt(0).toUpperCase() + w.slice(1)))
    .join(" ");
}

/* --------------------------- Status dos operadores ----------------------- */

export const STATUS_ORDER = [
  "active",
  "in_call",
  "idle",
  "blocked",
  "outside_shift",
  "offline",
] as const;

const STATUS_LABELS: Record<string, string> = {
  active: "Online",
  in_call: "Em atendimento",
  idle: "Ocioso",
  blocked: "Bloqueado",
  outside_shift: "Fora do turno",
  offline: "Offline",
};

export function statusLabel(s: string): string {
  return STATUS_LABELS[s] ?? s;
}

/** Ponto/ícone (texto) por status — tokens semânticos do design system. */
export const STATUS_DOT: Record<string, string> = {
  active: "text-success",
  in_call: "text-primary",
  idle: "text-warning",
  blocked: "text-destructive",
  outside_shift: "text-muted-foreground",
  offline: "text-muted-foreground/40",
};

/** Barra proporcional (fundo) por status. */
export const STATUS_BAR: Record<string, string> = {
  active: "bg-success",
  in_call: "bg-primary",
  idle: "bg-warning",
  blocked: "bg-destructive",
  outside_shift: "bg-muted-foreground/60",
  offline: "bg-muted-foreground/25",
};

export type OperatorStatusRow = {
  operator_id: string;
  status: string;
  display_name: string;
  unit_id: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  unit_label: string | null;
  effective_at: string | null;
  status_repetitions_today: number;
};

export type StatusGroup = { status: string; label: string; count: number };

export type OperatorStatesResult = {
  groups: StatusGroup[];
  rows: OperatorStatusRow[];
  total: number;
};

export async function fetchOperatorStates(): Promise<OperatorStatesResult> {
  const { data, error } = await supabase
    .from("operator_states")
    .select("operator_id, status, effective_at, operators(display_name, unit_id, units(id, name, city, state))")
    .order("effective_at", { ascending: false, nullsFirst: false })
    .limit(100);
  if (error) throw error;

  const rows: OperatorStatusRow[] = (data ?? []).map((r: any) => ({
    operator_id: r.operator_id,
    status: r.status,
    display_name: r.operators?.display_name ?? "—",
    unit_id: r.operators?.unit_id ?? r.operators?.units?.id ?? null,
    unit_name: r.operators?.units?.name ?? null,
    unit_city: r.operators?.units?.city ?? null,
    unit_state: r.operators?.units?.state ?? null,
    unit_label: r.operators?.units?.name
      ? unitLabel({ name: r.operators.units.name, city: r.operators.units.city, state: r.operators.units.state })
      : null,
    effective_at: r.effective_at ?? null,
    status_repetitions_today: 0,
  }));

  const repetitions = await fetchStatusRepetitions(rows.map((row) => row.operator_id));
  for (const row of rows) {
    row.status_repetitions_today = repetitions.get(`${row.operator_id}:${row.status}`) ?? 0;
  }

  const groups: StatusGroup[] = STATUS_ORDER.map((s) => ({
    status: s,
    label: statusLabel(s),
    count: rows.filter((r) => r.status === s).length,
  }));

  return { groups, rows, total: rows.length };
}

async function fetchStatusRepetitions(operatorIds: string[]): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  if (operatorIds.length === 0) return counts;

  const { data, error } = await supabase
    .from("operator_status_history")
    .select("operator_id, to_status")
    .in("operator_id", operatorIds)
    .in("to_status", ["idle", "in_call", "blocked", "offline"])
    .gte("occurred_at", startOfTodayISO())
    .limit(1000);

  if (error) return counts;

  for (const row of data ?? []) {
    const operatorId = (row as any).operator_id;
    const status = (row as any).to_status;
    if (!operatorId || !status) continue;
    const key = `${operatorId}:${status}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }

  return counts;
}

/* --------------------------- Operadores em atenção ----------------------- */

export type AttentionReason =
  | "blocked"
  | "idle"
  | "long_call"
  | "offline";

export type AttentionOperator = {
  operator_id: string;
  display_name: string;
  unit_name: string | null;
  unit_label: string | null;
  status: string;
  reason: AttentionReason;
  since: string | null;
  repetitions: number;
  severity: number; // menor = mais urgente
};

/** Minutos em atendimento a partir dos quais consideramos "longo". */
const LONG_CALL_MIN = 30;
const IDLE_ATTENTION_MIN = 10;
const MIN_ATTENTION_REPETITIONS = 3;

/** Deriva a lista de operadores que precisam de atenção a partir dos estados. */
export function deriveAttention(rows: OperatorStatusRow[]): AttentionOperator[] {
  const out: AttentionOperator[] = [];
  for (const r of rows) {
    if (r.status_repetitions_today < MIN_ATTENTION_REPETITIONS) continue;

    let reason: AttentionReason | null = null;
    let severity = 9;
    if (r.status === "blocked") {
      reason = "blocked";
      severity = 1;
    } else if (r.status === "in_call" && (minutesSince(r.effective_at) ?? 0) >= LONG_CALL_MIN) {
      reason = "long_call";
      severity = 2;
    } else if (r.status === "idle" && (minutesSince(r.effective_at) ?? 0) >= IDLE_ATTENTION_MIN) {
      reason = "idle";
      severity = 3;
    } else if (r.status === "offline") {
      reason = "offline";
      severity = 4;
    }
    if (!reason) continue;
    out.push({
      operator_id: r.operator_id,
      display_name: r.display_name,
      unit_name: r.unit_name,
      unit_label: r.unit_label,
      status: r.status,
      reason,
      since: r.effective_at,
      repetitions: r.status_repetitions_today,
      severity,
    });
  }
  return out
    .sort((a, b) => a.severity - b.severity || (minutesSince(b.since) ?? 0) - (minutesSince(a.since) ?? 0))
    .slice(0, 6);
}

export function attentionReasonLabel(a: AttentionOperator): string {
  switch (a.reason) {
    case "blocked":
      return "Bloqueado";
    case "long_call":
      return "Em atendimento prolongado";
    case "idle":
      return "Ocioso";
    case "offline":
      return "Offline";
  }
}

/* ------------------------------- Contagens ------------------------------- */

export type OverviewCounts = {
  operators: number;
  operatorsOnline: number;
  activeSessions: number;
  sessionsEndedToday: number;
  pendingFeedback: number;
  pendingPlaylists: number | null; // null = estrutura de aprovação indisponível
};

export async function fetchOverviewCounts(statisticsSince?: string): Promise<OverviewCounts> {
  const today = startOfTodayISO();
  const endedSince = statisticsSince && statisticsSince > today ? statisticsSince : today;
  const [operators, online, active, endedToday, feedback, playlists] = await Promise.all([
    supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", true),
    supabase.from("operator_states").select("operator_id", { count: "exact", head: true }).eq("status", "active"),
    supabase.from("operator_sessions").select("id", { count: "exact", head: true }).eq("status", "active"),
    supabase
      .from("operator_sessions")
      .select("id", { count: "exact", head: true })
      .eq("status", "ended")
      .gte("ended_at", endedSince),
    supabase.from("feedback").select("id", { count: "exact", head: true }).eq("status", "new"),
    supabase.from("playlists").select("id", { count: "exact", head: true }).eq("approval_status", "pending"),
  ]);

  return {
    operators: operators.count ?? 0,
    operatorsOnline: online.count ?? 0,
    activeSessions: active.count ?? 0,
    sessionsEndedToday: endedToday.count ?? 0,
    pendingFeedback: feedback.count ?? 0,
    pendingPlaylists: playlists.error ? null : playlists.count ?? 0,
  };
}

/* ---------------------------- Atividade recente -------------------------- */

export type ActivityKind = "session" | "feedback" | "playlist" | "audit";

export type RecentActivity = {
  id: string;
  kind: ActivityKind;
  title: string;
  detail: string | null;
  occurred_at: string;
};

const AUDIT_VERB: Record<string, string> = {
  insert: "cadastrou",
  create: "cadastrou",
  update: "atualizou",
  delete: "removeu",
  approve: "aprovou",
  reject: "rejeitou",
};

const ENTITY_PT: Record<string, string> = {
  operators: "um operador",
  operator: "um operador",
  units: "um condomínio",
  unit: "um condomínio",
  playlists: "uma playlist",
  playlist: "uma playlist",
  tracks: "uma música",
  challenges: "um desafio",
  feedback: "um feedback",
  devices: "um dispositivo",
};

function formatAudit(action: string, entity: string | null): string {
  const verb = AUDIT_VERB[action?.toLowerCase()] ?? "alterou";
  const ent = ENTITY_PT[(entity ?? "").toLowerCase()] ?? "um registro";
  return `${verb} ${ent}`;
}

function formatSession(status: string): string {
  switch (status) {
    case "active":
      return "iniciou uma sessão";
    case "ended":
      return "encerrou uma sessão";
    case "expired":
      return "teve a sessão expirada";
    case "revoked":
      return "teve a sessão revogada";
    default:
      return "atualizou a sessão";
  }
}

const FEEDBACK_TYPE_PT: Record<string, string> = {
  suggestion: "Sugestão",
  problem: "Problema",
  praise: "Elogio",
};

const PLAYLIST_TYPE_PT: Record<string, string> = {
  principal: "Playlist principal",
  secondary: "Playlist secundária",
};

export async function fetchRecentActivity(sinceAt: string, untilAt: string): Promise<RecentActivity[]> {
  const [audits, sessions, feedback, playlists] = await Promise.all([
    supabase
      .from("admin_audit_logs")
      .select("id, action, entity_type, occurred_at, admin_users(display_name)")
      .gte("occurred_at", sinceAt)
      .lte("occurred_at", untilAt)
      .order("occurred_at", { ascending: false })
      .limit(8),
    supabase
      .from("operator_sessions")
      .select("id, status, started_at, ended_at, operators(display_name)")
      .gte("started_at", sinceAt)
      .lte("started_at", untilAt)
      .order("started_at", { ascending: false })
      .limit(8),
    supabase
      .from("feedback")
      .select("id, type, created_at, operators(display_name)")
      .gte("created_at", sinceAt)
      .lte("created_at", untilAt)
      .order("created_at", { ascending: false })
      .limit(6),
    supabase
      .from("playlists")
      .select("id, name, type, approval_status, submitted_at, reviewed_at, operators(display_name)")
      .not("submitted_at", "is", null)
      .gte("submitted_at", sinceAt)
      .lte("submitted_at", untilAt)
      .order("submitted_at", { ascending: false })
      .limit(6),
  ]);

  const items: RecentActivity[] = [];

  for (const a of audits.data ?? []) {
    const who = capitalizeName((a as any).admin_users?.display_name ?? "Administrador");
    items.push({
      id: `audit-${a.id}`,
      kind: "audit",
      title: `${who} ${formatAudit(a.action, a.entity_type)}`,
      detail: null,
      occurred_at: a.occurred_at,
    });
  }

  for (const s of sessions.data ?? []) {
    const who = capitalizeName((s as any).operators?.display_name);
    const when = s.status === "active" ? s.started_at : s.ended_at ?? s.started_at;
    items.push({
      id: `sess-${s.id}`,
      kind: "session",
      title: `${who} ${formatSession(s.status)}`,
      detail: null,
      occurred_at: when,
    });
  }

  for (const f of feedback.data ?? []) {
    const who = capitalizeName((f as any).operators?.display_name);
    items.push({
      id: `fb-${f.id}`,
      kind: "feedback",
      title: `Feedback recebido de ${who}`,
      detail: FEEDBACK_TYPE_PT[(f as any).type] ?? null,
      occurred_at: (f as any).created_at,
    });
  }

  for (const p of playlists.data ?? []) {
    const who = capitalizeName((p as any).operators?.display_name);
    const label = PLAYLIST_TYPE_PT[(p as any).type] ?? "Playlist";
    let title: string;
    let when: string;
    if (p.approval_status === "approved") {
      title = `${label} aprovada`;
      when = (p as any).reviewed_at ?? (p as any).submitted_at;
    } else if (p.approval_status === "rejected") {
      title = `${label} rejeitada`;
      when = (p as any).reviewed_at ?? (p as any).submitted_at;
    } else {
      title = `${who} enviou uma playlist para aprovação`;
      when = (p as any).submitted_at;
    }
    items.push({
      id: `pl-${p.id}`,
      kind: "playlist",
      title,
      detail: (p as any).name ?? null,
      occurred_at: when,
    });
  }

  return items
    .filter((i) => !!i.occurred_at)
    .sort((a, b) => new Date(b.occurred_at).getTime() - new Date(a.occurred_at).getTime())
    .slice(0, 12);
}

/* ------------------------------ Resumo do dia ---------------------------- */

export type DailyMetric = { label: string; value: number | null };

/** Conta linhas de uma tabela desde o começo do dia; null se a query falhar. */
async function countSince(
  table: string,
  column: string,
  since: string,
  until: string,
  extra?: (q: any) => any,
): Promise<number | null> {
  try {
    let q = supabase.from(table).select("id", { count: "exact", head: true }).gte(column, since).lte(column, until);
    if (extra) q = extra(q);
    const { count, error } = await q;
    if (error) return null;
    return count ?? 0;
  } catch {
    return null;
  }
}

export async function fetchDailySummary(sinceAt: string, untilAt: string): Promise<DailyMetric[]> {
  const [started, ended, feedbackToday, idleToday, challengesToday, failures] = await Promise.all([
    countSince("operator_sessions", "started_at", sinceAt, untilAt),
    countSince("operator_sessions", "ended_at", sinceAt, untilAt, (q) => q.eq("status", "ended")),
    countSince("feedback", "created_at", sinceAt, untilAt),
    countSince("operator_status_history", "occurred_at", sinceAt, untilAt, (q) => q.eq("to_status", "idle")),
    countSince("challenge_logs", "answered_at", sinceAt, untilAt),
    countSince("download_jobs", "last_error_at", sinceAt, untilAt, (q) => q.eq("status", "error")),
  ]);

  return [
    { label: "Sessões iniciadas", value: started },
    { label: "Sessões encerradas", value: ended },
    { label: "Feedbacks recebidos", value: feedbackToday },
    { label: "Operadores ficaram ociosos", value: idleToday },
    { label: "Desafios respondidos", value: challengesToday },
    { label: "Falhas de importação", value: failures },
  ];
}
