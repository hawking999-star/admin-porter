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
  registered_name: string;
  username: string | null;
  unit_id: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  unit_label: string | null;
  effective_at: string | null;
  call_started_at: string | null;
  block_count_today: number;
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
    .select("operator_id, status, effective_at, updated_at, call_started_at, operators(registered_name, username, unit_id, units(id, name, city, state))")
    .order("effective_at", { ascending: false, nullsFirst: false })
    .limit(100);
  if (error) throw error;

  const rows: OperatorStatusRow[] = (data ?? []).map((r: any) => ({
    operator_id: r.operator_id,
    status: r.status,
    registered_name: r.operators?.registered_name ?? "Operador",
    username: r.operators?.username ?? null,
    unit_id: r.operators?.unit_id ?? r.operators?.units?.id ?? null,
    unit_name: r.operators?.units?.name ?? null,
    unit_city: r.operators?.units?.city ?? null,
    unit_state: r.operators?.units?.state ?? null,
    unit_label: r.operators?.units?.name
      ? unitLabel({ name: r.operators.units.name, city: r.operators.units.city, state: r.operators.units.state })
      : null,
    effective_at: r.effective_at ?? r.updated_at ?? null,
    call_started_at: r.call_started_at ?? null,
    block_count_today: 0,
  }));

  const blockActivity = await fetchBlockActivity(rows.map((row) => row.operator_id));
  for (const row of rows) {
    const activity = blockActivity.get(row.operator_id);
    row.block_count_today = activity?.count ?? 0;
  }

  const groups: StatusGroup[] = STATUS_ORDER.map((s) => ({
    status: s,
    label: statusLabel(s),
    count: rows.filter((r) => r.status === s).length,
  }));

  return { groups, rows, total: rows.length };
}

type BlockActivity = {
  count: number;
};

async function fetchBlockActivity(operatorIds: string[]): Promise<Map<string, BlockActivity>> {
  const activity = new Map<string, BlockActivity>();
  if (operatorIds.length === 0) return activity;

  const { data, error } = await supabase
    .from("operator_blocks")
    .select("operator_id, started_at")
    .in("operator_id", operatorIds)
    .gte("started_at", startOfTodayISO())
    .order("started_at", { ascending: false })
    .limit(5000);

  if (error) throw error;

  for (const row of data ?? []) {
    const operatorId = (row as any).operator_id;
    if (!operatorId) continue;
    const current = activity.get(operatorId);
    activity.set(operatorId, {
      count: (current?.count ?? 0) + 1,
    });
  }

  return activity;
}

/* --------------------------- Operadores em atenção ----------------------- */

export type AttentionReason =
  | "long_call"
  | "idle"
  | "repeated_blocks";

export type AttentionOperator = {
  operator_id: string;
  registered_name: string;
  username: string | null;
  unit_name: string | null;
  unit_label: string | null;
  status: string;
  reasons: AttentionReason[];
  since: string | null;
  block_count_today: number;
  severity: number; // menor = mais urgente
};

/** Minutos em atendimento a partir dos quais consideramos "longo". */
const LONG_CALL_MIN = 10;
const IDLE_ATTENTION_MIN = 60;
const BLOCK_ATTENTION_COUNT = 5;

/** Deriva a lista de operadores que precisam de atenção a partir dos estados. */
export function deriveAttention(rows: OperatorStatusRow[]): AttentionOperator[] {
  const out: AttentionOperator[] = [];
  for (const r of rows) {
    const statusStartedAt = r.status === "in_call" ? r.call_started_at ?? r.effective_at : r.effective_at;
    const elapsedMinutes = minutesSince(statusStartedAt) ?? 0;
    const reasons: AttentionReason[] = [];

    if (r.status === "in_call" && elapsedMinutes >= LONG_CALL_MIN) reasons.push("long_call");
    if (r.status === "idle" && elapsedMinutes >= IDLE_ATTENTION_MIN) reasons.push("idle");
    if (r.block_count_today >= BLOCK_ATTENTION_COUNT) reasons.push("repeated_blocks");
    if (reasons.length === 0) continue;

    const severity = reasons.includes("long_call") ? 1 : reasons.includes("idle") ? 2 : 3;
    out.push({
      operator_id: r.operator_id,
      registered_name: r.registered_name,
      username: r.username,
      unit_name: r.unit_name,
      unit_label: r.unit_label,
      status: r.status,
      reasons,
      since: reasons.includes("long_call") || reasons.includes("idle") ? statusStartedAt : null,
      block_count_today: r.block_count_today,
      severity,
    });
  }
  return out
    .sort(
      (a, b) =>
        a.severity - b.severity ||
        (minutesSince(b.since) ?? 0) - (minutesSince(a.since) ?? 0) ||
        b.block_count_today - a.block_count_today,
    );
}

