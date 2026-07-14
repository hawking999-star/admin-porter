import { useEffect, useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { errorMessage } from "@/lib/errors";
import { correctOperatorRegisteredName, type Operator } from "./queries";

type RegisteredNameCorrectionDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  operator: Operator | null;
};

export function RegisteredNameCorrectionDialog({
  open,
  onOpenChange,
  operator,
}: RegisteredNameCorrectionDialogProps) {
  const queryClient = useQueryClient();
  const [registeredName, setRegisteredName] = useState("");
  const [reason, setReason] = useState("");

  useEffect(() => {
    if (open) {
      setRegisteredName(operator?.registered_name ?? "");
      setReason("");
    }
  }, [open, operator]);

  const mutation = useMutation({
    mutationFn: () => {
      if (!operator) throw new Error("Operador inválido.");
      return correctOperatorRegisteredName(operator.id, registeredName.trim(), reason.trim());
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["operators"] });
      toast.success("Nome cadastral corrigido");
      onOpenChange(false);
    },
    onError: (error: unknown) => {
      toast.error("Não foi possível corrigir o nome", { description: errorMessage(error) });
    },
  });

  const canSubmit =
    registeredName.trim().length >= 3
    && registeredName.trim() !== operator?.registered_name
    && reason.trim().length >= 3;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Corrigir nome cadastral</DialogTitle>
          <DialogDescription>
            Esta ação é exclusiva de Super admin, não altera o nome de exibição no App e fica registrada na auditoria.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="space-y-2">
            <Label htmlFor="correct-registered-name">Nome cadastral</Label>
            <Input
              id="correct-registered-name"
              value={registeredName}
              onChange={(event) => setRegisteredName(event.target.value)}
              maxLength={120}
              autoFocus
            />
            <p className="text-xs text-muted-foreground">Entre 3 e 120 caracteres.</p>
          </div>
          <div className="space-y-2">
            <Label htmlFor="registered-name-correction-reason">Justificativa</Label>
            <Textarea
              id="registered-name-correction-reason"
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              placeholder="Explique por que o nome cadastral precisa ser corrigido."
              maxLength={300}
              rows={4}
            />
            <p className="text-xs text-muted-foreground">Obrigatória, entre 3 e 300 caracteres.</p>
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={mutation.isPending}>
            Cancelar
          </Button>
          <Button type="button" onClick={() => mutation.mutate()} disabled={!canSubmit || mutation.isPending}>
            {mutation.isPending ? "Salvando..." : "Corrigir nome"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
