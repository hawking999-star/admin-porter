import { useQuery } from "@tanstack/react-query";
import { Activity, Cloud, Database, HardDrive, ServerCog } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { UpdatedAt } from "@/components/shared/UpdatedAt";
import { getOperationalHealth, type HealthState } from "@/lib/operational";
import { cn } from "@/lib/utils";

const stateMeta: Record<HealthState, { label: string; className: string }> = {
  healthy: { label: "Saudável", className: "bg-success text-success-foreground" },
  degraded: { label: "Atenção", className: "bg-warning text-warning-foreground" },
  offline: { label: "Offline", className: "bg-destructive text-destructive-foreground" },
  stalled: { label: "Parada", className: "bg-destructive text-destructive-foreground" },
  unknown: { label: "Sem sinal", className: "bg-muted-foreground text-background" },
};

function HealthRow({
  icon,
  label,
  state,
  detail,
}: {
  icon: React.ReactNode;
  label: string;
  state: HealthState;
  detail: string;
}) {
  const meta = stateMeta[state];
  return (
    <div className="flex items-start gap-3 rounded-lg border border-border p-3">
      <span className="mt-0.5 text-muted-foreground">{icon}</span>
      <div className="min-w-0 flex-1">
        <div className="flex items-center justify-between gap-2">
          <span className="text-sm font-semibold">{label}</span>
          <span className={cn("rounded-full px-2 py-0.5 text-[10px] font-semibold", meta.className)}>{meta.label}</span>
        </div>
        <p className="mt-1 truncate text-xs text-muted-foreground" title={detail}>{detail}</p>
      </div>
    </div>
  );
}

export function SystemHealthPopover() {
  const health = useQuery({
    queryKey: ["integration-status"],
    queryFn: getOperationalHealth,
    staleTime: 30_000,
    refetchInterval: 60_000,
    refetchIntervalInBackground: false,
  });
  const data = health.data;
  const workerState = data?.worker?.state ?? "unknown";
  const r2State = data?.r2?.state ?? "unknown";
  const queueState: HealthState = (data?.storage_cleanup?.with_errors ?? 0) > 0
    ? "degraded"
    : data?.imports?.state ?? "unknown";
  const overall: HealthState = !data?.database_connected
    ? "offline"
    : [workerState, r2State, queueState].some((state) => ["offline", "stalled"].includes(state))
      ? "offline"
      : [workerState, r2State, queueState].some((state) => ["degraded", "unknown"].includes(state))
        ? "degraded"
        : "healthy";

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" className="gap-2" aria-label="Saúde dos serviços">
          <span className={cn("h-2 w-2 rounded-full", stateMeta[overall].className)} />
          <span className="hidden lg:inline">Saúde</span>
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" className="w-[360px] max-w-[calc(100vw-2rem)]">
        <div className="mb-3 flex items-start justify-between gap-3">
          <div>
            <h2 className="font-semibold">Saúde operacional</h2>
            <p className="text-xs text-muted-foreground">Supabase, Worker, R2 e filas reais.</p>
          </div>
          <Activity className={cn("h-5 w-5", health.isFetching && "animate-pulse")} />
        </div>
        <div className="space-y-2">
          <HealthRow icon={<Database className="h-4 w-4" />} label="Supabase" state={data?.database_connected ? "healthy" : "offline"} detail={data?.database_connected ? "RPC autenticada respondendo" : "Sem resposta do banco"} />
          <HealthRow icon={<ServerCog className="h-4 w-4" />} label="Worker" state={workerState} detail={data?.worker?.last_seen_at ? `Último sinal há ${data.worker.age_seconds ?? 0}s · ${data.worker.details?.activity ?? data.worker.status ?? "ativo"}` : "Heartbeat ainda não recebido"} />
          <HealthRow icon={<Cloud className="h-4 w-4" />} label="Cloudflare R2" state={r2State} detail={data?.r2?.message ?? "Aguardando teste do Worker"} />
          <HealthRow icon={<HardDrive className="h-4 w-4" />} label="Filas" state={queueState} detail={data?.imports ? `Importação: ${data.imports.queued} na fila, ${data.imports.running} processando, ${data.imports.with_errors} com erro · Limpeza R2: ${data.storage_cleanup.queued} na fila, ${data.storage_cleanup.with_errors} com erro` : "Aguardando métricas"} />
        </div>
        <div className="mt-3 flex items-center justify-between gap-3 border-t border-border pt-3">
          <UpdatedAt value={data?.generated_at ?? health.dataUpdatedAt} loading={health.isFetching} />
          <Button variant="ghost" size="sm" onClick={() => health.refetch()} disabled={health.isFetching}>Atualizar</Button>
        </div>
      </PopoverContent>
    </Popover>
  );
}
