import { useQuery } from "@tanstack/react-query";
import { CheckCircle2, Database, HardDrive, RefreshCw, TriangleAlert } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { ErrorState, RetryButton, StatCard } from "@/components/shared";
import { cn } from "@/lib/utils";
import { getIntegrationStatus, type IntegrationQueueStatus } from "./queries";

function formatDate(value: string | null) {
  if (!value) return "Sem atividade registrada";
  return new Date(value).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function QueueCard({ title, description, queue, icon }: {
  title: string;
  description: string;
  queue: IntegrationQueueStatus;
  icon: React.ReactNode;
}) {
  const hasError = queue.with_errors > 0;
  const isWorking = queue.running > 0 || queue.queued > 0;
  const label = hasError ? "Atenção necessária" : isWorking ? "Em processamento" : "Sem pendências";

  return (
    <Card className="p-5 shadow-sm">
      <div className="flex items-start justify-between gap-4">
        <div className="flex min-w-0 items-start gap-3">
          <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">{icon}</div>
          <div>
            <h2 className="font-semibold">{title}</h2>
            <p className="mt-1 text-sm text-muted-foreground">{description}</p>
          </div>
        </div>
        <span className={cn(
          "shrink-0 rounded-full px-2.5 py-1 text-xs font-medium",
          hasError ? "bg-destructive/10 text-destructive" : isWorking ? "bg-warning/15 text-warning-foreground" : "bg-success/20 text-success-foreground",
        )}>{label}</span>
      </div>
      <div className="mt-5 grid grid-cols-3 gap-2">
        <QueueMetric label="Na fila" value={queue.queued} />
        <QueueMetric label="Processando" value={queue.running} />
        <QueueMetric label="Com erro" value={queue.with_errors} danger={hasError} />
      </div>
      <p className="mt-4 text-xs text-muted-foreground">Última atividade: {formatDate(queue.last_activity_at)}</p>
    </Card>
  );
}

function QueueMetric({ label, value, danger = false }: { label: string; value: number; danger?: boolean }) {
  return (
    <div className="rounded-md border border-border bg-muted/30 px-3 py-2">
      <p className="text-xs text-muted-foreground">{label}</p>
      <p className={cn("mt-1 text-lg font-semibold tabular-nums", danger && "text-destructive")}>{value}</p>
    </div>
  );
}

export function IntegracaoPage() {
  const statusQuery = useQuery({
    queryKey: ["integration-status"],
    queryFn: getIntegrationStatus,
    staleTime: 15_000,
    refetchInterval: 30_000,
  });
  const status = statusQuery.data;

  return (
    <>
      <PageHeader
        title="Integrações"
        description="Acompanhe as filas que conectam o painel, o importador e o armazenamento de músicas."
        action={
          <Button variant="outline" size="sm" onClick={() => statusQuery.refetch()} disabled={statusQuery.isFetching}>
            <RefreshCw className={cn("h-4 w-4", statusQuery.isFetching && "animate-spin")} /> Atualizar
          </Button>
        }
      />

      {statusQuery.isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível consultar as integrações."
            description={(statusQuery.error as Error).message}
            action={<RetryButton onClick={() => statusQuery.refetch()} disabled={statusQuery.isFetching} />}
          />
        </Card>
      ) : (
        <div className="space-y-5">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <StatCard
              icon={<Database className="h-5 w-5" />}
              iconClassName="bg-success/25 text-success-foreground"
              label="Supabase"
              value={status?.database_connected ? "Conectado" : "Verificando"}
              hint="Leitura autenticada pelo painel"
              loading={statusQuery.isLoading}
            />
            <StatCard
              icon={<TriangleAlert className="h-5 w-5" />}
              iconClassName="bg-warning/20 text-warning-foreground"
              label="Falhas de importação"
              value={status?.imports.with_errors ?? 0}
              hint="Jobs que exigem acompanhamento"
              loading={statusQuery.isLoading}
            />
            <StatCard
              icon={<HardDrive className="h-5 w-5" />}
              iconClassName="bg-primary/10 text-primary"
              label="Limpeza no R2"
              value={status?.storage_cleanup.queued ?? 0}
              hint="Arquivos aguardando remoção segura"
              loading={statusQuery.isLoading}
            />
          </div>

          {status && (
            <div className="grid gap-5 xl:grid-cols-2">
              <QueueCard title="Importação de playlists" description="Jobs enviados para o Worker baixar e registrar músicas." queue={status.imports} icon={<RefreshCw className="h-5 w-5" />} />
              <QueueCard title="Limpeza de armazenamento" description="Faixas sem playlist aguardando validação e exclusão no R2." queue={status.storage_cleanup} icon={<HardDrive className="h-5 w-5" />} />
            </div>
          )}

          {!statusQuery.isLoading && status && status.imports.running === 0 && status.imports.queued === 0 && (
            <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/30 p-3 text-sm text-muted-foreground">
              <CheckCircle2 className="h-4 w-4 text-success-foreground" /> Nenhuma importação pendente neste momento.
            </div>
          )}
        </div>
      )}
    </>
  );
}
