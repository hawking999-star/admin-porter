import { useEffect, useState, type FormEvent } from "react";
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
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { Textarea } from "@/components/ui/textarea";
import type { DisplayNameModerationTerm, DisplayNameTermInput } from "./queries";

type DisplayNameTermDialogProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  term: DisplayNameModerationTerm | null;
  isPending: boolean;
  onSubmit: (input: DisplayNameTermInput) => void;
};

export function DisplayNameTermDialog({ open, onOpenChange, term, isPending, onSubmit }: DisplayNameTermDialogProps) {
  const [value, setValue] = useState("");
  const [matchType, setMatchType] = useState<DisplayNameTermInput["match_type"]>("whole_word");
  const [reason, setReason] = useState("");
  const [active, setActive] = useState(true);

  useEffect(() => {
    if (!open) return;
    setValue(term?.term ?? "");
    setMatchType(term?.match_type ?? "whole_word");
    setReason(term?.reason ?? "");
    setActive(term?.active ?? true);
  }, [open, term]);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    onSubmit({ id: term?.id, term: value.trim(), match_type: matchType, reason: reason.trim(), active });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={submit}>
          <DialogHeader>
            <DialogTitle>{term ? "Editar termo bloqueado" : "Novo termo bloqueado"}</DialogTitle>
            <DialogDescription>
              A lista fica somente no servidor. O App recebe apenas a informação de que o nome não é permitido.
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="moderation-term">Termo ou expressão</Label>
              <Input
                id="moderation-term"
                value={value}
                onChange={(event) => setValue(event.target.value)}
                placeholder="Informe o conteúdo a bloquear"
                minLength={2}
                maxLength={80}
                required
              />
            </div>

            <div className="space-y-2">
              <Label>Forma de detecção</Label>
              <Select value={matchType} onValueChange={(next) => setMatchType(next as DisplayNameTermInput["match_type"])}>
                <SelectTrigger><SelectValue /></SelectTrigger>
                <SelectContent>
                  <SelectItem value="whole_word">Palavra ou frase completa</SelectItem>
                  <SelectItem value="exact_name">Nome inteiro exato</SelectItem>
                  <SelectItem value="obfuscated">Ofuscação por letras, espaços ou símbolos</SelectItem>
                </SelectContent>
              </Select>
              <p className="text-xs text-muted-foreground">
                {matchType === "obfuscated"
                  ? "Modo mais agressivo: detecta o termo mesmo separado por símbolos e pode exigir revisão de falsos positivos."
                  : "A comparação ignora maiúsculas, minúsculas e acentos, preservando os limites das palavras."}
              </p>
            </div>

            <div className="space-y-2">
              <Label htmlFor="moderation-reason">Motivo administrativo</Label>
              <Textarea
                id="moderation-reason"
                value={reason}
                onChange={(event) => setReason(event.target.value)}
                placeholder="Ex.: linguagem inadequada para identificação operacional."
                minLength={3}
                maxLength={300}
                required
              />
            </div>

            <div className="flex items-center justify-between rounded-lg border border-border px-3 py-2.5">
              <div>
                <Label htmlFor="moderation-active">Termo ativo</Label>
                <p className="text-xs text-muted-foreground">Termos inativos permanecem no histórico, mas não bloqueiam nomes.</p>
              </div>
              <Switch id="moderation-active" checked={active} onCheckedChange={setActive} />
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isPending}>Cancelar</Button>
            <Button type="submit" disabled={isPending || value.trim().length < 2 || reason.trim().length < 3}>
              {isPending ? "Salvando..." : "Salvar termo"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
