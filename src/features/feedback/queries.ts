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

export const FEEDBACK_TYPES = [
  { value: "suggestion", label: "Sugestão" },
  { value: "problem", label: "Problema" },
  { value: "praise", label: "Elogio" },
] as const;

export const FEEDBACK_STATUSES = [
  { value: "new", label: "Novo" },
  { value: "read", label: "Lido" },
  { value: "resolved", label: "Resolvido" },
] as const;

export type FeedbackType = (typeof FEEDBACK_TYPES)[number]["value"];
export type FeedbackStatus = (typeof FEEDBACK_STATUSES)[number]["value"];

export function feedbackTypeLabel(v: string) {
  return FEEDBACK_TYPES.find((t) => t.value === v)?.label ?? v;
}
export function feedbackStatusLabel(v: string) {
  return FEEDBACK_STATUSES.find((s) => s.value === v)?.label ?? v;
}

/* -------------------------------- Dados ---------------------------------- */

export type Feedback = {
  id: string;
  type: FeedbackType;
  message: string;
  status: FeedbackStatus;
  app_version: string | null;
  created_at: string;
  operator_name: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
};

export type FeedbackFilters = PageParams & {
  search?: string;
  type?: "all" | string;
  status?: "all" | string;
};

export type FeedbackStats = {
  pending: number;
  resolved: number;
  problems: number;
  today: number;
};

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

export async function listFeedback(filters: FeedbackFilters): Promise<PaginatedResult<Feedback>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim();

  let query = supabase
    .from("feedback")
    .select(
      "id, type, message, status, app_version, created_at, operators(display_name), units(name, city, state)",
      { count: "exact" },
    )
    .order("created_at", { ascending: false });

  if (filters.type && filters.type !== "all") query = query.eq("type", filters.type);
  if (filters.status && filters.status !== "all") query = query.eq("status", filters.status);
  if (term) {
    const clean = term.replace(/[%,()]/g, "");
    if (clean) query = query.ilike("message", `%${clean}%`);
  }

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;

  const rows = (data ?? []).map((f: any) => ({
    id: f.id,
    type: f.type,
    message: f.message,
    status: f.status,
    app_version: f.app_version ?? null,
    created_at: f.created_at,
    operator_name: f.operators?.display_name ?? null,
    unit_name: f.units?.name ?? null,
    unit_city: f.units?.city ?? null,
    unit_state: f.units?.state ?? null,
  }));

  return { rows, total: count ?? 0 };
}

export async function countFeedbackStats(): Promise<FeedbackStats> {
  const startToday = new Date();
  startToday.setHours(0, 0, 0, 0);

  const [pending, resolved, problems, today] = await Promise.all([
    supabase.from("feedback").select("id", { count: "exact", head: true }).eq("status", "new"),
    supabase.from("feedback").select("id", { count: "exact", head: true }).eq("status", "resolved"),
    supabase.from("feedback").select("id", { count: "exact", head: true }).eq("type", "problem"),
    supabase.from("feedback").select("id", { count: "exact", head: true }).gte("created_at", startToday.toISOString()),
  ]);

  const error = pending.error ?? resolved.error ?? problems.error ?? today.error;
  if (error) throw error;

  return {
    pending: pending.count ?? 0,
    resolved: resolved.count ?? 0,
    problems: problems.count ?? 0,
    today: today.count ?? 0,
  };
}

export async function updateFeedbackStatus(id: string, status: FeedbackStatus): Promise<void> {
  const { error } = await supabase.rpc("admin_update_feedback_status", {
    p_feedback: id,
    p_status: status,
  });
  if (error) throw error;
}
