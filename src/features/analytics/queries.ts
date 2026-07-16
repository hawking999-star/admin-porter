import { supabase } from "@/lib/supabase";
import { buildPeriodRange, type PeriodPreset } from "@/lib/period";
import { effectiveStatisticsStart, fetchStatisticsResetInfo } from "@/lib/statistics";
import { unitLabel } from "@/lib/unit-label";

export { buildPeriodRange, type PeriodPreset };
export type ShiftFilter = "all" | "day" | "night" | "other";

export type AnalyticsFilters = {
  startAt: string;
  endAt: string;
  unitId: string;
  operatorId: string;
  shift: ShiftFilter;
  rankingPage: number;
  rankingPageSize: number;
};

export type FilterOption = {
  id: string;
  name?: string;
  registered_name?: string;
  display_name?: string;
  username?: string | null;
  unit_id?: string;
  city?: string | null;
  state?: string | null;
  code?: string | null;
};
export type ShiftOption = { value: ShiftFilter; label: string };

export type AnalyticsMetrics = {
  active_operators: number;
  total_sessions: number;
  online_seconds: number;
  idle_seconds: number;
  call_seconds: number;
  answered_calls: number;
  challenge_response_rate: number | null;
  challenge_accuracy_rate: number | null;
  challenges_received: number;
  challenges_answered: number;
  music_interactions: number | null;
  music_interactions_available: boolean;
  music_interactions_unavailable_reason: string | null;
};

export type TimeseriesPoint = {
  bucket_start: string;
  sessions: number;
  online_seconds: number;
  idle_seconds: number;
  call_seconds: number;
};

export type CondominiumAnalyticsRow = {
  unit_id: string;
  unit_name: string;
  unit_city?: string | null;
  unit_state?: string | null;
  unit_code?: string | null;
  active_operators: number;
  sessions: number;
  online_seconds: number;
  idle_seconds: number;
  call_seconds: number;
  challenges_answered: number;
  challenges_received: number;
  challenge_accuracy_rate: number | null;
};

export type OperatorRankingRow = {
  operator_id: string;
  operator_name: string;
  unit_id: string;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  unit_code: string | null;
  challenges_received: number;
  challenges_answered: number;
  challenges_correct: number;
  challenge_accuracy_rate: number | null;
  last_challenge_at: string | null;
};

export type OperatorAttentionRow = {
  operator_id: string;
  operator_name: string;
  unit_id: string;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  unit_code: string | null;
  idle_events: number;
  idle_seconds: number;
  last_idle_at: string | null;
  block_count: number;
  blocked_seconds: number;
  last_block_at: string | null;
};

export type StatusBreakdownRow = {
  status: "active" | "in_call" | "idle" | "offline" | string;
  label: string;
  count: number;
};

export type AnalyticsSource = {
  key: string;
  label: string;
  available: boolean;
  tables?: string[];
  reason?: string;
};

export type AnalyticsDashboard = {
  metrics: AnalyticsMetrics;
  filter_options: {
    units: FilterOption[];
    operators: FilterOption[];
    shifts: ShiftOption[];
  };
  timeseries: TimeseriesPoint[];
  condominiums: CondominiumAnalyticsRow[];
  ranking: {
    rows: OperatorRankingRow[];
    total: number;
    page: number;
    page_size: number;
  };
  attention_ranking: {
    idle: OperatorAttentionRow[];
    blocked: OperatorAttentionRow[];
  };
  status_breakdown: StatusBreakdownRow[];
  sources: AnalyticsSource[];
  statistics_reset_at?: string | null;
};

