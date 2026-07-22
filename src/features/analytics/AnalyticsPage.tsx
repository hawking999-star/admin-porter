import { useMemo, useState, type ReactNode } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Area,
  AreaChart,
  Cell,
  CartesianGrid,
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
  PhoneIncoming,
  RotateCcw,
  ShieldCheck,
  Trophy,
  Users,
} from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { EmptyState, ErrorState, PeriodFilter, RetryButton } from "@/components/shared";
import { todayInput, type PeriodPreset } from "@/lib/period";
import { errorMessage } from "@/lib/errors";
import { resetStatistics, type StatisticsResetCategory } from "@/lib/statistics";
import { unitLabel } from "@/lib/unit-label";
import {
  buildPeriodRange,
  fetchAnalyticsDashboard,
  formatBucket,
  formatDateTime,
  formatPercent,
  formatSeconds,
  type AnalyticsDashboard,
  type AnalyticsMetrics,
  type ShiftFilter,
} from "./queries";

const TOP_LIST_LIMIT = 5;
const RESET_OPTIONS: Array<{ value: StatisticsResetCategory; label: string; description: string }> = [
  { value: "sessions", label: "Sessões e tempos", description: "Sessões, tempo online, ocioso e em atendimento." },
  { value: "calls", label: "Ligações atendidas", description: "Contagem de ligações atendidas pelos Operadores." },
  { value: "challenges", label: "Desafios", description: "Recebidos, respondidos, aproveitamento e ranking." },
  { value: "attention", label: "Atenção operacional", description: "Ocorrências de ociosidade e bloqueios." },
];

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
  lines.push(["Ligacoes atendidas", data.metrics.answered_calls].map(csvCell).join(","));
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
    "Desafios",
    "Acertos",
    "Aproveitamento",
    "Ultimo desafio",
  ].map(csvCell).join(","));
  for (const row of data.ranking.rows) {
    lines.push([
      row.operator_name,
      unitLabel({ name: row.unit_name, city: row.unit_city, state: row.unit_state, code: row.unit_code }),
      row.challenges_answered,
      row.challenges_correct,
      formatPercent(row.challenge_accuracy_rate),
      formatDateTime(row.last_challenge_at),
    ].map(csvCell).join(","));
  }
  lines.push("");

  lines.push("Pontos de atencao - ociosidade");
  lines.push(["Operador", "Condominio", "Tempo ocioso", "Entradas em ociosidade", "Ultima ociosidade"].map(csvCell).join(","));
  for (const row of data.attention_ranking.idle) {
    lines.push([
      row.operator_name,
      unitLabel({ name: row.unit_name, city: row.unit_city, state: row.unit_state, code: row.unit_code }),
      formatSeconds(row.idle_seconds),
      row.idle_events,
      formatDateTime(row.last_idle_at),
    ].map(csvCell).join(","));
  }
  lines.push("");

  lines.push("Pontos de atencao - bloqueios");
  lines.push(["Operador", "Condominio", "Bloqueios", "Tempo bloqueado", "Ultimo bloqueio"].map(csvCell).join(","));
  for (const row of data.attention_ranking.blocked) {
    lines.push([
      row.operator_name,
      unitLabel({ name: row.unit_name, city: row.unit_city, state: row.unit_state, code: row.unit_code }),
      row.block_count,
      formatSeconds(row.blocked_seconds),
      formatDateTime(row.last_block_at),
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
      {Array.from({ length: 8 }).map((_, i) => (
        <MetricCard key={i} icon={<Loader2 className="h-5 w-5" />} label="Carregando" value="" loading />
      ))}
    </>
  );
}

function metricCards(metrics: AnalyticsMetrics) {
  return [
    {
      icon: <Users className="h-5 w-5" />,
      label: "Operadores ativos",
      value: metrics.active_operators,
      hint: "Total no período filtrado",
    },
    {
      icon: <Activity className="h-5 w-5" />,
      label: "Total de sessões",
      value: metrics.total_sessions,
      hint: "Total no período filtrado",
    },
    {
      icon: <Clock3 className="h-5 w-5" />,
      label: "Tempo total online",
      value: formatSeconds(metrics.online_seconds),
      hint: "Total no período filtrado",
    },
    {
      icon: <AlertCircle className="h-5 w-5" />,
      label: "Tempo ocioso",
      value: formatSeconds(metrics.idle_seconds),
      hint: "Total no período filtrado",
    },
    {
      icon: <Phone className="h-5 w-5" />,
      label: "Tempo em atendimento",
      value: formatSeconds(metrics.call_seconds),
      hint: "Total no período filtrado",
    },
    {
      icon: <PhoneIncoming className="h-5 w-5" />,
      label: "Ligações atendidas",
      value: metrics.answered_calls,
      hint: "Total no período filtrado",
    },
    {
      icon: <ShieldCheck className="h-5 w-5" />,
      label: "Desafios respondidos",
      value: formatPercent(metrics.challenge_response_rate),
      hint: metrics.challenges_received ? `${metrics.challenges_answered}/${metrics.challenges_received} respondidos` : "Sem desafios no período",
    },
    {
      icon: <Trophy className="h-5 w-5" />,
      label: "Aproveitamento",
      value: formatPercent(metrics.challenge_accuracy_rate),
      hint: metrics.challenges_answered ? "Sobre desafios respondidos" : "Sem respostas no período",
    },
  ];
}

export function AnalyticsPage() {
  const queryClient = useQueryClient();
  const [period, setPeriod] = useState<PeriodPreset>("7d");
  const [customFrom, setCustomFrom] = useState(todayInput());
  const [customTo, setCustomTo] = useState(todayInput());
  const [unitId, setUnitId] = useState("all");
  const [operatorId, setOperatorId] = useState("all");
  const [shift, setShift] = useState<ShiftFilter>("all");
  const [attentionMode, setAttentionMode] = useState<"idle" | "blocked">("idle");
  const [resetOpen, setResetOpen] = useState(false);
  const [resetCategories, setResetCategories] = useState<StatisticsResetCategory[]>(
    RESET_OPTIONS.map((option) => option.value),
  );

  const resetMutation = useMutation({
    mutationFn: (categories: StatisticsResetCategory[]) => resetStatistics(categories),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["analytics-dashboard"] }),
        queryClient.invalidateQueries({ queryKey: ["overview"] }),
      ]);
      setResetOpen(false);
      toast.success("Estatísticas selecionadas zeradas. O histórico foi preservado para auditoria.");
    },
    onError: (error) => toast.error(errorMessage(error, "Não foi possível zerar as estatísticas.")),
  });

  const query = useQuery({
    queryKey: ["analytics-dashboard", period, customFrom, customTo, unitId, operatorId, shift],
    queryFn: () => {
      const currentRange = buildPeriodRange(period, customFrom, customTo);
      return fetchAnalyticsDashboard({
        startAt: currentRange.startAt,
        endAt: currentRange.endAt,
        unitId,
        operatorId,
        shift,
        rankingPage: 1,
        rankingPageSize: TOP_LIST_LIMIT,
      });
    },
    staleTime: 30_000,
    refetchInterval: 15_000,
    placeholderData: keepPreviousData,
  });

  const data = query.data;
  const chartData = (data?.timeseries ?? []).map((point) => ({
    label: formatBucket(point.bucket_start),
    idle: Number((point.idle_seconds / 3600).toFixed(2)),
  }));
  const statusData = data?.status_breakdown ?? [];
  const totalVisibleOperators = statusData.reduce((total, item) => total + item.count, 0);
  const statusColors: Record<string, string> = { active: "var(--chart-success)", in_call: "var(--chart-challenges)", idle: "var(--chart-warning)", offline: "#94a3b8" };
  const hasAnyOperationalData = Boolean(
    data &&
      (data.metrics.total_sessions > 0 ||
        data.metrics.online_seconds > 0 ||
        data.condominiums.some((row) => row.sessions > 0) ||
        data.ranking.rows.some((row) => row.challenges_answered > 0)),
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
      ? "Top 5 por aproveitamento nos desafios; em empate, vence quem respondeu mais."
      : `Top 5 de ${selectedUnitName ?? "condomínio selecionado"} por aproveitamento nos desafios.`;
  const attentionRows = data?.attention_ranking[attentionMode] ?? [];

  return (
    <>
      <PageHeader
        title="Analytics"
        description="Painel operacional com métricas reais de sessões, presença, desafios e status dos Operadores."
        action={
          <Button variant="outline" size="sm" disabled={resetMutation.isPending} onClick={() => setResetOpen(true)}>
            {resetMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />}
            Zerar estatísticas
          </Button>
        }
      />

      <Dialog open={resetOpen} onOpenChange={(open) => !resetMutation.isPending && setResetOpen(open)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>Escolha quais estatísticas zerar</DialogTitle>
            <DialogDescription>
              O reset é não destrutivo: os relatórios passam a contar a partir de agora e o histórico permanece na Auditoria. Condomínios e usuários nunca são alterados.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2">
            {RESET_OPTIONS.map((option) => {
              const checked = resetCategories.includes(option.value);
              return (
                <label key={option.value} className="flex cursor-pointer items-start gap-3 rounded-lg border border-border p-3 hover:bg-muted/40">
                  <Checkbox
                    checked={checked}
                    onCheckedChange={(next) => {
                      setResetCategories((current) =>
                        next ? [...new Set([...current, option.value])] : current.filter((value) => value !== option.value),
                      );
                    }}
                    aria-label={`Zerar ${option.label}`}
                  />
                  <span>
                    <span className="block text-sm font-semibold">{option.label}</span>
                    <span className="block text-xs text-muted-foreground">{option.description}</span>
                  </span>
                </label>
              );
            })}
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setResetOpen(false)} disabled={resetMutation.isPending}>Cancelar</Button>
            <Button
              variant="destructive"
              disabled={!resetCategories.length || resetMutation.isPending}
              onClick={() => resetMutation.mutate(resetCategories)}
            >
              {resetMutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              Zerar selecionadas
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Card className="sticky top-3 z-20 mb-5 border-border/80 bg-card/95 p-3.5 shadow-sm backdrop-blur-sm">
        <div className="grid gap-3 lg:grid-cols-[160px_minmax(0,1fr)]">
          <div>
            <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Filtros globais</p>
            <p className="mt-1 text-sm text-muted-foreground">Todos os cards e tabelas usam estes filtros.</p>
          </div>
          <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
            <PeriodFilter
              value={period}
              customFrom={customFrom}
              customTo={customTo}
              onValueChange={setPeriod}
              onCustomFromChange={setCustomFrom}
              onCustomToChange={setCustomTo}
            />

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
                    {operator.registered_name ?? "Operador sem nome cadastral"}
                    {operator.username ? ` · @${operator.username}` : ""}
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
            {query.isLoading || !data ? (
              <CardsSkeleton />
            ) : (
              metricCards(data.metrics).map((card) => (
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
              {query.isFetching && !query.isLoading
                ? "Atualizando dados..."
                : data?.statistics_reset_at
                  ? `Estatísticas contadas desde ${formatDateTime(data.statistics_reset_at)}.`
                  : "Dados agregados diretamente do Supabase."}
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
                  <h2 className="font-display text-lg font-semibold text-foreground">Ociosidade operacional</h2>
                  <p className="text-sm text-muted-foreground">Tempo ocioso por intervalo do período filtrado.</p>
                </div>
              </div>
              {query.isLoading ? (
                <Skeleton className="h-[320px] w-full" />
              ) : chartData.length === 0 ? (
                <EmptyState title="Sem ociosidade registrada." description="Não há histórico operacional real para montar o gráfico neste período." />
              ) : (
                <div className="h-[320px]">
                  <ResponsiveContainer width="100%" height="100%">
                    <AreaChart data={chartData} margin={{ left: 0, right: 8, top: 8, bottom: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--border)" />
                      <XAxis dataKey="label" tick={{ fontSize: 12 }} />
                      <YAxis tick={{ fontSize: 12 }} tickFormatter={(value) => `${value}h`} />
                      <Tooltip
                        formatter={(value) => [formatSeconds(Number(value) * 3600), "Tempo ocioso"]}
                      />
                      <Area
                        type="monotone"
                        dataKey="idle"
                        name="Tempo ocioso"
                        stroke="var(--chart-warning)"
                        fill="var(--chart-warning)"
                        fillOpacity={0.18}
                        strokeWidth={2}
                        dot={{ r: 4 }}
                      />
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
            <h2 className="font-display text-lg font-semibold text-foreground">Melhores em desafios</h2>
            <p className="mb-4 text-sm text-muted-foreground">{operatorRankingDescription}</p>
            {query.isLoading ? (
              <TableSkeleton columns={6} />
            ) : data?.ranking.rows.length === 0 ? (
              <EmptyState title="Nenhum resultado no ranking." description="Ainda não há desafios respondidos dentro dos filtros aplicados." />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[760px] text-sm">
                  <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <tr className="border-b">
                      <th className="py-3 pr-4">Operador</th>
                      <th className="py-3 pr-4">Condomínio</th>
                      <th className="py-3 pr-4">Desafios</th>
                      <th className="py-3 pr-4">Acertos</th>
                      <th className="py-3 pr-4">Aproveitamento</th>
                      <th className="py-3 pr-4">Último desafio</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data?.ranking.rows.map((row) => (
                      <tr key={row.operator_id} className="border-b last:border-0">
                        <td className="py-3 pr-4 font-medium">{row.operator_name}</td>
                        <td className="py-3 pr-4">{unitLabel({ name: row.unit_name, city: row.unit_city, state: row.unit_state, code: row.unit_code })}</td>
                        <td className="py-3 pr-4">{row.challenges_answered}</td>
                        <td className="py-3 pr-4">{row.challenges_correct}</td>
                        <td className="py-3 pr-4">{formatPercent(row.challenge_accuracy_rate)}</td>
                        <td className="py-3 pr-4">{formatDateTime(row.last_challenge_at)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Card>

          <Card className="mt-5 p-5 shadow-sm">
            <div className="mb-4 flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 className="font-display text-lg font-semibold text-foreground">Top 5 — Pontos de atenção</h2>
                <p className="text-sm text-muted-foreground">
                  {attentionMode === "idle"
                    ? "Operadores com mais tempo total em ociosidade dentro dos filtros."
                    : "Operadores que mais receberam bloqueios dentro dos filtros."}
                </p>
              </div>
              <div className="flex gap-2" aria-label="Alternar ranking de atenção">
                <Button
                  size="sm"
                  variant={attentionMode === "idle" ? "default" : "outline"}
                  onClick={() => setAttentionMode("idle")}
                >
                  Mais ociosos
                </Button>
                <Button
                  size="sm"
                  variant={attentionMode === "blocked" ? "default" : "outline"}
                  onClick={() => setAttentionMode("blocked")}
                >
                  Mais bloqueados
                </Button>
              </div>
            </div>
            {query.isLoading ? (
              <TableSkeleton columns={5} />
            ) : attentionRows.length === 0 ? (
              <EmptyState
                title={attentionMode === "idle" ? "Nenhuma ociosidade no período." : "Nenhum bloqueio no período."}
                description="Não há ocorrências reais dentro dos filtros aplicados."
              />
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full min-w-[720px] text-sm">
                  <thead className="text-left text-xs uppercase tracking-wide text-muted-foreground">
                    <tr className="border-b">
                      <th className="py-3 pr-4">Operador</th>
                      <th className="py-3 pr-4">Condomínio</th>
                      <th className="py-3 pr-4">{attentionMode === "idle" ? "Tempo ocioso" : "Bloqueios"}</th>
                      <th className="py-3 pr-4">{attentionMode === "idle" ? "Ocorrências" : "Tempo bloqueado"}</th>
                      <th className="py-3 pr-4">Última ocorrência</th>
                    </tr>
                  </thead>
                  <tbody>
                    {attentionRows.map((row) => (
                      <tr key={row.operator_id} className="border-b last:border-0">
                        <td className="py-3 pr-4 font-medium">{row.operator_name}</td>
                        <td className="py-3 pr-4">{unitLabel({ name: row.unit_name, city: row.unit_city, state: row.unit_state, code: row.unit_code })}</td>
                        <td className="py-3 pr-4">{attentionMode === "idle" ? formatSeconds(row.idle_seconds) : row.block_count}</td>
                        <td className="py-3 pr-4">{attentionMode === "idle" ? row.idle_events : formatSeconds(row.blocked_seconds)}</td>
                        <td className="py-3 pr-4">{formatDateTime(attentionMode === "idle" ? row.last_idle_at : row.last_block_at)}</td>
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
