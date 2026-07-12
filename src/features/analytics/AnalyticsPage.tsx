import { useMemo, useState, type ReactNode } from "react";
import { keepPreviousData, useQuery } from "@tanstack/react-query";
import {
  Area,
  AreaChart,
  Cell,
  CartesianGrid,
  Line,
  LineChart,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  Activity,
  AlertCircle,
  BarChart3,
  Clock3,
  Download,
  Loader2,
  Phone,
  RotateCcw,
  ShieldCheck,
  Trophy,
  Users,
} from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { EmptyState, ErrorState, RetryButton } from "@/components/shared";
import {
  buildPeriodRange,
  fetchAnalyticsDashboard,
  formatBucket,
  formatDateTime,
  formatPercent,
  formatSeconds,
  type AnalyticsDashboard,
  type AnalyticsMetrics,
  type PeriodPreset,
  type ShiftFilter,
} from "./queries";

const TOP_LIST_LIMIT = 5;

function todayInput() {
  return new Date().toISOString().slice(0, 10);
}

function csvCell(value: unknown) {
  const raw = value == null ? "" : String(value);
  return `"${raw.replace(/"/g, '""')}"`;
}

function downloadCsv(data: AnalyticsDashboard) {
  const lines: string[] = [];
  lines.push("Resumo");
  lines.push(["Metrica", "Valor"].map(csvCell).join(","));
  lines.push(["Operadores ativos", data.metrics.active_operators].map(csvCell).join(","));
  lines.push(["Total de sessoes", data.metrics.total_sessions].map(csvCell).join(","));
  lines.push(["Tempo online", formatSeconds(data.metrics.online_seconds)].map(csvCell).join(","));
  lines.push(["Tempo ocioso", formatSeconds(data.metrics.idle_seconds)].map(csvCell).join(","));
  lines.push(["Tempo em atendimento", formatSeconds(data.metrics.call_seconds)].map(csvCell).join(","));
  lines.push(["Taxa resposta desafios", formatPercent(data.metrics.challenge_response_rate)].map(csvCell).join(","));
  lines.push(["Taxa acerto desafios", formatPercent(data.metrics.challenge_accuracy_rate)].map(csvCell).join(","));
  lines.push("");

  lines.push("Condominios");
  lines.push([
    "Condominio",
    "Operadores ativos",
    "Sessoes",
    "Tempo online",
    "Tempo ocioso",
    "Tempo atendimento",
    "Desafios respondidos",
    "Taxa acerto",
  ].map(csvCell).join(","));
  for (const row of data.condominiums) {
    lines.push([
      row.unit_name,
      row.active_operators,
      row.sessions,
      formatSeconds(row.online_seconds),
      formatSeconds(row.idle_seconds),
      formatSeconds(row.call_seconds),
      row.challenges_answered,
      formatPercent(row.challenge_accuracy_rate),
    ].map(csvCell).join(","));
  }
  lines.push("");

  lines.push("Ranking");
  lines.push([
    "Operador",
    "Condominio",
    "Tempo online",
    "Tempo ocioso",
    "Tempo atendimento",
    "Desafios recebidos",
    "Desafios respondidos",
    "Taxa resposta",
    "Taxa acerto",
    "Ultimo evento",
  ].map(csvCell).join(","));
  for (const row of data.ranking.rows) {
    lines.push([
      row.operator_name,
      row.unit_name,
      formatSeconds(row.online_seconds),
      formatSeconds(row.idle_seconds),
      formatSeconds(row.call_seconds),
      row.challenges_received,
      row.challenges_answered,
      formatPercent(row.challenge_response_rate),
      formatPercent(row.challenge_accuracy_rate),
      formatDateTime(row.last_event_at),
    ].map(csvCell).join(","));
  }

  const blob = new Blob([lines.join("\n")], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = `ptm-analytics-${new Date().toISOString().slice(0, 10)}.csv`;
  anchor.click();
  URL.revokeObjectURL(url);
}

function MetricCard({
  icon,
  label,
  value,
  hint,
  loading,
}: {
  icon: ReactNode;
  label: string;
  value: ReactNode;
  hint?: string;
  loading?: boolean;
}) {
  return (
    <Card className="flex min-h-[94px] items-center gap-3.5 border-border/80 p-3.5 shadow-sm">
      <div className="flex shrink-0 items-center justify-between gap-3">
        <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10 text-primary">
          {icon}
        </div>
      </div>
      <div className="min-w-0 space-y-0.5">
        <p className="truncate text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">{label}</p>
        {loading ? (
          <Skeleton className="h-8 w-24" />
        ) : (
          <p className="truncate font-display text-[21px] font-semibold text-foreground">{value}</p>
        )}
        {hint && <p className="truncate text-xs text-muted-foreground">{hint}</p>}
      </div>
    </Card>
  );
}

function CardsSkeleton() {
  return (
    <>
      {Array.from({ length: 7 }).map((_, i) => (
        <MetricCard key={i} icon={<Loader2 className="h-5 w-5" />} label="Carregando" value="" loading />
      ))}
    </>
  );
}

function metricCards(metrics: AnalyticsMetrics, averageByCondominium = false) {
  const scopeHint = averageByCondominium ? "Média por condomínio" : undefined;
  const formatCount = (value: number) =>
    averageByCondominium ? value.toLocaleString("pt-BR", { maximumFractionDigits: 1 }) : value;

  return [
    {
      icon: <Users className="h-5 w-5" />,
      label: averageByCondominium ? "Média de Operadores ativos" : "Operadores ativos",
      value: formatCount(metrics.active_operators),
      hint: scopeHint ?? "Com sessão no período",
    },
    {
      icon: <Activity className="h-5 w-5" />,
      label: averageByCondominium ? "Média de sessões" : "Total de sessões",
      value: formatCount(metrics.total_sessions),
      hint: scopeHint ?? "Sessões sobrepostas ao filtro",
    },
    {
      icon: <Clock3 className="h-5 w-5" />,
      label: "Tempo total online",
      value: formatSeconds(metrics.online_seconds),
      hint: scopeHint ?? "Derivado de operator_sessions",
    },
    {
      icon: <AlertCircle className="h-5 w-5" />,
      label: "Tempo ocioso",
      value: formatSeconds(metrics.idle_seconds),
      hint: scopeHint ?? "Derivado de operator_status_history",
    },
    {
      icon: <Phone className="h-5 w-5" />,
      label: "Tempo em atendimento",
      value: formatSeconds(metrics.call_seconds),
      hint: scopeHint ?? "Em atendimento no histórico operacional",
    },
    {
      icon: <ShieldCheck className="h-5 w-5" />,
      label: "Resposta desafios",
      value: formatPercent(metrics.challenge_response_rate),
      hint: averageByCondominium ? "Taxa consolidada do período" : metrics.challenges_received ? `${metrics.challenges_answered}/${metrics.challenges_received} respondidos` : "Sem desafios no período",
    },
    {
      icon: <Trophy className="h-5 w-5" />,
      label: "Acerto desafios",
      value: formatPercent(metrics.challenge_accuracy_rate),
      hint: averageByCondominium ? "Taxa consolidada do período" : metrics.challenges_answered ? "Sobre desafios respondidos" : "Sem respostas no período",
    },
  ];
}

export function AnalyticsPage() {
  const [period, setPeriod] = useState<PeriodPreset>("today");
  const [customFrom, setCustomFrom] = useState(todayInput());
  const [customTo, setCustomTo] = useState(todayInput());
  const [unitId, setUnitId] = useState("all");
  const [operatorId, setOperatorId] = useState("all");
  const [shift, setShift] = useState<ShiftFilter>("all");

  const range = useMemo(() => buildPeriodRange(period, customFrom, customTo), [period, customFrom, customTo]);

  const query = useQuery({
    queryKey: ["analytics-dashboard", range.startAt, range.endAt, unitId, operatorId, shift],
    queryFn: () =>
      fetchAnalyticsDashboard({
        startAt: range.startAt,
        endAt: range.endAt,
        unitId,
        operatorId,
        shift,
        rankingPage: 1,
        rankingPageSize: TOP_LIST_LIMIT,
      }),
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  });

  const data = query.data;
  const showCondominiumAverage = unitId === "all" && operatorId === "all";
  const metricsForCards = useMemo(() => {
    if (!data || !showCondominiumAverage || data.condominiums.length === 0) return data?.metrics;

    const condominiumCount = data.condominiums.length;
    return {
      ...data.metrics,
      active_operators: data.metrics.active_operators / condominiumCount,
      total_sessions: data.metrics.total_sessions / condominiumCount,
      online_seconds: data.metrics.online_seconds / condominiumCount,
      idle_seconds: data.metrics.idle_seconds / condominiumCount,
      call_seconds: data.metrics.call_seconds / condominiumCount,
    };
  }, [data, showCondominiumAverage]);
  const chartData = (data?.timeseries ?? []).map((point) => ({
    label: formatBucket(point.bucket_start),
    sessions: point.sessions,
    online: Number((point.online_seconds / 3600).toFixed(2)),
    idle: Number((point.idle_seconds / 3600).toFixed(2)),
    call: Number((point.call_seconds / 3600).toFixed(2)),
  }));
  const statusData = data?.status_breakdown ?? [];
  const totalVisibleOperators = statusData.reduce((total, item) => total + item.count, 0);
  const statusColors: Record<string, string> = { active: "var(--chart-success)", in_call: "var(--chart-challenges)", idle: "var(--chart-warning)", offline: "#94a3b8" };
  const hasAnyOperationalData = Boolean(
    data &&
      (data.metrics.total_sessions > 0 ||
        data.metrics.online_seconds > 0 ||
        data.condominiums.some((row) => row.sessions > 0) ||
        data.ranking.rows.some((row) => row.sessions > 0)),
  );
  const unavailableSources = data?.sources.filter((source) => !source.available) ?? [];

  const units = data?.filter_options.units ?? [];
  const operators = data?.filter_options.operators.filter((op) => unitId === "all" || op.unit_id === unitId) ?? [];
  const shifts = data?.filter_options.shifts ?? [];
  const selectedUnitName = units.find((unit) => unit.id === unitId)?.name;
  const topCondominiums = useMemo(() => {
    return [...(data?.condominiums ?? [])]
      .sort((a, b) => {
        return (
          b.sessions - a.sessions ||
          b.online_seconds - a.online_seconds ||
          b.active_operators - a.active_operators ||
          a.unit_name.localeCompare(b.unit_name, "pt-BR")
        );
      })
      .slice(0, TOP_LIST_LIMIT);
  }, [data?.condominiums]);
  const operatorRankingDescription =
    unitId === "all"
      ? "Top 5 entre todos os condomínios, ordenado por tempo online."
      : `Top 5 de ${selectedUnitName ?? "condomínio selecionado"}, ordenado por tempo online.`;

  return (
    <>
      <PageHeader
        title="Analytics"
        description="Painel operacional com métricas reais de sessões, presença, desafios e status dos Operadores."
      />

      <Card className="sticky top-3 z-20 mb-5 border-border/80 bg-card/95 p-3.5 shadow-sm backdrop-blur-sm">
        <div className="grid gap-3 lg:grid-cols-[160px_minmax(0,1fr)]">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Filtros globais</p>
            <p className="mt-1 text-sm text-muted-foreground">Todos os cards e tabelas usam estes filtros.</p>
          </div>
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
            <Select value={period} onValueChange={(value) => setPeriod(value as PeriodPreset)}>
              <SelectTrigger className="h-10 rounded-lg">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="today">Hoje</SelectItem>
                <SelectItem value="7d">7 dias</SelectItem>
                <SelectItem value="30d">30 dias</SelectItem>
                <SelectItem value="custom">Personalizado</SelectItem>
              </SelectContent>
            </Select>

            {period === "custom" ? (
              <>
                <input
                  type="date"
                  value={customFrom}
                  onChange={(event) => setCustomFrom(event.target.value)}
                  className="h-10 rounded-lg border border-input bg-card px-3 text-sm"
                />
                <input
                  type="date"
                  value={customTo}
                  onChange={(event) => setCustomTo(event.target.value)}
                  className="h-10 rounded-lg border border-input bg-card px-3 text-sm"
                />
              </>
            ) : null}

            <Select value={unitId} onValueChange={setUnitId}>
              <SelectTrigger className="h-10 rounded-lg">
                <SelectValue placeholder="Condomínio" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos os condomínios</SelectItem>
                {units.map((unit) => (
                  <SelectItem key={unit.id} value={unit.id}>
                    {unit.name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <Select value={operatorId} onValueChange={setOperatorId}>
              <SelectTrigger className="h-10 rounded-lg">
                <SelectValue placeholder="Operador" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos os Operadores</SelectItem>
                {operators.map((operator) => (
                  <SelectItem key={operator.id} value={operator.id}>
                    {operator.display_name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>

            <Select value={shift} onValueChange={(value) => setShift(value as ShiftFilter)}>
              <SelectTrigger className="h-10 rounded-lg">
                <SelectValue placeholder="Turno" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos os turnos</SelectItem>
                <SelectItem value="day">Diurno</SelectItem>
                <SelectItem value="night">Noturno</SelectItem>
                <SelectItem value="other">Outro</SelectItem>
                {shifts
                  .filter((option) => !["day", "night", "other"].includes(option.value))
                  .map((option) => (
                    <SelectItem key={option.value} value={option.value}>
                      {option.label}
                    </SelectItem>
                  ))}
              </SelectContent>
            </Select>
          </div>
        </div>
      </Card>

      {query.isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar o Analytics."
            description={(query.error as Error)?.message}
            action={<RetryButton onClick={() => query.refetch()} disabled={query.isFetching} />}
          />
        </Card>
      ) : (
        <>
          {unavailableSources.length > 0 && (
            <div className="mb-5 rounded-lg border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-foreground">
              Algumas métricas foram omitidas por falta de origem real no banco:{" "}
              {unavailableSources.map((source) => source.label).join(", ")}.
            </div>
          )}

          <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
            {query.isLoading || !metricsForCards ? (
              <CardsSkeleton />
            ) : (
              metricCards(metricsForCards, showCondominiumAverage).map((card) => (
                <MetricCard
                  key={card.label}
                  icon={card.icon}
                  label={card.label}
                  value={card.value}
                  hint={card.hint}
                />
              ))
            )}
          </div>

          <div className="mb-5 flex flex-wrap items-center justify-between gap-3">
            <div className="text-sm text-muted-foreground">
              {query.isFetching && !query.isLoading ? "Atualizando dados..." : "Dados agregados diretamente do Supabase."}
            </div>
            <div className="flex gap-2">
              <Button variant="outline" onClick={() => query.refetch()} disabled={query.isFetching}>
                <RotateCcw className="h-4 w-4" />
                Tentar novamente
              </Button>
              <Button onClick={() => data && downloadCsv(data)} disabled={!data || query.isLoading}>
                <Download className="h-4 w-4" />
                Exportar CSV
              </Button>
            </div>
          </div>

          {!query.isLoading && data && !hasAnyOperationalData && (
            <Card className="mb-5 shadow-sm">
              <EmptyState
                icon={<BarChart3 className="h-6 w-6" />}
                title="Nenhum dado operacional no período."
                description="Os contratos existem, mas os filtros atuais não retornaram sessões, status ou desafios reais."
              />
            </Card>
          )}

          <div className="grid gap-5 xl:grid-cols-[minmax(0,1.7fr)_minmax(320px,0.8fr)]">
            <Card className="p-5 shadow-sm">
              <div className="mb-4 flex items-start justify-between gap-3">
                <div>
                  <h2 className="font-display text-lg font-semibold text-foreground">Evolução operacional</h2>
                  <p className="text-sm text-muted-foreground">Sessões e horas por bucket do período filtrado.</p>
                </div>
                <Select defaultValue="8">
                  <SelectTrigger className="h-10 w-[138px]"><SelectValue /></SelectTrigger>
                  <SelectContent><SelectItem value="8">Últimas 8 horas</SelectItem><SelectItem value="24">Últimas 24 horas</SelectItem></SelectContent>
                </Select>
              </div>
              {query.isLoading ? (
                <Skeleton className="h-[320px] w-full" />
              ) : chartData.length === 0 ? (
                <EmptyState title="Sem série temporal." description="Não há sessões reais para montar o gráfico neste período." />
              ) : (
                <div className="h-[320px]">
                  <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={chartData} margin={{ left: 0, right: 8, top: 8, bottom: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="label" tick={{ fontSize: 12 }} />
                      <YAxis yAxisId="left" tick={{ fontSize: 12 }} />
                      <YAxis yAxisId="right" orientation="right" tick={{ fontSize: 12 }} />
                      <Tooltip />
                      <Area yAxisId="left" type="monotone" dataKey="online" name="Horas" stroke="var(--chart-success)" fill="var(--chart-success)" fillOpacity={0.16} dot={{ r: 4 }} />
                      <Line yAxisId="right" type="monotone" dataKey="sessions" name="Sessões" stroke="var(--chart-challenges)" strokeWidth={2} dot={{ r: 5 }} />
                    </AreaChart>
                  </ResponsiveContainer>
                </div>
              )}
            </Card>

            <Card className="p-5 shadow-sm">
              <h2 className="font-display text-lg font-semibold text-foreground">Status operacional <span className="font-normal text-muted-foreground">(agora)</span></h2>
              <p className="mb-4 text-sm text-muted-foreground">Distribuição atual dos Operadores visíveis.</p>
              {query.isLoading ? (
                <Skeleton className="h-[320px] w-full" />
              ) : statusData.length === 0 ? (
                <EmptyState title="Sem status atual." description="A fonte operator_states ainda não retornou dados para os filtros." />
              ) : (
                <div className="h-[320px]">
                  <div className="relative h-[190px] w-full"><ResponsiveContainer width="100%" height="100%"><PieChart><Pie data={statusData} dataKey="count" nameKey="label" innerRadius={62} outerRadius={90} paddingAngle={1} strokeWidth={0}>{statusData.map((item) => <Cell key={item.status} fill={statusColors[item.status] ?? "#94a3b8"} />)}</Pie><Tooltip /></PieChart></ResponsiveContainer><div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center"><strong className="text-3xl">{totalVisibleOperators}</strong><span className="text-xs text-muted-foreground">Total online</span></div></div>
                  <div className="grid w-full grid-cols-2 gap-2 text-sm">{statusData.map((item) => <div key={item.status} className="flex items-center gap-2"><span className="h-3 w-3 rounded-full" style={{ backgroundColor: statusColors[item.status] ?? "#94a3b8" }} /><span className="flex-1">{item.label}</span><span>{item.count}</span><span className="text-muted-foreground">{totalVisibleOperators ? Math.round(item.count / totalVisibleOperators * 100) : 0}%</span></div>)}</div>
                </div>
              )}
            </Card>
          </div>

          <Card className="mt-5 p-5 shadow-sm">
            <h2 className="font-display text-lg font-semibold text-foreground">Top 5 condomínios</h2>
            <p className="mb-4 text-sm text-muted-foreground">Ordenado por sessões e tempo online dentro dos filtros atuais.</p>
            {query.isLoading ? (
              <TableSkeleton columns={8} />
            ) : topCondominiums.length === 0 ? (
              <EmptyState title="Nenhum condomínio com dados." description="Ajuste os filtros ou aguarde registros operacionais reais." />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[980px] text-sm">
                  <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <tr className="border-b">
                      <th className="py-3 pr-4">Condomínio</th>
                      <th className="py-3 pr-4">Operadores ativos</th>
                      <th className="py-3 pr-4">Sessões</th>
                      <th className="py-3 pr-4">Online</th>
                      <th className="py-3 pr-4">Ocioso</th>
                      <th className="py-3 pr-4">Atendimento</th>
                      <th className="py-3 pr-4">Desafios respondidos</th>
                      <th className="py-3 pr-4">Taxa acerto</th>
                    </tr>
                  </thead>
                  <tbody>
                    {topCondominiums.map((row) => (
                      <tr key={row.unit_id} className="border-b last:border-0">
                        <td className="py-3 pr-4 font-medium">{row.unit_name}</td>
                        <td className="py-3 pr-4">{row.active_operators}</td>
                        <td className="py-3 pr-4">{row.sessions}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.online_seconds)}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.idle_seconds)}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.call_seconds)}</td>
                        <td className="py-3 pr-4">{row.challenges_answered}</td>
                        <td className="py-3 pr-4">{formatPercent(row.challenge_accuracy_rate)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <Card className="mt-5 p-5 shadow-sm">
            <h2 className="font-display text-lg font-semibold text-foreground">Top 5 Operadores</h2>
            <p className="mb-4 text-sm text-muted-foreground">{operatorRankingDescription}</p>
            {query.isLoading ? (
              <TableSkeleton columns={10} />
            ) : data?.ranking.rows.length === 0 ? (
              <EmptyState title="Nenhum Operador no ranking." description="Não há Operadores com acesso dentro dos filtros aplicados." />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[1180px] text-sm">
                  <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <tr className="border-b">
                      <th className="py-3 pr-4">Operador</th>
                      <th className="py-3 pr-4">Condomínio</th>
                      <th className="py-3 pr-4">Online</th>
                      <th className="py-3 pr-4">Ocioso</th>
                      <th className="py-3 pr-4">Atendimento</th>
                      <th className="py-3 pr-4">Recebidos</th>
                      <th className="py-3 pr-4">Respondidos</th>
                      <th className="py-3 pr-4">Resposta</th>
                      <th className="py-3 pr-4">Acerto</th>
                      <th className="py-3 pr-4">Último evento/sessão</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data?.ranking.rows.map((row) => (
                      <tr key={row.operator_id} className="border-b last:border-0">
                        <td className="py-3 pr-4 font-medium">{row.operator_name}</td>
                        <td className="py-3 pr-4">{row.unit_name ?? "-"}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.online_seconds)}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.idle_seconds)}</td>
                        <td className="py-3 pr-4">{formatSeconds(row.call_seconds)}</td>
                        <td className="py-3 pr-4">{row.challenges_received}</td>
                        <td className="py-3 pr-4">{row.challenges_answered}</td>
                        <td className="py-3 pr-4">{formatPercent(row.challenge_response_rate)}</td>
                        <td className="py-3 pr-4">{formatPercent(row.challenge_accuracy_rate)}</td>
                        <td className="py-3 pr-4">{formatDateTime(row.last_event_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>
        </>
      )}
    </>
  );
}

function TableSkeleton({ columns }: { columns: number }) {
  return (
    <div className="space-y-3">
      {Array.from({ length: 5 }).map((_, row) => (
        <div key={row} className="grid gap-3" style={{ gridTemplateColumns: `repeat(${columns}, minmax(80px, 1fr))` }}>
          {Array.from({ length: columns }).map((__, col) => (
            <Skeleton key={col} className="h-8 w-full" />
          ))}
        </div>
      ))}
    </div>
  );
}
