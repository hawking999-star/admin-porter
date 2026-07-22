import { supabase } from "@/lib/supabase";

export type StatisticsResetInfo = {
  reset_at: string | null;
  resets: Record<StatisticsResetCategory, string | null>;
};

export const STATISTICS_RESET_CATEGORIES = ["sessions", "calls", "challenges", "attention"] as const;
export type StatisticsResetCategory = (typeof STATISTICS_RESET_CATEGORIES)[number];

const EMPTY_RESETS: StatisticsResetInfo["resets"] = {
  sessions: null,
  calls: null,
  challenges: null,
  attention: null,
};

function normalizeResetInfo(value: unknown): StatisticsResetInfo {
  const payload = (value ?? {}) as Partial<StatisticsResetInfo>;
  const resets = (payload.resets ?? {}) as Partial<StatisticsResetInfo["resets"]>;
  return {
    reset_at: typeof payload.reset_at === "string" ? payload.reset_at : null,
    resets: Object.fromEntries(
      STATISTICS_RESET_CATEGORIES.map((category) => [
        category,
        typeof resets[category] === "string" ? resets[category] : null,
      ]),
    ) as StatisticsResetInfo["resets"],
  };
}

export async function fetchStatisticsResetInfo(): Promise<StatisticsResetInfo> {
  const { data, error } = await supabase.rpc("admin_statistics_reset_info");
  if (error) throw error;
  return normalizeResetInfo(data ?? { reset_at: null, resets: EMPTY_RESETS });
}

export async function resetStatistics(categories: StatisticsResetCategory[]): Promise<StatisticsResetInfo> {
  const { data, error } = await supabase.rpc("admin_reset_statistics", { p_categories: categories });
  if (error) throw error;
  return normalizeResetInfo(data);
}

export function effectiveStatisticsStart(startAt: string, endAt: string, resetAt?: string | null): string {
  if (!resetAt) return startAt;
  const start = new Date(startAt).getTime();
  const end = new Date(endAt).getTime();
  const reset = new Date(resetAt).getTime();
  if (!Number.isFinite(reset) || reset <= start) return startAt;
  return new Date(Math.min(reset, end - 1)).toISOString();
}
