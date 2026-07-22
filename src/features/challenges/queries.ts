import { supabase } from "@/lib/supabase";

export type PaginatedResult<T> = {
  rows: T[];
  total: number;
};

export type PageParams = {
  page: number;
  pageSize: number;
};

/* -------------------------------- Rótulos -------------------------------- */

export const CHALLENGE_STATUSES = [
  { value: "draft", label: "Rascunho" },
  { value: "active", label: "Ativo" },
  { value: "inactive", label: "Inativo" },
  { value: "archived", label: "Arquivado" },
] as const;

export const CHALLENGE_KINDS = [
  { value: "multiple_choice", label: "Múltipla escolha" },
  { value: "text", label: "Texto" },
  { value: "numeric", label: "Numérico" },
] as const;

export type ChallengeStatus = (typeof CHALLENGE_STATUSES)[number]["value"];

export function challengeStatusLabel(v: string) {
  return CHALLENGE_STATUSES.find((s) => s.value === v)?.label ?? v;
}
export function challengeKindLabel(v: string) {
  return CHALLENGE_KINDS.find((k) => k.value === v)?.label ?? v.replace(/_/g, " ");
}

/** Rótulo + tom de cor para o StatusBadge, por status de desafio. */
export function challengeStatusBadge(status: string): {
  label: string;
  tone: "success" | "warning" | "danger" | "info" | "neutral";
} {
  switch (status) {
    case "active":
      return { label: "Ativo", tone: "success" };
    case "inactive":
      return { label: "Inativo", tone: "warning" };
    case "archived":
      return { label: "Arquivado", tone: "neutral" };
    case "draft":
    default:
      return { label: "Rascunho", tone: "neutral" };
  }
}

/* -------------------------------- Dados ---------------------------------- */

export type Challenge = {
  id: string;
  unit_id: string | null;
  title: string;
  prompt: string;
  kind: string;
  status: string;
  alternatives: [string, string, string, string];
  correct: string;
  revision: number;
  created_at: string;
  updated_at: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
};

export type ChallengeFilters = PageParams & {
  search?: string;
  status?: "all" | string;
  kind?: "all" | string;
  unit?: "all" | "global" | string;
};

/**
 * Modelo de planilha (CSV) para envio de desafios de MÚLTIPLA ESCOLHA.
 * `correta` = letra da alternativa correta (A, B, C ou D).
 * Os tempos de exibição, resposta e punição são definidos nas regras, não em cada desafio.
 * O prefixo BOM (U+FEFF) garante acentos corretos ao abrir no Excel.
 */
export function challengeCsvTemplate(): string {
  const header = "titulo,enunciado,alternativa_a,alternativa_b,alternativa_c,alternativa_d,correta";
  const rows = [
    '"Coleta seletiva","Em que dia passa a coleta de recicláveis no condomínio?","Segunda","Quarta","Sexta","Domingo","B"',
    '"Portaria","Qual o ramal da portaria?","2010","2020","2030","2040","A"',
    '"Regras da piscina","Até que horário a piscina fica aberta em dias úteis?","20h","21h","22h","23h","C"',
  ];
  return String.fromCharCode(0xfeff) + [header, ...rows].join("\r\n") + "\r\n";
}

export type ChallengeStats = {
  total: number;
  active: number;
  draft: number;
  applications: number;
};

export type ChallengeActiveWindow = {
  key: "daytime" | "nighttime";
  enabled: boolean;
  start: string;
  end: string;
};

export type ChallengeRules = {
  revision: number;
  min_interval_seconds: number;
  max_interval_seconds: number;
  response_seconds: number;
  abandon_block_seconds: number;
  error_block_seconds: number[];
  active_window_start: string;
  active_window_end: string;
  active_windows: ChallengeActiveWindow[];
  timezone: string;
};

const DEFAULT_ACTIVE_WINDOWS: ChallengeActiveWindow[] = [
  { key: "daytime", enabled: true, start: "06:00", end: "18:00" },
  { key: "nighttime", enabled: true, start: "18:00", end: "06:00" },
];

export const DEFAULT_CHALLENGE_RULES: ChallengeRules = {
  revision: 0,
  min_interval_seconds: 180,
  max_interval_seconds: 300,
  response_seconds: 60,
  abandon_block_seconds: 300,
  error_block_seconds: [300, 900, 3600],
  active_window_start: "00:00",
  active_window_end: "00:00",
  active_windows: DEFAULT_ACTIVE_WINDOWS,
  timezone: "America/Sao_Paulo",
};

function normalizeActiveWindows(value: Partial<ChallengeRules>): ChallengeActiveWindow[] {
  if (Array.isArray(value.active_windows) && value.active_windows.length) {
    return DEFAULT_ACTIVE_WINDOWS.map((fallback) => {
      const saved = value.active_windows?.find((window) => window?.key === fallback.key);
      return saved
        ? {
            key: fallback.key,
            enabled: Boolean(saved.enabled),
            start: saved.start || fallback.start,
            end: saved.end || fallback.end,
          }
        : fallback;
    });
  }

  const start = value.active_window_start ?? DEFAULT_CHALLENGE_RULES.active_window_start;
  const end = value.active_window_end ?? DEFAULT_CHALLENGE_RULES.active_window_end;
  if (start === end) return DEFAULT_ACTIVE_WINDOWS.map((window) => ({ ...window }));

  const overnight = start > end;
  return DEFAULT_ACTIVE_WINDOWS.map((window) => {
    if ((overnight && window.key === "nighttime") || (!overnight && window.key === "daytime")) {
      return { ...window, enabled: true, start, end };
    }
    return { ...window, enabled: false };
  });
}

