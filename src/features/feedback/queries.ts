import { supabase } from "@/lib/supabase";

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

export async function listFeedback(): Promise<Feedback[]> {
  const { data, error } = await supabase
    .from("feedback")
    .select(
      "id, type, message, status, app_version, created_at, operators(display_name), units(name, city, state)",
    )
    .order("created_at", { ascending: false });
  if (error) throw error;

  return (data ?? []).map((f: any) => ({
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
}

export async function updateFeedbackStatus(id: string, status: FeedbackStatus): Promise<void> {
  const patch: Record<string, unknown> = {
    status,
    updated_at: new Date().toISOString(),
  };
  patch.resolved_at = status === "resolved" ? new Date().toISOString() : null;
  const { error } = await supabase.from("feedback").update(patch).eq("id", id);
  if (error) throw error;
}
