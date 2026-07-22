import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Clock3 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { EmptyState } from "@/components/shared/EmptyState";
import { ErrorState, RetryButton } from "@/components/shared/ErrorState";
import { listEntityHistory } from "@/lib/operational";

function label(value: string) {
  return value.replaceAll("_", " ").replace(/\b\w/g, (character) => character.toUpperCase());
}

function ChangeSnapshot({ title, value }: { title: string; value: unknown }) {
  if (value == null) return null;
  return (
    <details className="rounded-lg border border-border bg-muted/20 p-3">
      <summary className="cursor-pointer text-xs font-semibold text-muted-foreground">{title}</summary>
      <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words text-xs leading-relaxed">
        {JSON.stringify(value, null, 2)}
      </pre>
    </details>
  );
}

export function EntityHistoryButton({
  entityId,
  entityTypes,
  title,
}: {
  entityId: string;
  entityTypes: string[];
  title: string;
}) {
  const [open, setOpen] = useState(false);
  const history = useQuery({
    queryKey: ["entity-history", entityId, entityTypes],
    queryFn: () => listEntityHistory(entityId, entityTypes),
    enabled: open,
    staleTime: 30_000,
  });

  return (
    <>
      <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(true)}>
        <Clock3 className="h-4 w-4" /> Histórico
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="max-h-[88vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>Histórico de {title}</DialogTitle>
            <DialogDescription>Alterações administrativas registradas com autor, data e valores anteriores.</DialogDescription>
          </DialogHeader>
          {history.isLoading ? (
            <div className="space-y-3">{Array.from({ length: 3 }).map((_, index) => <Skeleton key={index} className="h-24 w-full" />)}</div>
          ) : history.isError ? (
            <ErrorState title="Não foi possível carregar o histórico." description={(history.error as Error).message} action={<RetryButton onClick={() => history.refetch()} />} />
          ) : !history.data?.length ? (
            <EmptyState icon={<Clock3 className="h-6 w-6" />} title="Nenhuma alteração registrada." description="Novas ações auditadas aparecerão aqui." />
          ) : (
            <div className="space-y-3">
              {history.data.map((row) => (
                <article key={row.id} className="rounded-xl border border-border p-4">
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div>
                      <p className="text-sm font-semibold">{label(row.action)}</p>
                      <p className="text-xs text-muted-foreground">{row.admin_name} · {label(row.entity_type)}</p>
                    </div>
                    <time className="text-xs text-muted-foreground">{new Date(row.occurred_at).toLocaleString("pt-BR")}</time>
                  </div>
                  {row.reason && <p className="mt-3 rounded-md bg-muted/40 p-2 text-xs">{row.reason}</p>}
                  <div className="mt-3 grid gap-2 sm:grid-cols-2">
                    <ChangeSnapshot title="Antes" value={row.before_data} />
                    <ChangeSnapshot title="Depois" value={row.after_data} />
                  </div>
                </article>
              ))}
            </div>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
