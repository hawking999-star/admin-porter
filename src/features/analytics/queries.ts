import { supabase } from "@/lib/supabase";

export type PeriodPreset = "today" | "7d" | "30d" | "custom";
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

export type FilterOption = { id: string; name?: string; display_name?: string; unit_id?: string };
export type ShiftOption = { value: ShiftFilter; label: string };

export type AnalyticsMetrics = {
  active_operators: number;
  total_sessions: number;
  online_seconds: number;
  idle_seconds: number;
  call_seconds: number;
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
  unit_name: string | null;
  sessions: number;
  online_seconds: number;
  idle_seconds: number;
  call_seconds: number;
  challenges_received: number;
  challenges_answered: number;
  challenge_response_rate: number | null;
  challenge_accuracy_rate: number | null;
  last_event_at: string | null;
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
  status_breakdown: StatusBreakdownRow[];
  sources: AnalyticsSource[];
};

export function buildPeriodRange(preset: PeriodPreset, customFrom: string, customTo: string) {
  const now = new Date();
  const start = new Date(now);
  const end = new Date(now);

  if (preset === "today") {
    start.setHours(0, 0, 0, 0);
  } else if (preset === "7d") {
    start.setDate(start.getDate() - 6);
    start.setHours(0, 0, 0, 0);
  } else if (preset === "30d") {
    start.setDate(start.getDate() - 29);
    start.setHours(0, 0, 0, 0);
  } else {
    const from = customFrom ? new Date(`${customFrom}T00:00:00`) : start;
    const to = customTo ? new Date(`${customTo}T23:59:59.999`) : end;
    return { startAt: from.toISOString(), endAt: to.toISOString() };
  }

  return { startAt: start.toISOString(), endAt: end.toISOString() };
}

export async function fetchAnalyticsDashboard(filters: AnalyticsFilters): Promise<AnalyticsDashboard> {
  const { data, error } = await supabase.rpc("admin_analytics_dashboard", {
    p_request: {
      start_at: filters.startAt,
      end_at: filters.endAt,
      unit_id: filters.unitId === "all" ? null : filters.unitId,
      operator_id: filters.operatorId === "all" ? null : filters.operatorId,
      shift: filters.shift,
      ranking_page: filters.rankingPage,
      ranking_page_size: filters.rankingPageSize,
    },
  });

  if (error) throw error;
  return data as AnalyticsDashboard;
}

export function formatSeconds(value: number | null | undefined): string {
  if (value == null) return "-";
  const totalMinutes = Math.round(value / 60);
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