export function attentionReasonLabel(a: AttentionOperator): string {
  return a.reasons
    .map((reason) => {
      switch (reason) {
        case "long_call":
          return `Em atendimento há ${fmtDuration(a.since)}`;
        case "idle":
          return `Ocioso há ${fmtDuration(a.since)}`;
        case "repeated_blocks":
          return `${a.block_count_today} bloqueios hoje`;
      }
    })
    .join(" · ");
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

export type OverviewPendingAction = {
  id: string;
  kind: "playlist" | "feedback";
  title: string;
  operator_name: string | null;
  unit_label: string | null;
  occurred_at: string;
};

export type OverviewImportHealth = {
  queued: number;
  running: number;
  with_errors: number;
  last_activity_at: string | null;
};

export type OverviewActionCenter = {
  oldest_playlist: OverviewPendingAction | null;
  oldest_feedback: OverviewPendingAction | null;
  imports: OverviewImportHealth;
};

export async function fetchOverviewCounts(statisticsSince?: string, unitId?: string): Promise<OverviewCounts> {
  const today = startOfTodayISO();
  const endedSince = statisticsSince && statisticsSince > today ? statisticsSince : today;

  let operatorsQuery = supabase.from("operators").select("id", { count: "exact", head: true }).eq("active", true);
  let onlineQuery = supabase
    .from("operator_states")
    .select("operator_id, operators!inner(unit_id)", { count: "exact", head: true })
    .eq("status", "active");
  let activeQuery = supabase.from("operator_sessions").select("id", { count: "exact", head: true }).eq("status", "active");
  let endedQuery = supabase
    .from("operator_sessions")
    .select("id", { count: "exact", head: true })
    .eq("status", "ended")
    .gte("ended_at", endedSince);
  let feedbackQuery = supabase.from("feedback").select("id", { count: "exact", head: true }).eq("status", "new");
  let playlistsQuery = supabase.from("playlists").select("id", { count: "exact", head: true }).eq("approval_status", "pending");

  if (unitId) {
    operatorsQuery = operatorsQuery.eq("unit_id", unitId);
    onlineQuery = onlineQuery.eq("operators.unit_id", unitId);
    activeQuery = activeQuery.eq("unit_id", unitId);
    endedQuery = endedQuery.eq("unit_id", unitId);
    feedbackQuery = feedbackQuery.eq("unit_id", unitId);
    playlistsQuery = playlistsQuery.eq("unit_id", unitId);
  }

  const [operators, online, active, endedToday, feedback, playlists] = await Promise.all([
    operatorsQuery,
    onlineQuery,
    activeQuery,
    endedQuery,
    feedbackQuery,
    playlistsQuery,
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

/**
 * Carrega somente os itens necessários para priorizar o trabalho do Admin.
 * As contagens completas continuam em fetchOverviewCounts; aqui buscamos o item
 * mais antigo de cada fila e a saúde agregada do importador.
 */
export async function fetchOverviewActionCenter(unitId?: string): Promise<OverviewActionCenter> {
  let playlistQuery = supabase
    .from("playlists")
    .select("id, name, submitted_at, operators(display_name), units(name, city, state)")
    .eq("approval_status", "pending")
    .not("submitted_at", "is", null)
    .order("submitted_at", { ascending: true })
    .limit(1);
  let feedbackQuery = supabase
    .from("feedback")
    .select("id, message, created_at, operators(display_name), units(name, city, state)")
    .eq("status", "new")
    .order("created_at", { ascending: true })
    .limit(1);

  if (unitId) {
    playlistQuery = playlistQuery.eq("unit_id", unitId);
    feedbackQuery = feedbackQuery.eq("unit_id", unitId);
  }

  const [playlistResult, feedbackResult, integrationResult] = await Promise.all([
    playlistQuery.maybeSingle(),
    feedbackQuery.maybeSingle(),
    supabase.rpc("admin_integration_status"),
  ]);

  const error = playlistResult.error ?? feedbackResult.error ?? integrationResult.error;
  if (error) throw error;

  const playlist = playlistResult.data as any;
  const feedback = feedbackResult.data as any;
  const integration = (integrationResult.data ?? {}) as any;
  const imports = integration.imports ?? {};
  const contextLabel = (units: any) =>
    units?.name
      ? unitLabel({ name: units.name, city: units.city, state: units.state })
      : null;

  return {
    oldest_playlist: playlist
      ? {
          id: playlist.id,
          kind: "playlist",
          title: playlist.name?.trim() || "Playlist sem nome",
          operator_name: playlist.operators?.display_name ?? null,
          unit_label: contextLabel(playlist.units),
          occurred_at: playlist.submitted_at,
        }
      : null,
    oldest_feedback: feedback
      ? {
          id: feedback.id,
          kind: "feedback",
          title: feedback.message?.trim() || "Feedback sem mensagem",
          operator_name: feedback.operators?.display_name ?? null,
          unit_label: contextLabel(feedback.units),
          occurred_at: feedback.created_at,
        }
      : null,
    imports: {
      queued: Number(imports.queued ?? 0),
      running: Number(imports.running ?? 0),
      with_errors: Number(imports.with_errors ?? 0),
      last_activity_at: imports.last_activity_at ?? null,
    },
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

export async function fetchRecentActivity(sinceAt: string, untilAt: string, unitId?: string): Promise<RecentActivity[]> {
  const auditsQuery = unitId
    ? Promise.resolve({ data: [] as any[], error: null })
    : supabase
        .from("admin_audit_logs")
        .select("id, action, entity_type, occurred_at, admin_users(display_name)")
        .gte("occurred_at", sinceAt)
        .lte("occurred_at", untilAt)
        .order("occurred_at", { ascending: false })
        .limit(8);
  let sessionsQuery = supabase
    .from("operator_sessions")
    .select("id, status, started_at, ended_at, operators!inner(display_name, unit_id)")
    .gte("started_at", sinceAt)
    .lte("started_at", untilAt)
    .order("started_at", { ascending: false })
    .limit(8);
  let feedbackQuery = supabase
    .from("feedback")
    .select("id, type, created_at, operators(display_name)")
    .gte("created_at", sinceAt)
    .lte("created_at", untilAt)
    .order("created_at", { ascending: false })
    .limit(6);
  let playlistsQuery = supabase
    .from("playlists")
    .select("id, name, type, approval_status, submitted_at, reviewed_at, operators(display_name)")
    .not("submitted_at", "is", null)
    .gte("submitted_at", sinceAt)
    .lte("submitted_at", untilAt)
    .order("submitted_at", { ascending: false })
    .limit(6);

  if (unitId) {
    sessionsQuery = sessionsQuery.eq("operators.unit_id", unitId);
    feedbackQuery = feedbackQuery.eq("unit_id", unitId);
    playlistsQuery = playlistsQuery.eq("unit_id", unitId);
  }

  const [audits, sessions, feedback, playlists] = await Promise.all([
    auditsQuery,
    sessionsQuery,
    feedbackQuery,
    playlistsQuery,
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
  selectColumns = "id",
): Promise<number | null> {
  try {
    let q = supabase.from(table).select(selectColumns, { count: "exact", head: true }).gte(column, since).lte(column, until);
    if (extra) q = extra(q);
    const { count, error } = await q;
    if (error) return null;
    return count ?? 0;
  } catch {
    return null;
  }
}

export async function fetchDailySummary(sinceAt: string, untilAt: string, unitId?: string): Promise<DailyMetric[]> {
  const directUnit = (q: any) => (unitId ? q.eq("unit_id", unitId) : q);
  const operatorUnit = (q: any) => (unitId ? q.eq("operators.unit_id", unitId) : q);
  const playlistUnit = (q: any) => (unitId ? q.eq("playlists.unit_id", unitId) : q);
  const [started, ended, feedbackToday, idleToday, challengesToday, failures] = await Promise.all([
    countSince("operator_sessions", "started_at", sinceAt, untilAt, directUnit),
    countSince("operator_sessions", "ended_at", sinceAt, untilAt, (q) => directUnit(q.eq("status", "ended"))),
    countSince("feedback", "created_at", sinceAt, untilAt, directUnit),
    countSince("operator_status_history", "occurred_at", sinceAt, untilAt, (q) => operatorUnit(q.eq("to_status", "idle")), "id, operators!inner(unit_id)"),
    countSince("challenge_logs", "answered_at", sinceAt, untilAt, operatorUnit, "id, operators!inner(unit_id)"),
    countSince("download_jobs", "last_error_at", sinceAt, untilAt, (q) => playlistUnit(q.eq("status", "error")), "id, playlists!inner(unit_id)"),
  ]);

  return [
    { label: "Sessões iniciadas", value: started },
    { label: "Sessões encerradas", value: ended },
    { label: "Feedbacks recebidos", value: feedbackToday },
    { label: "Entradas em ociosidade", value: idleToday },
    { label: "Desafios respondidos", value: challengesToday },
    { label: "Falhas de importação", value: failures },
  ];
}
