import type { ReactNode } from "react";
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import {
  AlertTriangle,
  Bell,
  Building2,
  CalendarDays,
  CheckCircle2,
  ChevronRight,
  Circle,
  Clock,
  CloudAlert,
  Headphones,
  Inbox,
  ListFilter,
  MessageSquare,
  Music,
  Play,
  Radio,
  RotateCw,
  Shield,
  Square,
  Trophy,
  UserRoundX,
  Users,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { PeriodFilter } from "@/components/shared";
import { buildPeriodRange, todayInput, type PeriodPreset } from "@/lib/period";
import { effectiveStatisticsStart, fetchStatisticsResetInfo } from "@/lib/statistics";
import { listUnitOptions } from "@/features/usuarios/queries";
import { unitLabel } from "@/lib/unit-label";
import {
  STATUS_BAR,
  STATUS_DOT,
  STATUS_ORDER,
  attentionReasonLabel,
  deriveAttention,
  fetchDailySummary,
  fetchOperatorStates,
  fetchOverviewCounts,
  fetchRecentActivity,
  fmtRelative,
  statusLabel,
  type ActivityKind,
  type DailyMetric,
  type OperatorStatusRow,
  type RecentActivity,
  type StatusGroup,
} from "./queries";

/* ------------------------------ Card de métrica -------------------------- */

function MetricCard({
  icon,
  iconClass,
  label,
  value,
  hint,
  loading,
}: {
  icon: ReactNode;
  iconClass: string;
  label: string;
  value: ReactNode;
  hint?: ReactNode;
  loading?: boolean;
}) {
  return (
    <Card className="overflow-hidden border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardContent className="relative min-h-[154px] p-5">
        <div className="absolute -right-10 -top-12 h-28 w-28 rounded-full bg-primary/5" />
        <div className="relative flex items-center gap-3">
          <div className={cn("flex h-11 w-11 shrink-0 items-center justify-center rounded-lg", iconClass)}>
            {icon}
          </div>
          <div className="text-sm font-semibold text-foreground">{label}</div>
        </div>
        {loading ? (
          <Skeleton className="mt-6 h-10 w-20" />
        ) : (
          <div className="relative mt-5 font-display text-[34px] font-bold leading-none tracking-tight text-secondary tabular-nums">
            {value}
          </div>
        )}
        {hint && !loading && <div className="relative mt-3 text-xs font-medium text-muted-foreground">{hint}</div>}
      </CardContent>
    </Card>
  );
}

/* ---------------------- Card de operação (3 métricas) -------------------- */

function OperationCard({ groups, loading }: { groups: StatusGroup[]; loading: boolean }) {
  const get = (s: string) => groups.find((g) => g.status === s)?.count ?? 0;
  const rows = [
    { label: "Em atendimento", value: get("in_call"), dot: STATUS_DOT.in_call },
    { label: "Ociosos", value: get("idle"), dot: STATUS_DOT.idle },
    { label: "Fora do turno", value: get("outside_shift"), dot: STATUS_DOT.outside_shift },
  ];

  return (
    <Card className="border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardContent className="min-h-[154px] p-5">
        <div className="flex items-center gap-3">
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-success/20 text-success-foreground">
            <Headphones className="h-5 w-5" />
          </div>
          <div className="text-sm font-semibold text-foreground">Operação agora</div>
        </div>
        <div className="mt-5 space-y-2.5">
          {rows.map((r) => (
            <div key={r.label} className="flex items-center justify-between">
              <span className="flex items-center gap-2 text-sm text-foreground">
                <Circle className={cn("h-2 w-2 fill-current", r.dot)} />
                {r.label}
              </span>
              {loading ? (
                <Skeleton className="h-4 w-6" />
              ) : (
                <span className="text-sm font-semibold tabular-nums">{r.value}</span>
              )}
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

/* ------------------------- Card de pendências ---------------------------- */

function PendingCard({
  feedback,
  playlists,
  loading,
}: {
  feedback: number;
  playlists: number | null;
  loading: boolean;
}) {
  return (
    <Card className="border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardContent className="min-h-[154px] p-5">
        <div className="flex items-center gap-3">
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-lg bg-warning/15 text-warning">
            <Inbox className="h-5 w-5" />
          </div>
          <div className="text-sm font-semibold text-foreground">Pendências</div>
        </div>
        <div className="mt-5 space-y-2">
          <Link
            to="/feedback"
            className="flex items-center justify-between rounded-md px-1 py-0.5 text-sm transition-colors hover:text-primary"
          >
            <span className="flex items-center gap-2">
              <MessageSquare className="h-4 w-4 text-muted-foreground" /> Feedbacks
            </span>
            {loading ? <Skeleton className="h-4 w-6" /> : <span className="font-semibold tabular-nums">{feedback}</span>}
          </Link>
          <Link
            to="/musicas"
            className="flex items-center justify-between rounded-md px-1 py-0.5 text-sm transition-colors hover:text-primary"
          >
            <span className="flex items-center gap-2">
              <Music className="h-4 w-4 text-muted-foreground" /> Playlists p/ aprovar
            </span>
            {loading ? (
              <Skeleton className="h-4 w-6" />
            ) : (
              <span className="font-semibold tabular-nums">{playlists ?? "—"}</span>
            )}
          </Link>
        </div>
      </CardContent>
    </Card>
  );
}

/* -------------------------- Status dos operadores ------------------------ */

function StatusPanel({ groups, total, loading }: { groups: StatusGroup[]; total: number; loading: boolean }) {
  return (
    <Card className="border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-sm font-semibold">Status dos operadores</CardTitle>
          {!loading && <span className="text-xs text-muted-foreground">{total} registrados</span>}
        </div>
      </CardHeader>
      <CardContent className="space-y-2">
        {loading ? (
          Array.from({ length: 5 }).map((_, i) => <Skeleton key={i} className="h-9 w-full" />)
        ) : total === 0 ? (
          <p className="py-8 text-center text-sm text-muted-foreground">
            Nenhum operador com presença registrada para os filtros atuais.
          </p>
        ) : (
          <>
            <div className="mb-3 flex h-2.5 overflow-hidden rounded-full bg-muted">
              {groups
                .filter((g) => g.count > 0)
                .map((g) => (
                  <div
                    key={g.status}
                    className={cn("transition-all", STATUS_BAR[g.status] ?? "bg-muted-foreground/25")}
                    style={{ width: `${(g.count / total) * 100}%` }}
                    title={`${g.label}: ${g.count}`}
                  />
                ))}
            </div>
            {groups.map((g) => (
              <div
                key={g.status}
                className="flex items-center justify-between rounded-lg px-2 py-1.5 transition-colors hover:bg-muted/50"
              >
                <span className="flex items-center gap-2.5 text-sm">
                  <Circle className={cn("h-2.5 w-2.5 fill-current", STATUS_DOT[g.status] ?? "text-muted-foreground")} />
                  {g.label}
                </span>
                <Badge variant="secondary" className="min-w-[2rem] justify-center font-mono text-xs">
                  {g.count}
                </Badge>
              </div>
            ))}
          </>
        )}
      </CardContent>
    </Card>
  );
}

/* -------------------------- Operadores em atenção ------------------------ */

function initials(name: string) {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((part) => part.charAt(0))
    .join("")
    .toUpperCase();
}

function AttentionPanel({ rows, loading }: { rows: OperatorStatusRow[]; loading: boolean }) {
  const attention = useMemo(() => deriveAttention(rows), [rows]);

  return (
    <Card className="porter-contour-panel overflow-hidden border-sidebar-border bg-sidebar text-white shadow-sm shadow-secondary/20">
      <CardHeader className="border-b border-white/10 pb-3">
        <div className="flex items-center justify-between">
          <div>
            <CardTitle className="flex items-center gap-2 text-sm font-semibold">
              <AlertTriangle className="h-4 w-4 text-warning" />
              Operadores em atenção
            </CardTitle>
            <p className="mt-1 text-xs text-white/55">
              Atendimento acima de 10 min, ociosidade acima de 1 h ou 5+ bloqueios hoje.
            </p>
          </div>
          {!loading && attention.length > 0 && (
            <span className="inline-flex min-w-[2rem] items-center justify-center rounded-full bg-warning px-2 py-0.5 font-mono text-xs font-semibold text-warning-foreground">
              {attention.length}
            </span>
          )}
        </div>
      </CardHeader>
      <CardContent className="max-h-[300px] space-y-1.5 overflow-y-auto">
        {loading ? (
          Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-12 w-full bg-white/10" />)
        ) : attention.length === 0 ? (
          <div className="flex flex-col items-center justify-center gap-2 py-8 text-center">
            <CheckCircle2 className="h-8 w-8 text-success" />
            <p className="text-sm text-white/70">Nenhum Operador ultrapassou os limites de atenção.</p>
          </div>
        ) : (
          attention.map((a) => (
            <Link
              key={a.operator_id}
              to="/usuarios"
              className="flex items-center gap-3 rounded-lg border border-transparent px-2.5 py-2 transition-colors hover:border-white/15 hover:bg-white/8"
            >
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-full bg-primary font-display text-xs font-bold text-primary-foreground shadow-[0_0_0_1px_rgba(255,255,255,.16)]">
                {initials(a.registered_name)}
              </div>
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{a.registered_name}</div>
                <div className="truncate text-xs text-white/55">
                  {a.username ? `@${a.username}` : "Sem usuário"}
                  {a.unit_label ? ` · ${a.unit_label}` : ""}
                </div>
                <div className="truncate text-xs font-medium text-warning">{attentionReasonLabel(a)}</div>
              </div>
              <ChevronRight className="h-4 w-4 shrink-0 text-white/45" />
            </Link>
          ))
        )}
      </CardContent>
    </Card>
  );
}

/* --------------------------- Atividade recente --------------------------- */

const ACTIVITY_ICON: Record<ActivityKind, ReactNode> = {
  session: <Radio className="h-3.5 w-3.5 text-secondary" />,
  feedback: <MessageSquare className="h-3.5 w-3.5 text-primary" />,
  playlist: <Music className="h-3.5 w-3.5 text-primary" />,
  audit: <Shield className="h-3.5 w-3.5 text-muted-foreground" />,
};

function ActivityPanel({ items, loading }: { items: RecentActivity[]; loading: boolean }) {
  return (
    <Card className="border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardHeader className="pb-3">
        <CardTitle className="text-sm font-semibold">Atividade recente</CardTitle>
      </CardHeader>
      <CardContent>
        {loading ? (
          <div className="space-y-2">
            {Array.from({ length: 6 }).map((_, i) => (
              <Skeleton key={i} className="h-11 w-full" />
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="flex flex-col items-center justify-center gap-2 py-10 text-center">
            <Clock className="h-6 w-6 text-muted-foreground/60" />
            <p className="text-sm text-muted-foreground">Nenhuma atividade recente registrada.</p>
          </div>
        ) : (
          <div className="max-h-[340px] space-y-0.5 overflow-y-auto pr-1">
            {items.map((item) => (
              <div
                key={item.id}
                className="flex items-start gap-3 rounded-lg px-2 py-2 transition-colors hover:bg-muted/50"
              >
                <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-muted">
                  {ACTIVITY_ICON[item.kind]}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm">{item.title}</div>
                  {item.detail && <div className="truncate text-xs text-muted-foreground">{item.detail}</div>}
                </div>
                <span className="shrink-0 text-xs text-muted-foreground">{fmtRelative(item.occurred_at)}</span>
              </div>
            ))}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

/* ----------------------------- Resumo do dia ----------------------------- */

function DailySummaryPanel({ metrics, loading, title }: { metrics: DailyMetric[]; loading: boolean; title: string }) {
  const icons = [
    { icon: <Play className="h-4 w-4" />, className: "bg-primary/10 text-primary" },
    { icon: <Square className="h-4 w-4" />, className: "bg-secondary/10 text-secondary" },
    { icon: <MessageSquare className="h-4 w-4" />, className: "bg-success/20 text-success-foreground" },
    { icon: <UserRoundX className="h-4 w-4" />, className: "bg-warning/15 text-warning" },
    { icon: <Trophy className="h-4 w-4" />, className: "bg-destructive/10 text-destructive" },
    { icon: <CloudAlert className="h-4 w-4" />, className: "bg-primary/10 text-primary" },
  ];

  return (
    <Card className="border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardHeader className="pb-3">
        <CardTitle className="text-sm font-semibold">{title}</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-6">
          {loading
            ? Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-20 w-full rounded-lg" />)
            : metrics.map((m, index) => {
                const item = icons[index] ?? icons[0];
                return (
                  <div key={m.label} className="flex min-h-[78px] items-center gap-3 rounded-lg border border-border bg-background/55 p-3">
                    <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg", item.className)}>
                      {item.icon}
                    </div>
                    <div className="min-w-0">
                      <div className="font-display text-2xl font-bold leading-none tracking-tight text-secondary tabular-nums">
                        {m.value === null ? <span className="text-base text-muted-foreground">—</span> : m.value}
                      </div>
                      <div className="mt-1.5 text-xs leading-tight text-muted-foreground">
                        {m.value === null ? "Sem dados hoje" : m.label}
                      </div>
                    </div>
                  </div>
                );
              })}
        </div>
      </CardContent>
    </Card>
  );
}

/* -------------------------------- Filtros -------------------------------- */

type UnitOption = {
  value: string;
  label: string;
};

function OverviewFilters({
  unitOptions,
  unit,
  status,
  period,
  customFrom,
  customTo,
  hasFilters,
  onUnitChange,
  onStatusChange,
  onPeriodChange,
  onCustomFromChange,
  onCustomToChange,
  onClear,
}: {
  unitOptions: UnitOption[];
  unit: string;
  status: string;
  period: PeriodPreset;
  customFrom: string;
  customTo: string;
  hasFilters: boolean;
  onUnitChange: (value: string) => void;
  onStatusChange: (value: string) => void;
  onPeriodChange: (value: PeriodPreset) => void;
  onCustomFromChange: (value: string) => void;
  onCustomToChange: (value: string) => void;
  onClear: () => void;
}) {
  return (
    <Card className="mb-5 border-border/80 bg-card shadow-sm shadow-secondary/5">
      <CardContent className="grid gap-4 p-4 md:grid-cols-[minmax(220px,1fr)_minmax(180px,0.65fr)_minmax(160px,0.55fr)_auto] md:items-end">
        <div className="space-y-1.5">
          <div className="text-xs font-semibold text-muted-foreground">Condomínio</div>
          <Select value={unit} onValueChange={onUnitChange}>
            <SelectTrigger className="h-10 bg-background">
              <span className="flex min-w-0 items-center gap-2">
                <Building2 className="h-4 w-4 shrink-0 text-muted-foreground" />
                <SelectValue placeholder="Todos os condomínios" />
              </span>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos os condomínios</SelectItem>
              {unitOptions.map((item) => (
                <SelectItem key={item.value} value={item.value}>
                  {item.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-1.5">
          <div className="text-xs font-semibold text-muted-foreground">Status</div>
          <Select value={status} onValueChange={onStatusChange}>
            <SelectTrigger className="h-10 bg-background">
              <span className="flex min-w-0 items-center gap-2">
                <ListFilter className="h-4 w-4 shrink-0 text-muted-foreground" />
                <SelectValue placeholder="Todos" />
              </span>
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">Todos</SelectItem>
              {STATUS_ORDER.map((item) => (
                <SelectItem key={item} value={item}>
                  {statusLabel(item)}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="space-y-1.5">
          <div className="text-xs font-semibold text-muted-foreground">Período</div>
          <PeriodFilter
            value={period}
            customFrom={customFrom}
            customTo={customTo}
            onValueChange={onPeriodChange}
            onCustomFromChange={onCustomFromChange}
            onCustomToChange={onCustomToChange}
          />
        </div>

        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="h-10 justify-start text-primary hover:text-primary"
          disabled={!hasFilters}
          onClick={onClear}
        >
          <RotateCw className="h-4 w-4" />
          Limpar filtros
        </Button>
      </CardContent>
    </Card>
  );
}

/* -------------------------------- Página --------------------------------- */

export function OverviewPage() {
  const queryClient = useQueryClient();
  const [unitFilter, setUnitFilter] = useState("all");
  const [statusFilter, setStatusFilter] = useState("all");
  const [period, setPeriod] = useState<PeriodPreset>("7d");
  const [customFrom, setCustomFrom] = useState(todayInput());
  const [customTo, setCustomTo] = useState(todayInput());
  const periodRange = useMemo(() => buildPeriodRange(period, customFrom, customTo), [period, customFrom, customTo]);
  const resetInfo = useQuery({ queryKey: ["overview", "statistics-reset"], queryFn: fetchStatisticsResetInfo, staleTime: 30_000 });
  const effectiveStartAt = effectiveStatisticsStart(periodRange.startAt, periodRange.endAt, resetInfo.data?.reset_at);
  const scopedUnitId = unitFilter === "all" ? undefined : unitFilter;

  const counts = useQuery({ queryKey: ["overview", "counts", resetInfo.data?.reset_at, scopedUnitId], queryFn: () => fetchOverviewCounts(resetInfo.data?.reset_at ?? undefined, scopedUnitId), staleTime: 30_000, enabled: resetInfo.isSuccess });
  const states = useQuery({
    queryKey: ["overview", "states"],
    queryFn: fetchOperatorStates,
    staleTime: 15_000,
    refetchInterval: 30_000,
  });
  const units = useQuery({ queryKey: ["overview", "units"], queryFn: listUnitOptions, staleTime: 60_000 });
  const activity = useQuery({ queryKey: ["overview", "activity", effectiveStartAt, periodRange.endAt, scopedUnitId], queryFn: () => fetchRecentActivity(effectiveStartAt, periodRange.endAt, scopedUnitId), staleTime: 30_000, enabled: resetInfo.isSuccess });
  const daily = useQuery({ queryKey: ["overview", "daily", effectiveStartAt, periodRange.endAt, scopedUnitId], queryFn: () => fetchDailySummary(effectiveStartAt, periodRange.endAt, scopedUnitId), staleTime: 60_000, enabled: resetInfo.isSuccess });

  const isFetching = resetInfo.isFetching || counts.isFetching || states.isFetching || units.isFetching || activity.isFetching || daily.isFetching;
  const isError = resetInfo.isError || counts.isError || states.isError || units.isError || activity.isError || daily.isError;

  const lastUpdated = useMemo(() => {
    const ts = [resetInfo.dataUpdatedAt, counts.dataUpdatedAt, states.dataUpdatedAt, units.dataUpdatedAt, activity.dataUpdatedAt, daily.dataUpdatedAt].filter(
      Boolean,
    );
    return ts.length ? new Date(Math.max(...ts)).toISOString() : null;
  }, [resetInfo.dataUpdatedAt, counts.dataUpdatedAt, states.dataUpdatedAt, units.dataUpdatedAt, activity.dataUpdatedAt, daily.dataUpdatedAt]);

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["overview"] });

  const groups = states.data?.groups ?? [];
  const total = states.data?.total ?? 0;
  const rows = states.data?.rows ?? [];
  const unitOptions = useMemo(
    () => (units.data ?? []).map((unit) => ({ value: unit.id, label: unitLabel(unit) })),
    [units.data],
  );
  const filteredRows = useMemo(
    () =>
      rows.filter((row) => {
        const fallbackUnitValue = row.unit_label ? `unit:${row.unit_label}` : null;
        const matchesUnit = unitFilter === "all" || row.unit_id === unitFilter || fallbackUnitValue === unitFilter;
        const matchesStatus = statusFilter === "all" || row.status === statusFilter;
        return matchesUnit && matchesStatus;
      }),
    [rows, statusFilter, unitFilter],
  );
  const filteredGroups = useMemo(
    () =>
      groups.map((group) => ({
        ...group,
        count: filteredRows.filter((row) => row.status === group.status).length,
      })),
    [filteredRows, groups],
  );
  const hasFilters = unitFilter !== "all" || statusFilter !== "all" || period !== "7d";
  const visibleTotal = hasFilters ? filteredRows.length : total;
  const pendingTotal = (counts.data?.pendingFeedback ?? 0) + (counts.data?.pendingPlaylists ?? 0);
  const todayLabel = useMemo(
    () => new Intl.DateTimeFormat("pt-BR", { day: "2-digit", month: "long", year: "numeric" }).format(new Date()),
    [],
  );

  return (
    <>
      <PageHeader
        title="Visão Geral"
        description="Acompanhe em tempo real a operação, presença dos operadores e alertas importantes."
        action={
          <div className="flex flex-wrap items-center gap-2">
            <span className="inline-flex h-9 items-center justify-center rounded-md border border-border bg-background px-3 text-xs text-muted-foreground shadow-sm">
              <Bell className="mr-2 h-4 w-4" />
              {pendingTotal}
            </span>
            <span className="inline-flex h-9 items-center justify-center rounded-md border border-border bg-background px-3 text-xs text-muted-foreground shadow-sm">
              <CalendarDays className="mr-2 h-4 w-4" />
              {todayLabel}
            </span>
            <span className="hidden text-xs text-muted-foreground xl:inline">
              Atualizado {lastUpdated ? fmtRelative(lastUpdated) : "agora"}
            </span>
            <Button size="sm" onClick={refresh} disabled={isFetching}>
              <RotateCw className={cn("h-4 w-4", isFetching && "animate-spin")} />
              Atualizar dados
            </Button>
          </div>
        }
      />

      {isError && (
        <div className="mb-6 flex flex-col gap-3 rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-2.5">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
            <div>
              <p className="text-sm font-medium text-foreground">Alguns dados não puderam ser carregados.</p>
              <p className="text-xs text-muted-foreground">
                Os números abaixo podem estar incompletos. Tente atualizar novamente.
              </p>
            </div>
          </div>
          <Button variant="outline" size="sm" onClick={refresh} disabled={isFetching} className="shrink-0">
            <RotateCw className={cn("h-4 w-4", isFetching && "animate-spin")} />
            Tentar novamente
          </Button>
        </div>
      )}

      <OverviewFilters
        unitOptions={unitOptions}
        unit={unitFilter}
        status={statusFilter}
        period={period}
        customFrom={customFrom}
        customTo={customTo}
        hasFilters={hasFilters}
        onUnitChange={setUnitFilter}
        onStatusChange={setStatusFilter}
        onPeriodChange={setPeriod}
        onCustomFromChange={setCustomFrom}
        onCustomToChange={setCustomTo}
        onClear={() => {
          setUnitFilter("all");
          setStatusFilter("all");
          setPeriod("7d");
        }}
      />

      <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard
          icon={<Users className="h-5 w-5" />}
          iconClass="bg-primary/10 text-primary"
          label="Operadores ativos"
          value={counts.data?.operators ?? 0}
          loading={counts.isLoading}
          hint={
            <span className="flex items-center gap-1.5 text-success-foreground">
              <Circle className="h-2 w-2 fill-current text-success" />
              {counts.data?.operatorsOnline ?? 0} online agora
            </span>
          }
        />
        <MetricCard
          icon={<Radio className="h-5 w-5" />}
          iconClass="bg-secondary/10 text-secondary"
          label="Sessões ativas"
          value={counts.data?.activeSessions ?? 0}
          loading={counts.isLoading}
          hint={`${counts.data?.sessionsEndedToday ?? 0} encerradas hoje`}
        />
        <OperationCard groups={filteredGroups} loading={states.isLoading} />
        <PendingCard
          feedback={counts.data?.pendingFeedback ?? 0}
          playlists={counts.data?.pendingPlaylists ?? null}
          loading={counts.isLoading}
        />
      </div>

      <div className="mb-5 grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(340px,.85fr)]">
        <AttentionPanel rows={filteredRows} loading={states.isLoading} />
        <StatusPanel groups={filteredGroups} total={visibleTotal} loading={states.isLoading} />
      </div>

      <div className="mb-5">
        <DailySummaryPanel metrics={daily.data ?? []} loading={daily.isLoading} title="Resumo do período" />
      </div>

      <ActivityPanel items={activity.data ?? []} loading={activity.isLoading} />
    </>
  );
}
