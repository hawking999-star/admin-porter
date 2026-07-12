import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  CheckCircle2,
  Check,
  ClipboardCopy,
  Database,
  HardDrive,
  RefreshCw,
  RotateCcw,
  TriangleAlert,
} from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { ErrorState, RetryButton, StatCard } from "@/components/shared";
import { cn } from "@/lib/utils";
import {
  acknowledgeImportError,
  getIntegrationStatus,
  listPendingImportErrors,
  retryImport,
  type IntegrationQueueStatus,
  type PendingImportError,
} from "./queries";

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

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "Não foi possível concluir a ação.";
}

function isRetryable(error: PendingImportError) {
  return error.approval_status === "approved" && /(^|\.)youtube\.com|youtu\.be/i.test(error.source_url ?? "");
}

function buildErrorReport(errors: PendingImportError[]) {
  const generatedAt = new Date().toLocaleString("pt-BR");
  const sections = errors.map((error, index) => [
    `${index + 1}. Playlist: ${error.playlist_name}`,
    `Operador: ${error.operator_name ?? "não informado"}`,
    `Condomínio: ${error.unit_name ?? "não informado"}`,
    `Data da falha: ${formatDate(error.last_error_at)}`,
    `Código: ${error.error_code ?? "não informado"}`,
    `Mensagem: ${error.error_message ?? "motivo técnico não informado"}`,
    `Origem: ${error.source_url ?? "não informada"}`,
    error.error_details ? `Detalhes: ${JSON.stringify(error.error_details)}` : null,
  ].filter(Boolean).join("\n")).join("\n\n");

  return [
    "PORTER MUSIC — RELATÓRIO DE ERROS DE IMPORTAÇÃO",
    `Gerado em: ${generatedAt}`,
    `Erros pendentes: ${errors.length}`,
    "",
    sections,
  ].join("\n");
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
  const queryClient = useQueryClient();
  const statusQuery = useQuery({
    queryKey: ["integration-status"],
    queryFn: getIntegrationStatus,
    staleTime: 15_000,
    refetchInterval: 30_000,
  });
  const errorsQuery = useQuery({
    queryKey: ["integration-import-errors"],
    queryFn: listPendingImportErrors,
    staleTime: 15_000,
    refetchInterval: 30_000,
  });
  const refresh = () => {
    void statusQuery.refetch();
    void errorsQuery.refetch();
  };
  const invalidate = () => Promise.all([
    queryClient.invalidateQueries({ queryKey: ["integration-status"] }),
    queryClient.invalidateQueries({ queryKey: ["integration-import-errors"] }),
    queryClient.invalidateQueries({ queryKey: ["playlists"] }),
  ]);
  const acknowledgeMutation = useMutation({
    mutationFn: acknowledgeImportError,
    onSuccess: async () => {
      await invalidate();
      toast.success("Erro marcado como tratado");
    },
    onError: (error: unknown) => toast.error("Não foi possível marcar como tratado", { description: errorMessage(error) }),
  });
  const retryMutation = useMutation({
    mutationFn: retryImport,
    onSuccess: async () => {
      await invalidate();
      toast.success("Importação reenfileirada");
    },
    onError: (error: unknown) => toast.error("Não foi possível reenfileirar", { description: errorMessage(error) }),
  });
  const status = statusQuery.data;
  const errors = errorsQuery.data ?? [];
  const isRefreshing = statusQuery.isFetching || errorsQuery.isFetching;

  const copyReport = async () => {
    try {
      await navigator.clipboard.writeText(buildErrorReport(errors));
      toast.success("Relatório copiado");
    } catch {
      toast.error("Não foi possível copiar o relatório");
    }
  };

  return (
    <>
      <PageHeader
        title="Integrações"
        description="Acompanhe as filas que conectam o painel, o importador e o armazenamento de músicas."
        action={
          <Button variant="outline" size="sm" onClick={refresh} disabled={isRefreshing}>
            <RefreshCw className={cn("h-4 w-4", isRefreshing && "animate-spin")} /> Atualizar
          </Button>
        }
      />

      {statusQuery.isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível consultar as integrações."
            description={errorMessage(statusQuery.error)}
            action={<RetryButton onClick={refresh} disabled={isRefreshing} />}
          />
        </Card>
      ) : (
        <div className="space-y-5">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <StatCard icon={<Database className="h-5 w-5" />} iconClassName="bg-success/25 text-success-foreground" label="Supabase" value={status?.database_connected ? "Conectado" : "Verificando"} hint="Leitura autenticada pelo painel" loading={statusQuery.isLoading} />
            <StatCard icon={<TriangleAlert className="h-5 w-5" />} iconClassName="bg-warning/20 text-warning-foreground" label="Falhas de importação" value={status?.imports.with_errors ?? 0} hint="Erros pendentes de tratamento" loading={statusQuery.isLoading} />
            <StatCard icon={<HardDrive className="h-5 w-5" />} iconClassName="bg-primary/10 text-primary" label="Limpeza no R2" value={status?.storage_cleanup.queued ?? 0} hint="Arquivos aguardando remoção segura" loading={statusQuery.isLoading} />
          </div>

          {status && (
            <div className="grid gap-5 xl:grid-cols-2">
              <QueueCard title="Importação de playlists" description="Jobs enviados para o Worker baixar e registrar músicas." queue={status.imports} icon={<RefreshCw className="h-5 w-5" />} />
              <QueueCard title="Limpeza de armazenamento" description="Faixas sem playlist aguardando validação e exclusão no R2." queue={status.storage_cleanup} icon={<HardDrive className="h-5 w-5" />} />
            </div>
          )}

          {errorsQuery.isError ? (
            <Card className="shadow-sm">
              <ErrorState title="Não foi possível carregar os erros de importação." description={errorMessage(errorsQuery.error)} action={<RetryButton onClick={() => errorsQuery.refetch()} disabled={errorsQuery.isFetching} />} />
            </Card>
          ) : errors.length > 0 ? (
            <Card className="overflow-hidden shadow-sm">
              <div className="flex flex-wrap items-start justify-between gap-3 border-b border-border p-5">
                <div>
                  <h2 className="font-semibold">Tratamento de erros de importação</h2>
                  <p className="mt-1 text-sm text-muted-foreground">Confirme itens já tratados para retirá-los da fila ou reenfileire importações elegíveis. Casos complexos podem ser copiados para o desenvolvedor.</p>
                </div>
                <Button variant="outline" size="sm" onClick={copyReport}>
                  <ClipboardCopy className="h-4 w-4" /> Copiar relatório ({errors.length})
                </Button>
              </div>
              <div className="divide-y divide-border">
                {errors.map((error) => {
                  const retryable = isRetryable(error);
                  const busy = acknowledgeMutation.isPending || retryMutation.isPending;
                  return (
                    <div key={error.playlist_id} className="p-5">
                      <div className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
                        <div className="min-w-0">
                          <div className="flex flex-wrap items-center gap-2">
                            <h3 className="font-medium">{error.playlist_name}</h3>
                            {error.error_code && <span className="rounded bg-destructive/10 px-2 py-0.5 font-mono text-xs text-destructive">{error.error_code}</span>}
                          </div>
                          <p className="mt-1 break-words text-sm text-destructive">{error.error_message ?? "Motivo técnico não informado pelo backend."}</p>
                          <p className="mt-2 text-xs text-muted-foreground">Operador: {error.operator_name ?? "não informado"} · Condomínio: {error.unit_name ?? "não informado"} · Falha: {formatDate(error.last_error_at)}</p>
                          {error.source_url && <p className="mt-1 break-all text-xs text-muted-foreground">Origem: {error.source_url}</p>}
                        </div>
                        <div className="flex shrink-0 flex-wrap gap-2">
                          {retryable && <Button size="sm" variant="outline" onClick={() => retryMutation.mutate(error.playlist_id)} disabled={busy}><RotateCcw className="h-4 w-4" /> Reenfileirar</Button>}
                          <Button size="sm" variant="outline" onClick={() => acknowledgeMutation.mutate(error.playlist_id)} disabled={busy}><Check className="h-4 w-4" /> Marcar como tratado</Button>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </Card>
          ) : !errorsQuery.isLoading ? (
            <div className="flex items-center gap-2 rounded-lg border border-success/30 bg-success/10 p-3 text-sm text-success-foreground">
              <CheckCircle2 className="h-4 w-4" /> Nenhum erro de importação pendente neste momento.
            </div>
          ) : null}

          {!statusQuery.isLoading && status && status.imports.running === 0 && status.imports.queued === 0 && (
            <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/30 p-3 text-sm text-muted-foreground">
              <CheckCircle2 className="h-4 w-4 text-success-foreground" /> Nenhuma importação em processamento neste momento.
            </div>
          )}
        </div>
      )}
    </>
  );
}
