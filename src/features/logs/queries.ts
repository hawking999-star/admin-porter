import { supabase } from "@/lib/supabase";

/* ========================================================================== *
 * Logs — feed de diagnóstico da operação (dados reais do Supabase).
 * Une: mudanças de status, sessões, importações de músicas e eventos.
 * Todas as leituras dependem das policies is_admin() já existentes.
 * ========================================================================== */

export type LogLevel = "info" | "warning" | "error";
export type LogCategory = "sessao" | "status" | "importacao" | "evento";

export type LogEntry = {
  id: string;
  category: LogCategory;
  level: LogLevel;
  occurred_at: string;
  actor: string | null;
  title: string;
  detail: string | null;
};

export type LogFilters = {
  page: number;
  pageSize: number;
  search?: string;
  category?: LogCategory | "all";
  level?: LogLevel | "all";
  actor?: string;
  dateFrom?: string;
  dateTo?: string;
};

export type LogPage = {
  rows: LogEntry[];
  total: number;
};

export const LOG_CATEGORIES: { value: LogCategory | "all"; label: string }[] = [
  { value: "all", label: "Todas as categorias" },
  { value: "sessao", label: "Sessões" },
  { value: "status", label: "Status" },
  { value: "importacao", label: "Importações" },
  { value: "evento", label: "Eventos" },
];

export const LOG_LEVELS: { value: LogLevel | "all"; label: string }[] = [
  { value: "all", label: "Todos os níveis" },
  { value: "info", label: "Informação" },
  { value: "warning", label: "Aviso" },
  { value: "error", label: "Erro" },
];

const CATEGORY_PT: Record<LogCategory, string> = {
  sessao: "Sessão",
  status: "Status",
  importacao: "Importação",
  evento: "Evento",
};

export function categoryLabel(c: LogCategory): string {
  return CATEGORY_PT[c] ?? c;
}

/* ------------------------------- Helpers --------------------------------- */

const OP_STATUS_PT: Record<string, string> = {
  active: "Online",
  idle: "Ocioso",
  in_call: "Em atendimento",
  blocked: "Bloqueado",
  outside_shift: "Fora do turno",
  offline: "Offline",
};

function statusPT(s: string | null): string {
  return s ? OP_STATUS_PT[s] ?? s : "—";
}

function nameCap(n: string | null | undefined): string {
  if (!n) return "Operador";
  return n
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(" ");
}

