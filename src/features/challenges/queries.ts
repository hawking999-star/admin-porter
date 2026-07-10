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
  title: string;
  prompt: string;
  kind: string;
  status: string;
  duration_seconds: number | null;
  block_seconds: number | null;
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
 * `duracao_segundos` padrão 60; `bloqueio_segundos` é opcional.
 * O prefixo BOM (U+FEFF) garante acentos corretos ao abrir no Excel.
 */
export function challengeCsvTemplate(): string {
  const header =
    "titulo,enunciado,alternativa_a,alternativa_b,alternativa_c,alternativa_d,correta,duracao_segundos,bloqueio_segundos";
  const rows = [
    '"Coleta seletiva","Em que dia passa a coleta de recicláveis no condomínio?","Segunda","Quarta","Sexta","Domingo","B","60","120"',
    '"Portaria","Qual o ramal da portaria?","2010","2020","2030","2040","A","45",""',
    '"Regras da piscina","Até que horário a piscina fica aberta em dias úteis?","20h","21h","22h","23h","C","60","180"',
  ];
  return String.fromCharCode(0xfeff) + [header, ...rows].join("\r\n") + "\r\n";
}

export type ChallengeStats = {
  total: number;
  active: number;
  draft: number;
  applications: number;
};

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
      "id, title, prompt, kind, status, duration_seconds, block_seconds, revision, created_at, updated_at, units(name, city, state)",
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
    title: c.title,
    prompt: c.prompt,
    kind: c.kind,
    status: c.status,
    duration_seconds: c.duration_seconds ?? null,
    block_seconds: c.block_seconds ?? null,
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