export async function getChallengeRules(unitId: string | null): Promise<ChallengeRules> {
  let query = supabase
    .from("system_settings")
    .select("value, revision")
    .eq("key", "challenge_rules")
    .eq("active", true)
    .eq("scope_type", unitId ? "unit" : "global")
    .order("revision", { ascending: false })
    .limit(1);
  query = unitId ? query.eq("scope_id", unitId) : query.is("scope_id", null);
  const { data, error } = await query.maybeSingle();
  if (error) throw error;
  const saved = (data?.value as Partial<ChallengeRules> | null) ?? {};
  return {
    ...DEFAULT_CHALLENGE_RULES,
    ...saved,
    active_windows: normalizeActiveWindows(saved),
    revision: Number(data?.revision ?? 0),
  };
}

export async function saveChallengeRules(unitId: string | null, rules: ChallengeRules): Promise<void> {
  const { error } = await supabase.rpc("admin_save_challenge_rules", { p_unit_id: unitId, p_rules: rules });
  if (error) throw error;
}

export type ChallengeInput = {
  id?: string;
  unit_id: string | null;
  title: string;
  prompt: string;
  alternatives: [string, string, string, string];
  correct: string;
  status: string;
};

export type ChallengeBatchInput = {
  title: string;
  prompt: string;
  alternatives: [string, string, string, string];
  correct: string;
};

export type ChallengeBatchResult = {
  imported?: number;
  updated?: number;
  unit_id: string | null;
  status?: string | null;
  unit_changed?: boolean;
  challenge_ids?: string[];
};

export async function upsertChallenge(input: ChallengeInput): Promise<string> {
  const payload = {
    ...input,
    answer_definition: { alternatives: input.alternatives, correct: input.correct },
  };
  const { data, error } = await supabase.rpc("admin_upsert_challenge", { p_challenge: payload });
  if (error) throw error;
  return data as string;
}

export async function setChallengeStatus(challengeId: string, status: "draft" | "active" | "inactive" | "archived"): Promise<void> {
  const { error } = await supabase.rpc("admin_set_challenge_status", { p_challenge_id: challengeId, p_status: status });
  if (error) throw error;
}

export async function importChallengesBatch(
  challenges: ChallengeBatchInput[],
  unitId: string | null,
  signal?: AbortSignal,
): Promise<ChallengeBatchResult> {
  let request = supabase.rpc("admin_import_challenges_batch", {
    p_challenges: challenges,
    p_unit_id: unitId,
  });
  if (signal) request = request.abortSignal(signal);
  const { data, error } = await request;
  if (error) throw error;
  return data as ChallengeBatchResult;
}

export async function bulkUpdateChallenges(input: {
  challengeIds: string[];
  status?: "draft" | "active" | "inactive" | "archived" | null;
  changeUnit?: boolean;
  unitId?: string | null;
}): Promise<ChallengeBatchResult> {
  const { data, error } = await supabase.rpc("admin_bulk_update_challenges", {
    p_challenge_ids: input.challengeIds,
    p_status: input.status ?? null,
    p_change_unit: input.changeUnit ?? false,
    p_unit_id: input.unitId ?? null,
  });
  if (error) throw error;
  return data as ChallengeBatchResult;
}

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

export async function listChallenges(filters: ChallengeFilters): Promise<PaginatedResult<Challenge>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim();

  let query = supabase
    .from("challenges")
    .select(
      "id, unit_id, title, prompt, kind, status, answer_definition, revision, created_at, updated_at, units(name, city, state)",
      { count: "exact" },
    )
    .order("created_at", { ascending: false });

  if (filters.status && filters.status !== "all") query = query.eq("status", filters.status);
  if (filters.kind && filters.kind !== "all") query = query.eq("kind", filters.kind);
  if (filters.unit === "global") query = query.is("unit_id", null);
  else if (filters.unit && filters.unit !== "all") query = query.eq("unit_id", filters.unit);
  if (term) {
    const clean = term.replace(/[%,()]/g, "");
    if (clean) query = query.or(`title.ilike.%${clean}%,prompt.ilike.%${clean}%`);
  }

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;

  const rows = (data ?? []).map((c: any) => ({
    id: c.id,
    unit_id: c.unit_id ?? null,
    title: c.title,
    prompt: c.prompt,
    kind: c.kind,
    status: c.status,
    alternatives: [0, 1, 2, 3].map((index) => String(c.answer_definition?.alternatives?.[index] ?? "")) as [string, string, string, string],
    correct: String(c.answer_definition?.correct ?? "A").toUpperCase(),
    revision: c.revision ?? 0,
    created_at: c.created_at,
    updated_at: c.updated_at ?? null,
    unit_name: c.units?.name ?? null,
    unit_city: c.units?.city ?? null,
    unit_state: c.units?.state ?? null,
  }));

  return { rows, total: count ?? 0 };
}

export async function countChallengeStats(): Promise<ChallengeStats> {
  const [total, active, draft, applications] = await Promise.all([
    supabase.from("challenges").select("id", { count: "exact", head: true }),
    supabase.from("challenges").select("id", { count: "exact", head: true }).eq("status", "active"),
    supabase.from("challenges").select("id", { count: "exact", head: true }).eq("status", "draft"),
    supabase.from("challenge_logs").select("id", { count: "exact", head: true }),
  ]);

  const error = total.error ?? active.error ?? draft.error ?? applications.error;
  if (error) throw error;

  return {
    total: total.count ?? 0,
    active: active.count ?? 0,
    draft: draft.count ?? 0,
    applications: applications.count ?? 0,
  };
}