export function fmtLogDate(iso: string): string {
  try {
    return new Date(iso).toLocaleString("pt-BR", {
      day: "2-digit",
      month: "2-digit",
      year: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

export function fmtLogRelative(iso: string): string {
  const mins = Math.floor((Date.now() - new Date(iso).getTime()) / 60_000);
  if (mins < 1) return "agora";
  if (mins < 60) return `há ${mins} min`;
  const h = Math.floor(mins / 60);
  if (h < 24) return `há ${h}h`;
  const d = Math.floor(h / 24);
  return `há ${d}d`;
}

const SESSION_PT: Record<string, { t: string; lvl: LogLevel }> = {
  active: { t: "iniciou uma sessão", lvl: "info" },
  ended: { t: "encerrou a sessão", lvl: "info" },
  expired: { t: "teve a sessão expirada", lvl: "warning" },
  revoked: { t: "teve a sessão revogada", lvl: "warning" },
};

const EVENT_PT: Record<string, string> = {
  "call.started": "Atendimento iniciado",
  "call.ended": "Atendimento encerrado",
  "session.started": "Sessão iniciada",
  "session.ended": "Sessão encerrada",
  "playlist.submitted": "Playlist enviada",
  "playlist.approved": "Playlist aprovada",
  "playlist.rejected": "Playlist rejeitada",
  "device.registered": "Dispositivo registrado",
  "operator.blocked": "Operador bloqueado",
};

const REASON_PT: Record<string, string> = {
  app_return: "Retorno pelo app",
  blocked: "Bloqueio operacional",
  duplicate_session: "Sessão duplicada",
  expired: "Sessão expirada",
  idle_timeout: "Tempo ocioso excedido",
  logout: "Logout",
  manual: "Ação manual",
  outside_shift: "Fora do turno",
  replaced_by_new_session: "Substituída por nova sessão",
  takeover: "Sessão assumida em outro dispositivo",
  timeout: "Tempo limite excedido",
};

const SOURCE_PT: Record<string, string> = {
  admin: "Painel administrativo",
  app: "App do operador",
  backend: "Backend",
  reconcile: "Reconciliação automática",
  system: "Sistema",
  worker: "Worker de importação",
};

function labelFromRegistry(value: string | null | undefined, registry: Record<string, string>): string | null {
  if (!value) return null;
  const normalized = value.toLowerCase();
  return registry[normalized] ?? null;
}

function eventLabel(value: string): string {
  return labelFromRegistry(value, EVENT_PT) ?? "Evento operacional";
}

function reasonLabel(value: string | null | undefined): string | null {
  if (!value) return null;
  return labelFromRegistry(value, REASON_PT) ?? "Motivo operacional";
}

function sourceLabel(value: string | null | undefined): string | null {
  if (!value) return null;
  return labelFromRegistry(value, SOURCE_PT) ?? "Origem operacional";
}

/* -------------------------------- Query ---------------------------------- */

function cleanTerm(value: string | undefined) {
  return value?.trim().replace(/[%,()]/g, "") ?? "";
}

function sourceRange(page: number, pageSize: number, sourceCount: number, singleSource: boolean) {
  const size = singleSource ? pageSize : Math.max(1, Math.ceil(pageSize / sourceCount));
  const from = Math.max(0, page - 1) * size;
  return { from, to: from + size - 1 };
}

function applyDateRange(query: any, column: string, filters: LogFilters) {
  let q = query;
  if (filters.dateFrom) q = q.gte(column, new Date(`${filters.dateFrom}T00:00:00`).toISOString());
  if (filters.dateTo) q = q.lte(column, new Date(`${filters.dateTo}T23:59:59`).toISOString());
  return q;
}

function actorMatches(entry: LogEntry, actor: string) {
  if (!actor) return true;
  return (entry.actor ?? "").toLowerCase().includes(actor.toLowerCase());
}

function levelMatches(entry: LogEntry, level: LogLevel | "all" | undefined) {
  return !level || level === "all" || entry.level === level;
}

function textMatches(entry: LogEntry, term: string) {
  if (!term) return true;
  const haystack = [entry.title, entry.detail, entry.actor, categoryLabel(entry.category), entry.level]
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  return haystack.includes(term.toLowerCase());
}

export async function fetchLogs(filters: LogFilters): Promise<LogPage> {
  const selectedSources =
    filters.category && filters.category !== "all"
      ? [filters.category]
      : (["status", "sessao", "importacao", "evento"] as LogCategory[]);
  const singleSource = selectedSources.length === 1;
  const range = sourceRange(filters.page, filters.pageSize, selectedSources.length, singleSource);
  const term = cleanTerm(filters.search);

  const requests = {
    status: selectedSources.includes("status")
      ? applyDateRange(
          supabase
            .from("operator_status_history")
            .select("id, from_status, to_status, reason_code, source, occurred_at, operators(display_name)", { count: "exact" })
            .order("occurred_at", { ascending: false }),
          "occurred_at",
          filters,
        )
          .or(term ? `from_status.ilike.%${term}%,to_status.ilike.%${term}%,reason_code.ilike.%${term}%,source.ilike.%${term}%` : "id.not.is.null")
          .range(range.from, range.to)
      : Promise.resolve({ data: [], error: null, count: 0 }),
    sessao: selectedSources.includes("sessao")
      ? applyDateRange(
          supabase
            .from("operator_sessions")
            .select("id, status, started_at, ended_at, end_reason, operators(display_name)", { count: "exact" })
            .order("started_at", { ascending: false }),
          "started_at",
          filters,
        )
          .or(term ? `status.ilike.%${term}%,end_reason.ilike.%${term}%` : "id.not.is.null")
          .range(range.from, range.to)
      : Promise.resolve({ data: [], error: null, count: 0 }),
    importacao: selectedSources.includes("importacao")
      ? applyDateRange(
          supabase
            .from("download_jobs")
            .select(
              "id, status, total, completed, failed, error_message, error_code, created_at, started_at, finished_at, last_error_at, playlists(name)",
              { count: "exact" },
            )
            .order("created_at", { ascending: false }),
          "created_at",
          filters,
        )
          .or(term ? `status.ilike.%${term}%,error_message.ilike.%${term}%,error_code.ilike.%${term}%` : "id.not.is.null")
          .range(range.from, range.to)
      : Promise.resolve({ data: [], error: null, count: 0 }),
    evento: selectedSources.includes("evento")
      ? applyDateRange(
          supabase
            .from("operational_events")
            .select("id, event_type, occurred_at, operators(display_name)", { count: "exact" })
            .order("occurred_at", { ascending: false }),
          "occurred_at",
          filters,
        )
          .or(term ? `event_type.ilike.%${term}%` : "id.not.is.null")
          .range(range.from, range.to)
      : Promise.resolve({ data: [], error: null, count: 0 }),
  };

  const [statuses, sessions, jobs, events] = await Promise.all([
    requests.status,
    requests.sessao,
    requests.importacao,
    requests.evento,
  ]);

  const error = statuses.error ?? sessions.error ?? jobs.error ?? events.error;
  if (error) throw error;

  const out: LogEntry[] = [];

  for (const s of statuses.data ?? []) {
    const who = nameCap((s as any).operators?.display_name);
    out.push({
      id: `st-${s.id}`,
      category: "status",
      level: s.to_status === "blocked" ? "warning" : "info",
      occurred_at: s.occurred_at,
      actor: who,
      title: `${who}: ${statusPT(s.from_status)} → ${statusPT(s.to_status)}`,
      detail: reasonLabel(s.reason_code)
        ? `Motivo: ${reasonLabel(s.reason_code)}`
        : sourceLabel(s.source)
          ? `Origem: ${sourceLabel(s.source)}`
          : null,
    });
  }

  for (const s of sessions.data ?? []) {
    const who = nameCap((s as any).operators?.display_name);
    const m = SESSION_PT[s.status] ?? { t: "atualizou a sessão", lvl: "info" as LogLevel };
    const when = s.status === "active" ? s.started_at : s.ended_at ?? s.started_at;
    out.push({
      id: `se-${s.id}`,
      category: "sessao",
      level: m.lvl,
      occurred_at: when,
      actor: who,
      title: `${who} ${m.t}`,
      detail: reasonLabel(s.end_reason) ? `Motivo: ${reasonLabel(s.end_reason)}` : null,
    });
  }

  for (const j of jobs.data ?? []) {
    const name = (j as any).playlists?.name ?? "playlist";
    let level: LogLevel = "info";
    let title = `Importação concluída: ${name}`;
    if (j.status === "error") {
      level = "error";
      title = `Falha na importação: ${name}`;
    } else if (j.status === "partial") {
      level = "warning";
      title = `Importação parcial: ${name}`;
    } else if (j.status === "running" || j.status === "queued") {
      title = `Importação em andamento: ${name}`;
    }
    const when = j.finished_at ?? j.last_error_at ?? j.started_at ?? j.created_at;
    const detail =
      j.error_message ??
      (j.total != null
        ? `${j.completed ?? 0}/${j.total} faixas${j.failed ? `, ${j.failed} falhas` : ""}`
        : null);
    out.push({ id: `jb-${j.id}`, category: "importacao", level, occurred_at: when, actor: null, title, detail });
  }

  for (const e of events.data ?? []) {
    const display = (e as any).operators?.display_name;
    out.push({
      id: `ev-${e.id}`,
      category: "evento",
      level: "info",
      occurred_at: e.occurred_at,
      actor: display ? nameCap(display) : null,
      title: eventLabel(e.event_type),
      detail: null,
    });
  }

  const rows = out
    .filter((x) => !!x.occurred_at)
    .filter((x) => levelMatches(x, filters.level))
    .filter((x) => textMatches(x, term))
    .filter((x) => actorMatches(x, cleanTerm(filters.actor)))
    .sort((a, b) => new Date(b.occurred_at).getTime() - new Date(a.occurred_at).getTime())
    .slice(0, filters.pageSize);

  return {
    rows,
    total: (statuses.count ?? 0) + (sessions.count ?? 0) + (jobs.count ?? 0) + (events.count ?? 0),
  };
}
