import { Building2, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { unitLabel, type UnitOption } from "@/features/usuarios/queries";

export function ChallengeBulkUnitDialog({
  open,
  onOpenChange,
  units,
  selectedCount,
  saving,
  onConfirm,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  units: UnitOption[];
  selectedCount: number;
  saving: boolean;
  onConfirm: (unitId: string | null) => void;
}) {
  const [target, setTarget] = useState("");

  useEffect(() => {
    if (open) setTarget("");
  }, [open]);

  return (
    <Dialog open={open} onOpenChange={(nextOpen) => !saving && onOpenChange(nextOpen)}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Alterar condomínio em massa</DialogTitle>
          <DialogDescription>
            Defina onde os {selectedCount} desafio(s) selecionado(s) poderão aparecer. A alteração é transacional e auditada.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-3">
          <label className="space-y-1.5">
            <span className="text-sm font-semibold">Novo destino</span>
            <Select value={target} onValueChange={setTarget} disabled={saving}>
              <SelectTrigger><SelectValue placeholder="Selecione o destino" /></SelectTrigger>
              <SelectContent>
                <SelectItem value="global">Todos os condomínios (desafios globais)</SelectItem>
                {units.map((unit) => <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>)}
              </SelectContent>
            </Select>
          </label>

          <div className="flex items-start gap-2 rounded-lg border border-blue-200 bg-blue-50 p-3 text-xs leading-relaxed text-blue-900 dark:border-blue-900/60 dark:bg-blue-950/30 dark:text-blue-100">
            <Building2 className="mt-0.5 h-4 w-4 shrink-0" />
            {target === "global"
              ? "Estes desafios passarão a valer para Operadores de todos os condomínios."
              : "Ao escolher um condomínio, os desafios ficarão direcionados somente aos Operadores daquela unidade."}
          </div>
        </div>

        <DialogFooter>
          <Button variant="outline" disabled={saving} onClick={() => onOpenChange(false)}>Cancelar</Button>
          <Button disabled={!target || saving} onClick={() => onConfirm(target === "global" ? null : target)}>
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <Building2 className="h-4 w-4" />}
            {saving ? "Alterando..." : "Aplicar aos selecionados"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
