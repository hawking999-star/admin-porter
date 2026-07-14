import { useEffect, useState } from "react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import type { DisplayNameRequest } from "./queries";

type DisplayNameReviewDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  request: DisplayNameRequest | null;
  decision: "approve" | "reject";
  isPending: boolean;
  onConfirm: (reason: string) => void;
};

export function DisplayNameReviewDialog({
  open,
  onOpenChange,
  request,
  decision,
  isPending,
  onConfirm,
}: DisplayNameReviewDialogProps) {
  const [reason, setReason] = useState("");

  useEffect(() => {
    if (open) setReason("");
  }, [open, request?.id, decision]);

  const isApprove = decision === "approve";

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{isApprove ? "Aprovar nome bloqueado?" : "Rejeitar solicitação?"}</DialogTitle>
          <DialogDescription>
            {isApprove
              ? "A exceção vale somente para esta solicitação e reinicia o prazo de 15 dias."
              : "O nome continuará bloqueado e o Operador poderá fazer outra solicitação quando estiver liberado."}
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4 py-2">
          <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm">
            <p className="font-medium">{request?.operator_name}</p>
            <p className="mt-1 text-muted-foreground">
              {request?.previous_name} → <span className="font-medium text-foreground">{request?.requested_name}</span>
            </p>
          </div>
          <div className="space-y-2">
            <Label htmlFor="display-name-review-reason">Justificativa</Label>
            <Textarea
              id="display-name-review-reason"
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              placeholder="Explique o motivo da decisão administrativa."
              maxLength={300}
              rows={4}
            />
            <p className="text-xs text-muted-foreground">Obrigatória, entre 3 e 300 caracteres.</p>
          </div>
        </div>

        <DialogFooter>
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>
            Cancelar
          </Button>
          <Button
            type="button"
            variant={isApprove ? "default" : "destructive"}
            disabled={isPending || reason.trim().length < 3}
            onClick={() => onConfirm(reason.trim())}
          >
            {isPending ? "Salvando..." : isApprove ? "Aprovar e aplicar" : "Rejeitar"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
