import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { Check, Search } from "lucide-react";
import { cn } from "@/lib/utils";
import { errorMessage } from "@/lib/errors";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { SearchInput } from "@/components/shared";
import { Skeleton } from "@/components/ui/skeleton";
import { useDebounce } from "@/hooks/useDebounce";
import { listOperators, grantPanelAccess, unitLabel, type Operator } from "./queries";

/**
 * Promove um operador do app existente para o painel (vira Super admin).
 * Não cria login novo: reaproveita o login que o operador já usa no app.
 */
export function GrantPanelAccessDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  const qc = useQueryClient();
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Operator | null>(null);
  const debounced = useDebounce(search, 300);

  useEffect(() => {
    if (!open) {
      setSearch("");
      setSelected(null);
    }
  }, [open]);

  const { data, isLoading } = useQuery({
    queryKey: ["operators-for-promotion", debounced],
    queryFn: () => listOperators({ page: 1, pageSize: 20, search: debounced, active: "active" }),
    enabled: open,
    staleTime: 30_000,
  });

  // Só dá para promover quem já tem login vinculado.
  const operators = (data?.rows ?? []).filter((o) => o.has_login);

  const mutation = useMutation({
    mutationFn: () => {
      if (!selected) throw new Error("Selecione um operador.");
      return grantPanelAccess(selected.id);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin-users"] });
      toast.success("Acesso ao painel concedido", {
        description: selected ? `${selected.display_name} agora entra no admin.` : undefined,
      });
      onOpenChange(false);
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível conceder", { description: errorMessage(err) });
    },
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Dar acesso ao painel</DialogTitle>
          <DialogDescription>
            Escolha um operador do app. Ele passa a entrar no admin com o mesmo login, sem criar
            conta nova.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3 py-2">
          <SearchInput value={search} onChange={setSearch} placeholder="Buscar por nome ou usuário..." />

          <div className="max-h-72 space-y-1 overflow-y-auto rounded-lg border border-border p-1">
            {isLoading &&
              Array.from({ length: 4 }).map((_, i) => (
                <Skeleton key={i} className="h-12 w-full rounded-md" />
              ))}

            {!isLoading && operators.length === 0 && (
              <div className="flex flex-col items-center gap-1 px-3 py-8 text-center text-sm text-muted-foreground">
                <Search className="h-5 w-5" />
                Nenhum operador com login encontrado.
              </div>
            )}

            {!isLoading &&
              operators.map((op) => {
                const isSelected = selected?.id === op.id;
                return (
                  <button
                    key={op.id}
                    type="button"
                    onClick={() => setSelected(op)}
                    className={cn(
                      "flex w-full items-center justify-between rounded-md px-3 py-2 text-left transition-colors",
                      isSelected ? "bg-primary/10 text-primary" : "hover:bg-muted",
                    )}
                  >
                    <span className="min-w-0">
                      <span className="block truncate text-sm font-medium">{op.display_name}</span>
                      <span className="block truncate text-xs text-muted-foreground">
                        {op.username ?? "—"}
                        {op.unit_name
                          ? ` · ${unitLabel({ name: op.unit_name, city: op.unit_city, state: op.unit_state })}`
                          : ""}
                      </span>
                    </span>
                    {isSelected && <Check className="h-4 w-4 shrink-0" />}
                  </button>
                );
              })}
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button
            type="button"
            disabled={!selected || mutation.isPending}
            onClick={() => mutation.mutate()}
          >
            {mutation.isPending ? "Concedendo..." : "Dar acesso ao painel"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
