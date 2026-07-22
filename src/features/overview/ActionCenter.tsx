import type { ReactNode } from "react";
import { AlertTriangle, ArrowRight, CheckCircle2, Clock3, MessageSquare, Music, ServerCog } from "lucide-react";
import { Link } from "react-router-dom";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import {
  fmtDuration,
  fmtRelative,
  minutesSince,
  type OverviewActionCenter as OverviewActionCenterData,
  type OverviewPendingAction,
} from "./queries";

type SlaState = {
  label: string;
  detail: string;
  tone: "success" | "warning" | "danger";
};

const SLA_MINUTES = {
  playlist: { target: 4 * 60, critical: 24 * 60 },
  feedback: { target: 24 * 60, critical: 72 * 60 },
} as const;

function durationFromMinutes(minutes: number): string {
  const reference = new Date(Date.now() - Math.max(0, minutes) * 60_000).toISOString();
  return fmtDuration(reference);
}

function slaState(item: OverviewPendingAction): SlaState {
  const age = minutesSince(item.occurred_at) ?? 0;
  const limits = SLA_MINUTES[item.kind];
  if (age >= limits.critical) {
    return {
      label: "Crítico",
      detail: `SLA ultrapassado há ${durationFromMinutes(age - limits.target)}`,
      tone: "danger",
    };
  }
  if (age >= limits.target) {
    return {
      label: "Atenção",
      detail: `SLA ultrapassado há ${durationFromMinutes(age - limits.target)}`,
      tone: "warning",
    };
  }
  return {
    label: "No prazo",
    detail: `${durationFromMinutes(limits.target - age)} restantes no SLA`,
    tone: "success",
  };
}

function SlaBadge({ state }: { state: SlaState }) {
  return (
    <Badge
      variant="outline"
      className={cn(
        "shrink-0",
        state.tone === "danger" && "border-destructive/30 bg-destructive/10 text-destructive",
        state.tone === "warning" && "border-warning/40 bg-warning/10 text-warning-foreground",
        state.tone === "success" && "border-success/40 bg-success/15 text-success-foreground",
      )}
    >
      {state.label}
    </Badge>
  );
}

