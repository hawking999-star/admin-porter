import { useQuery } from "@tanstack/react-query";
import {
  Building2,
  Users,
  Radio,
  MessageSquare,
  Shield,
  Clock,
  Circle,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Badge } from "@/components/ui/badge";
import {
  fetchOverviewCounts,
  fetchOperatorStatuses,
  fetchRecentActivity,
  statusLabel,
  type StatusGroup,
  type RecentActivity,
} from "./queries";

/* -------------------------------- Helpers -------------------------------- */

function fmtRelative(iso: string) {
  const diff = Date.now() - new Date(iso).getTime();
  const mins = Math.floor(diff / 60_000);
  if (mins < 1) return "agora";
  if (mins < 60) return `${mins}min`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h`;
  const days = Math.floor(hrs / 24);
  return `${days}d`;
}

const STATUS_DOT: Record<string, string> = {
  active: "text-success",
  in_call: "text-primary",
  idle: "text-warning",
  blocked: "text-destructive",
  outside_shift: "text-muted-foreground",
  offline: "text-muted-foreground/40",
};

/* ------------------------------ Stat Card ------------------------------- */

function StatCard({
  icon,
  label,
  value,
  iconClass,
  loading,
}: {
  icon: React.ReactNode;
  label: string;
  value: number | string;
  iconClass: string;
  loading?: boolean;
}) {
  return (
    <Card className="shadow-sm">
      <CardContent className="flex items-center gap-4 p-5">
        <div className={cn("flex h-11 w-11 shrink-0 items-center justify-center rounded-xl", iconClass)}>
          {icon}
        </div>
        <div>
          {loading ? (
            <Skeleton className="mb-1 h-7 w-10" />
          ) : (
            <div className="text-2xl font-bold leading-none tracking-tight">{value}</div>
          )}
          <div className="mt-1 text-xs text-muted-foreground">{label}</div>
        </div>
      </CardContent>
    </Card>
  );
}

/* -------------------------- Status Operadores --------------------------- */

function StatusSection({ groups, loading }: { groups: StatusGroup[]; loading: boolean }) {
  if (loading) {
    return (
      <Card className="shadow-sm">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm font-semibold">Status dos operadores</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <Skeleton key={i} className="h-8 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  const total = groups.reduce((s, g) => s + g.count, 0);

  return (
    <Card className="shadow-sm">
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between">
          <CardTitle className="text-sm font-semibold">Status dos operadores</CardTitle>
          <span className="text-xs text-muted-foreground">{total} registrados</span>
        </div>
      </CardHeader>
      <CardContent className="space-y-2">
        {groups.map((g) => (
          <div
            key={g.status}
            className="flex items-center justify-between rounded-lg px-3 py-2 transition-colors hover:bg-muted/50"
          >
            <div className="flex items-center gap-2.5">
              <Circle className={cn("h-2.5 w-2.5 fill-current", STATUS_DOT[g.status] ?? "text-muted-foreground")} />
              <span className="text-sm">{g.label}</span>
            </div>
            <Badge variant="secondary" className="min-w-[2rem] justify-center font-mono text-xs">
              {g.count}
            </Badge>
          </div>
        ))}

        {/* mini-bar visual */}
        {total > 0 && (
          <div className="flex h-2 overflow-hidden rounded-full bg-muted mt-2">
            {groups
              .filter((g) => g.count > 0)
              .map((g) => {
                const pct = (g.count / total) * 100;
                const colors: Record<string, string> = {
                  active: "bg-success",
                  in_call: "bg-primary",
                  idle: "bg-warning",
                  blocked: "bg-destructive",
                  outside_shift: "bg-muted-foreground/30",
                  offline: "bg-muted-foreground/20",
                };
                return (
                  <div
                    key={g.status}
                    className={cn("transition-all", colors[g.status] ?? "bg-muted-foreground/20")}
                    style={{ width: `${pct}%` }}
                    title={`${g.label}: ${g.count}`}
                  />
                );
              })}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

/* -------------------------- Atividade Recente ---------------------------- */

function ActivitySection({ items, loading }: { items: RecentActivity[]; loading: boolean }) {
  if (loading) {
    return (
      <Card className="shadow-sm">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm font-semibold">Atividade recente</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          {Array.from({ length: 5 }).map((_, i) => (
            <Skeleton key={i} className="h-10 w-full" />
          ))}
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="shadow-sm">
      <CardHeader className="pb-3">
        <CardTitle className="text-sm font-semibold">Atividade recente</CardTitle>
      </CardHeader>
      <CardContent>
        {items.length === 0 ? (
          <p className="py-8 text-center text-sm text-muted-foreground">Nenhuma atividade registrada.</p>
        ) : (
          <div className="space-y-1">
            {items.map((item) => (
              <div
                key={item.id}
                className="flex items-start gap-3 rounded-lg px-3 py-2.5 transition-colors hover:bg-muted/50"
              >
                <div className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-muted">
                  {item.kind === "audit" ? (
                    <Shield className="h-3.5 w-3.5 text-muted-foreground" />
                  ) : (
                    <Clock className="h-3.5 w-3.5 text-muted-foreground" />
                  )}
                </div>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-medium">{item.title}</div>
                  {item.detail && (
                    <div className="truncate text-xs text-muted-foreground">{item.detail}</div>
                  )}
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

/* -------------------------------- Página -------------------------------- */

export function OverviewPage() {
  const counts = useQuery({
    queryKey: ["overview", "counts"],
    queryFn: fetchOverviewCounts,
    staleTime: 30_000,
  });

  const statuses = useQuery({
    queryKey: ["overview", "statuses"],
    queryFn: fetchOperatorStatuses,
    staleTime: 15_000,
  });

  const activity = useQuery({
    queryKey: ["overview", "activity"],
    queryFn: fetchRecentActivity,
    staleTime: 30_000,
  });

  return (
    <>
      <PageHeader title="Visão Geral" description="Resumo da operação em tempo real." />

      {/* Cards de resumo */}
      <div className="mb-6 grid grid-cols-2 gap-4 lg:grid-cols-4">
        <StatCard
          icon={<Building2 className="h-5 w-5" />}
          label="Condomínios ativos"
          value={counts.data?.units ?? 0}
          iconClass="bg-primary/10 text-primary"
          loading={counts.isLoading}
        />
        <StatCard
          icon={<Users className="h-5 w-5" />}
          label="Operadores ativos"
          value={counts.data?.operators ?? 0}
          iconClass="bg-secondary/10 text-secondary"
          loading={counts.isLoading}
        />
        <StatCard
          icon={<Radio className="h-5 w-5" />}
          label="Sessões ativas"
          value={counts.data?.activeSessions ?? 0}
          iconClass="bg-success/30 text-success-foreground"
          loading={counts.isLoading}
        />
        <StatCard
          icon={<MessageSquare className="h-5 w-5" />}
          label="Feedbacks pendentes"
          value={counts.data?.pendingFeedback ?? 0}
          iconClass="bg-destructive/10 text-destructive"
          loading={counts.isLoading}
        />
      </div>

      {/* Duas colunas: status + atividade */}
      <div className="grid gap-6 lg:grid-cols-2">
        <StatusSection groups={statuses.data ?? []} loading={statuses.isLoading} />
        <ActivitySection items={activity.data ?? []} loading={activity.isLoading} />
      </div>
    </>
  );
}
