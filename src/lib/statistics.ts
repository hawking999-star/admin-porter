import { supabase } from "@/lib/supabase";

export type StatisticsResetInfo = {
  reset_at: string | null;
};

export async function fetchStatisticsResetInfo(): Promise<StatisticsResetInfo> {
  const { data, error } = await supabase.rpc("admin_statistics_reset_info");
  if (error) throw error;
  const payload = (data ?? {}) as Partial<StatisticsResetInfo>;
  return { reset_at: typeof payload.reset_at === "string" ? payload.reset_at : null };
}

export async function resetStatistics(): Promise<StatisticsResetInfo> {
  const { data, error } = await supabase.rpc("admin_reset_statistics");
  if (error) throw error;
  const payload = (data ?? {}) as Partial<StatisticsResetInfo>;
  return { reset_at: typeof payload.reset_at === "string" ? payload.reset_at : null };
}

export function effectiveStatisticsStart(startAt: string, endAt: string, resetAt?: string | null): string {
  if (!resetAt) return startAt;
  const start = new Date(startAt).getTime();
  const end = new Date(endAt).getTime();
  const reset = new Date(resetAt).getTime();
  if (!Number.isFinite(reset) || reset <= start) return startAt;
  return new Date(Math.min(reset, end - 1)).toISOString();
}
