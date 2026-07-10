import type { ReactNode } from "react";
import { useMemo } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import {
  Users,
  Radio,
  Headphones,
  Inbox,
  Circle,
  Shield,
  Clock,
  MessageSquare,
  Music,
  UserCog,
  RotateCw,
  ChevronRight,
  AlertTriangle,
  CheckCircle2,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  fetchOverviewCounts,
  fetchOperatorStates,
  fetchRecentActivity,
  fetchDailySummary,
  deriveAttention,
  attentionReasonLabel,
  fmtRelative,
  fmtDuration,
  statusLabel,
  STATUS_DOT,
  STATUS_BAR,
  type StatusGroup,
  type OperatorStatusRow,
  type RecentActivity,
  type ActivityKind,
  type DailyMetric,
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
    <Card className="border-border/80 shadow-sm">
      <CardContent className="p-4">
        <div className="flex items-center gap-2.5">
          <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg", iconClass)}>
            {icon}
          </div>
          <div className="text-xs font-medium text-muted-foreground">{label}</div>
        </div>
        {loading ? (
          <Skeleton className="mt-4 h-8 w-16" />
        ) : (
          <div className="mt-3 font-display text-[26px] font-bold leading-none tracking-tight tabular-nums">
            {value}
          </div>
        )}
        {hint && !loading && <div className="mt-2 text-xs text-muted-foreground">{hint}</div>}
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
    <Card className="border-border/80 shadow-sm">
      <CardContent className="p-4">
        <div className="flex items-center gap-2.5">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-accent text-secondary">
            <Headphones className="h-5 w-5" />
          </div>
          <div className="text-xs font-medium text-muted-foreground">Operação agora</div>
        </div>
        <div className="mt-3 space-y-1.5">
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
    <Card className="border-border/80 shadow-sm">
      <CardContent className="p-4">
        <div className="flex items-center gap-2.5">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-warning/15 text-warning">
            <Inbox className="h-5 w-5" />
          </div>
          <div className="text-xs font-medium text-muted-foreground">Pendências</div>
        </div>
        <div className="mt-3 space-y-1.5">
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
    <Card className="shadow-sm">
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
            Nenhum operador com presença registrada ainda.
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

function AttentionPanel({ rows, loading }: { rows: OperatorStatusRow[]; loading: boolean }) {
  const attention = useMemo(() => deriveAttention(rows), [rows]);

  return (
    <Card className={cn("shadow-sm", !loading && attention.length > 0 && "border-warning/50")}>
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="flex items-center gap-2 text-sm font-semibold">
            <AlertTriangle className="h-4 w-4 text-warning" />
            Operadores em atenção
          </CardTitle>
          {!loading && attention.length > 0 && (
            <span className="inline-flex min-w-[2rem] items-center justify-center rounded-full bg-warning/15 px-2 py-0.5 font-mono text-xs font-semibold text-warning-foreground ring-1 ring-warning/40">
              {attention.length}
            </span>
          )}
        </div>
      </CardHeader>
      <CardContent className="space-y-1.5">
        {loading ? (
          Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-12 w-full" />)
        ) : attention.length === 0 ? (
          <div className="flex flex-col items-center justify-center gap-2 py-8 text-center">
            <CheckCircle2 className="h-8 w-8 text-success" />
            <p className="text-sm text-muted-foreground">Nenhuma ocorrência crítica no momento.</p>
          </div>
        ) : (
          attention.map((a) => (
            <Link
              key={a.operator_id}
              to="/usuarios"
              className="flex items-center gap-3 rounded-lg border border-transparent px-2.5 py-2 transition-colors hover:border-border hover:bg-muted/50"
            >
              <Circle className={cn("h-2.5 w-2.5 shrink-0 fill-current", STATUS_DOT[a.status] ?? "text-muted-foreground")} />
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{a.display_name}</div>
                <div className="truncate text-xs text-muted-foreground">
                  {attentionReasonLabel(a)}
                  {a.unit_name ? ` · ${a.unit_name}` : ""}
                </div>
              </div>
              <span className="shrink-0 text-xs tabular-nums text-muted-foreground">{fmtDuration(a.since)}</span>
              <ChevronRight className="h-4 w-4 shrink-0 text-muted-foreground/50" />
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
    <Card className="shadow-sm">
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

function DailySummaryPanel({ metrics, loading }: { metrics: DailyMetric[]; loading: boolean }) {
  return (
    <Card className="shadow-sm">
      <CardHeader className="pb-3">
        <CardTitle className="text-sm font-semibold">Resumo do dia</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          {loading
            ? Array.from({ length: 6 }).map((_, i) => <Skeleton key={i} className="h-16 w-full rounded-lg" />)
            : metrics.map((m) => (
                <div key={m.label} className="rounded-lg border border-border bg-muted/30 p-3">
                  <div className="text-2xl font-bold leading-none tracking-tight tabular-nums">
                    {m.value === null ? <span className="text-base text-muted-foreground">—</span> : m.value}
                  </div>
                  <div className="mt-1.5 text-xs leading-tight text-muted-foreground">
                    {m.value === null ? "Sem dados hoje" : m.label}
                  </div>
                </div>
              ))}
        </div>
      </CardContent>
    </Card>
  );
}

/* -------------------------------- Página --------------------------------- */

export function OverviewPage() {
  const queryClient = useQueryClient();

  const counts = useQuery({ queryKey: ["overview", "counts"], queryFn: fetchOverviewCounts, staleTime: 30_000 });
  const states = useQuery({ queryKey: ["overview", "states"], queryFn: fetchOperatorStates, staleTime: 15_000 });
  const activity = useQuery({ queryKey: ["overview", "activity"], queryFn: fetchRecentActivity, staleTime: 30_000 });
  const daily = useQuery({ queryKey: ["overview", "daily"], queryFn: fetchDailySummary, staleTime: 60_000 });

  const isFetching =
    counts.isFetching || states.isFetching || activity.isFetching || daily.isFetching;
  const isError = counts.isError || states.isError || activity.isError || daily.isError;

  const lastUpdated = useMemo(() => {
    const ts = [counts.dataUpdatedAt, states.dataUpdatedAt, activity.dataUpdatedAt, daily.dataUpdatedAt].filter(
      Boolean,
    );
    return ts.length ? new Date(Math.max(...ts)).toISOString() : null;
  }, [counts.dataUpdatedAt, states.dataUpdatedAt, activity.dataUpdatedAt, daily.dataUpdatedAt]);

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["overview"] });

  const groups = states.data?.groups ?? [];
  const total = states.data?.total ?? 0;
  const rows = states.data?.rows ?? [];

  return (
    <>
      <PageHeader
        title="Visão Geral"
        description="Acompanhamento em tempo real da operação, presença dos operadores e alertas recentes."
        action={
          <div className="flex items-center gap-3">
            <span className="hidden text-xs text-muted-foreground sm:inline">
              Atualizado {lastUpdated ? fmtRelative(lastUpdated) : "agora"}
            </span>
            <Button variant="outline" size="sm" onClick={refresh} disabled={isFetching}>
              <RotateCw className={cn("h-4 w-4", isFetching && "animate-spin")} />
              Atualizar
            </Button>
          </div>
        }
      />

      {isError && (
        <div className="mb-6 flex flex-col gap-3 rounded-lg border border-destructive/30 bg-destructive/5 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-2.5">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-destructive" />
            <div>
              <p className="text-sm font-medium text-foreground">
                Alguns dados não puderam ser carregados.
              </p>
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

      {/* Cards principais */}
      <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <MetricCard
          icon={<Users className="h-5 w-5" />}
          iconClass="bg-primary/10 text-primary"
          label="Operadores ativos"
          value={counts.data?.operators ?? 0}
          loading={counts.isLoading}
          hint={
            <span className="flex items-center gap-1.5">
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
        <OperationCard groups={groups} loading={states.isLoading} />
        <PendingCard
          feedback={counts.data?.pendingFeedback ?? 0}
          playlists={counts.data?.pendingPlaylists ?? null}
          loading={counts.isLoading}
        />
      </div>

      {/* Status + Atenção */}
      <div className="mb-5 grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(340px,.85fr)]">
        <AttentionPanel rows={rows} loading={states.isLoading} />
        <StatusPanel groups={groups} total={total} loading={states.isLoading} />
      </div>

      {/* Atividade + Resumo do dia */}
      <div className="grid gap-5 lg:grid-cols-[minmax(0,1.15fr)_minmax(340px,.85fr)]">
        <ActivityPanel items={activity.data ?? []} loading={activity.isLoading} />
        <DailySummaryPanel metrics={daily.data ?? []} loading={daily.isLoading} />
      </div>
    </>
  );
}