function PendingActionCard({
  icon,
  title,
  count,
  item,
  emptyText,
  actionLabel,
  to,
}: {
  icon: ReactNode;
  title: string;
  count: number | null;
  item: OverviewPendingAction | null;
  emptyText: string;
  actionLabel: string;
  to: string;
}) {
  const state = item ? slaState(item) : null;
  const context = [item?.operator_name, item?.unit_label].filter(Boolean).join(" · ");

  return (
    <Card className={cn("h-full border-border/80 shadow-sm", state?.tone === "danger" && "border-destructive/35")}>
      <CardHeader className="pb-3">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-warning/15 text-warning-foreground">
              {icon}
            </div>
            <div>
              <CardTitle className="text-sm font-semibold">{title}</CardTitle>
              <p className="mt-0.5 text-xs text-muted-foreground">
                {count == null ? "Contagem indisponível" : `${count} aguardando tratamento`}
              </p>
            </div>
          </div>
          {state && <SlaBadge state={state} />}
        </div>
      </CardHeader>
      <CardContent className="flex min-h-[154px] flex-col">
        {item ? (
          <>
            <div className="rounded-lg border border-border bg-muted/30 p-3">
              <p className="line-clamp-2 text-sm font-medium text-foreground">{item.title}</p>
              {context && <p className="mt-1 truncate text-xs text-muted-foreground">{context}</p>}
              <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs">
                <span className="flex items-center gap-1.5 font-medium text-foreground">
                  <Clock3 className="h-3.5 w-3.5 text-muted-foreground" />
                  Aguardando {fmtDuration(item.occurred_at)}
                </span>
                {state && <span className="text-muted-foreground">{state.detail}</span>}
              </div>
            </div>
            <Button asChild size="sm" className="mt-auto self-start">
              <Link to={to}>
                {actionLabel} <ArrowRight className="h-4 w-4" />
              </Link>
            </Button>
          </>
        ) : (
          <div className="flex flex-1 flex-col items-center justify-center gap-2 rounded-lg border border-success/25 bg-success/10 px-4 py-5 text-center">
            <CheckCircle2 className="h-6 w-6 text-success-foreground" />
            <p className="text-sm font-medium text-success-foreground">{emptyText}</p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}

function IntegrationHealthCard({ data }: { data: OverviewActionCenterData["imports"] }) {
  const active = data.queued + data.running;
  const inactiveMinutes = minutesSince(data.last_activity_at);
  const possiblyStalled = active > 0 && (inactiveMinutes == null || inactiveMinutes >= 15);
  const hasErrors = data.with_errors > 0;
  const title = hasErrors ? "Falhas de importação" : possiblyStalled ? "Possível fila parada" : active > 0 ? "Fila em processamento" : "Integrações estáveis";
  const description = hasErrors
    ? `${data.with_errors} falha(s) aguardando tratamento.`
    : possiblyStalled
      ? "Há itens ativos sem atualização recente. Verifique o Worker."
      : active > 0
        ? "O importador está trabalhando normalmente."
        : "Nenhuma fila ou falha exige ação agora.";

  return (
    <Card className={cn("h-full border-border/80 shadow-sm", hasErrors && "border-destructive/35", possiblyStalled && !hasErrors && "border-warning/40")}>
      <CardHeader className="pb-3">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className={cn("flex h-10 w-10 shrink-0 items-center justify-center rounded-lg", hasErrors ? "bg-destructive/10 text-destructive" : possiblyStalled ? "bg-warning/15 text-warning-foreground" : "bg-primary/10 text-primary")}>
              {hasErrors || possiblyStalled ? <AlertTriangle className="h-5 w-5" /> : <ServerCog className="h-5 w-5" />}
            </div>
            <div>
              <CardTitle className="text-sm font-semibold">Saúde das integrações</CardTitle>
              <p className="mt-0.5 text-xs text-muted-foreground">Visão geral do importador</p>
            </div>
          </div>
          <Badge variant="outline" className={cn(hasErrors && "border-destructive/30 bg-destructive/10 text-destructive", possiblyStalled && !hasErrors && "border-warning/40 bg-warning/10 text-warning-foreground", !hasErrors && !possiblyStalled && "border-success/40 bg-success/15 text-success-foreground")}>
            {hasErrors ? "Falha" : possiblyStalled ? "Atenção" : "Normal"}
          </Badge>
        </div>
      </CardHeader>
      <CardContent className="flex min-h-[154px] flex-col">
        <div>
          <p className="text-sm font-semibold text-foreground">{title}</p>
          <p className="mt-1 text-xs leading-relaxed text-muted-foreground">{description}</p>
          <div className="mt-3 grid grid-cols-3 gap-2 text-center">
            <div className="rounded-md bg-muted/55 px-2 py-2"><strong className="block text-lg tabular-nums">{data.queued}</strong><span className="text-[10px] text-muted-foreground">Na fila</span></div>
            <div className="rounded-md bg-muted/55 px-2 py-2"><strong className="block text-lg tabular-nums">{data.running}</strong><span className="text-[10px] text-muted-foreground">Processando</span></div>
            <div className="rounded-md bg-muted/55 px-2 py-2"><strong className={cn("block text-lg tabular-nums", hasErrors && "text-destructive")}>{data.with_errors}</strong><span className="text-[10px] text-muted-foreground">Com erro</span></div>
          </div>
          <p className="mt-2 text-xs text-muted-foreground">Última atividade {data.last_activity_at ? fmtRelative(data.last_activity_at) : "não informada"}</p>
        </div>
        <Button asChild size="sm" variant={hasErrors || possiblyStalled ? "default" : "outline"} className="mt-auto self-start">
          <Link to="/integracao">
            {hasErrors ? "Ver falhas" : "Ver integrações"} <ArrowRight className="h-4 w-4" />
          </Link>
        </Button>
      </CardContent>
    </Card>
  );
}

export function ActionCenter({
  data,
  pendingFeedback,
  pendingPlaylists,
  loading,
  error,
}: {
  data: OverviewActionCenterData | undefined;
  pendingFeedback: number;
  pendingPlaylists: number | null;
  loading: boolean;
  error: boolean;
}) {
  const activeImports = (data?.imports.queued ?? 0) + (data?.imports.running ?? 0);
  const possiblyStalled = activeImports > 0 && (minutesSince(data?.imports.last_activity_at ?? null) ?? Number.POSITIVE_INFINITY) >= 15;
  const actionCount = pendingFeedback + (pendingPlaylists ?? 0) + (data?.imports.with_errors ?? 0) + (possiblyStalled ? 1 : 0);

  return (
    <section id="central-de-acao" className="mb-5 scroll-mt-24" aria-labelledby="central-de-acao-title">
      <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-[10px] font-bold uppercase tracking-[0.16em] text-primary">Prioridades operacionais</p>
          <h2 id="central-de-acao-title" className="mt-1 font-display text-xl font-semibold text-foreground">Central de ação</h2>
          <p className="mt-1 text-sm text-muted-foreground">Comece pelas pendências mais antigas e pelos sinais que exigem intervenção.</p>
        </div>
        {!loading && !error && (
          <Badge variant="secondary" className="w-fit px-3 py-1 text-xs tabular-nums">
            {actionCount === 0 ? "Tudo em dia" : actionCount === 1 ? "1 ação pendente" : `${actionCount} ações pendentes`}
          </Badge>
        )}
      </div>

      {loading ? (
        <div className="grid gap-4 lg:grid-cols-3">
          {Array.from({ length: 3 }).map((_, index) => <Skeleton key={index} className="h-[268px] rounded-xl" />)}
        </div>
      ) : error || !data ? (
        <Card className="border-warning/35 bg-warning/5 shadow-sm">
          <CardContent className="flex items-start gap-3 p-5">
            <AlertTriangle className="mt-0.5 h-5 w-5 shrink-0 text-warning-foreground" />
            <div><p className="text-sm font-semibold">Não foi possível priorizar as pendências.</p><p className="mt-1 text-xs text-muted-foreground">Use Atualizar dados para tentar novamente. Os demais indicadores continuam disponíveis.</p></div>
          </CardContent>
        </Card>
      ) : (
        <div className="grid gap-4 lg:grid-cols-3">
          <PendingActionCard icon={<Music className="h-5 w-5" />} title="Playlists para revisar" count={pendingPlaylists} item={data.oldest_playlist} emptyText="Nenhuma playlist aguardando revisão." actionLabel="Revisar playlists" to="/musicas?status=pending&period=90d" />
          <PendingActionCard icon={<MessageSquare className="h-5 w-5" />} title="Feedbacks para resolver" count={pendingFeedback} item={data.oldest_feedback} emptyText="Nenhum feedback novo aguardando tratamento." actionLabel="Resolver feedbacks" to="/feedback?status=new" />
          <IntegrationHealthCard data={data.imports} />
        </div>
      )}
    </section>
  );
}