export async function fetchAnalyticsDashboard(filters: AnalyticsFilters): Promise<AnalyticsDashboard> {
  const resetInfo = await fetchStatisticsResetInfo();
  const effectiveStartAt = effectiveStatisticsStart(filters.startAt, filters.endAt, resetInfo.reset_at);
  const request = {
    start_at: effectiveStartAt,
    end_at: filters.endAt,
    unit_id: filters.unitId === "all" ? null : filters.unitId,
    operator_id: filters.operatorId === "all" ? null : filters.operatorId,
    shift: filters.shift,
    ranking_page: filters.rankingPage,
    ranking_page_size: filters.rankingPageSize,
  };
  const [dashboardResult, callsResult, leaderboardResult, attentionResult, unitsResult] = await Promise.all([
    supabase.rpc("admin_analytics_dashboard", { p_request: request }),
    supabase.rpc("admin_analytics_answered_calls", { p_request: request }),
    supabase.rpc("admin_challenge_leaderboard", { p_request: request }),
    supabase.rpc("admin_operator_attention_leaderboard", { p_request: request }),
    supabase.from("units").select("id, name, city, state, code").eq("active", true).order("name").limit(500),
  ]);

  if (dashboardResult.error) throw dashboardResult.error;
  if (callsResult.error) throw callsResult.error;
  if (leaderboardResult.error) throw leaderboardResult.error;
  if (attentionResult.error) throw attentionResult.error;
  if (unitsResult.error) throw unitsResult.error;

  const dashboard = dashboardResult.data as AnalyticsDashboard;
  const calls = (callsResult.data ?? {}) as { answered_calls?: unknown };
  const leaderboard = (leaderboardResult.data ?? {}) as AnalyticsDashboard["ranking"];
  const attentionRanking = (attentionResult.data ?? { idle: [], blocked: [] }) as AnalyticsDashboard["attention_ranking"];
  const visibleOperatorIds = dashboard.filter_options.operators.map((operator) => operator.id);
  const operatorIdentitiesResult = visibleOperatorIds.length
    ? await supabase
        .from("operators")
        .select("id, registered_name, username, unit_id")
        .in("id", visibleOperatorIds)
        .eq("active", true)
        .order("registered_name")
        .limit(500)
    : { data: [], error: null };

  if (operatorIdentitiesResult.error) throw operatorIdentitiesResult.error;

  const operatorIdentities = (operatorIdentitiesResult.data ?? []) as Array<{
    id: string;
    registered_name: string;
    username: string | null;
    unit_id: string;
  }>;
  const unitRows = (unitsResult.data ?? []) as Array<{
    id: string;
    name: string;
    city: string | null;
    state: string | null;
    code: string | null;
  }>;
  const unitsById = new Map(unitRows.map((unit) => [unit.id, unit]));
  const decoratedCondominiums = dashboard.condominiums.map((row) => {
    const unit = unitsById.get(row.unit_id);
    return {
      ...row,
      unit_name: unitLabel({
        name: unit?.name ?? row.unit_name,
        city: unit?.city,
        state: unit?.state,
        code: unit?.code,
      }),
      unit_city: unit?.city ?? null,
      unit_state: unit?.state ?? null,
      unit_code: unit?.code ?? null,
    };
  });
  return {
    ...dashboard,
    statistics_reset_at: resetInfo.reset_at,
    filter_options: {
      ...dashboard.filter_options,
      units: unitRows.map((unit) => ({ ...unit, name: unitLabel(unit) })),
      operators: operatorIdentities,
    },
    condominiums: decoratedCondominiums,
    ranking: leaderboard,
    attention_ranking: attentionRanking,
    metrics: {
      ...dashboard.metrics,
      answered_calls: Number(calls.answered_calls ?? 0),
    },
  };
}

export function formatSeconds(value: number | null | undefined): string {
  if (value == null) return "-";
  const totalSeconds = Math.max(0, Math.round(value));
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const totalMinutes = Math.floor(totalSeconds / 60);
  if (totalMinutes < 60) return `${totalMinutes} min`;
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours < 24) return minutes ? `${hours}h ${minutes}min` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const remHours = hours % 24;
  return remHours ? `${days}d ${remHours}h` : `${days}d`;
}

export function formatPercent(value: number | null | undefined): string {
  if (value == null) return "-";
  return `${Number(value).toLocaleString("pt-BR", { maximumFractionDigits: 1 })}%`;
}

export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return "-";
  return new Date(iso).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatBucket(iso: string): string {
  const date = new Date(iso);
  return date.toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
  });
}
