import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
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
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  listUnitOptions,
  grantAppAccess,
  unitLabel,
  OPERATOR_ROLES,
  type AdminUser,
} from "./queries";

/**
 * Dá acesso ao app a quem só tem acesso ao painel: cria um perfil de operador
 * usando o MESMO login. Resolve o caso "meu login de admin também entra no app".
 */
export function GrantAppAccessDialog({
  open,
  onOpenChange,
  adminUser,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  adminUser: AdminUser | null;
}) {
  const qc = useQueryClient();
  const [username, setUsername] = useState("");
  const [unitId, setUnitId] = useState("");
  const [role, setRole] = useState("operador");
  const [sessionPolicy, setSessionPolicy] = useState("single");

  useEffect(() => {
    if (open) {
      setUsername("");
      setUnitId("");
      setRole("operador");
      setSessionPolicy("single");
    }
  }, [open, adminUser]);

  const unitOptionsQuery = useQuery({
    queryKey: ["unit-options"],
    queryFn: listUnitOptions,
    enabled: open,
    staleTime: 60_000,
  });

  const mutation = useMutation({
    mutationFn: () => {
      if (!adminUser) throw new Error("Acesso inválido.");
      return grantAppAccess(adminUser.id, {
        username: username.trim(),
        unit_id: unitId,
        role,
        session_policy: sessionPolicy,
      });
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["operators"] });
      qc.invalidateQueries({ queryKey: ["operator-stats"] });
      toast.success("Acesso ao app concedido", {
        description: adminUser ? `${adminUser.display_name} já pode entrar no app.` : undefined,
      });
      onOpenChange(false);
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível conceder", { description: errorMessage(err) });
    },
  });

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!unitId) {
      toast.error("Escolha um condomínio.");
      return;
    }
    mutation.mutate();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={onSubmit}>
          <DialogHeader>
            <DialogTitle>Dar acesso ao app</DialogTitle>
            <DialogDescription>
              {adminUser?.display_name
                ? `${adminUser.display_name} vai entrar no app com o mesmo login do painel.`
                : "Cria um perfil de operador com o mesmo login do painel."}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="app_username">Usuário do app</Label>
              <Input
                id="app_username"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="ex.: kaua.henrique"
                autoComplete="off"
                required
              />
              <p className="text-xs text-muted-foreground">
                É por ele que a pessoa faz login no app. Letras minúsculas, números, ponto, hífen ou
                underline.
              </p>
            </div>

            <div className="space-y-2">
              <Label>Condomínio</Label>
              <Select value={unitId} onValueChange={setUnitId}>
                <SelectTrigger>
                  <SelectValue placeholder="Escolha o condomínio" />
                </SelectTrigger>
                <SelectContent>
                  {(unitOptionsQuery.data ?? []).map((unit) => (
                    <SelectItem key={unit.id} value={unit.id}>
                      {unitLabel(unit)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div className="space-y-2">
                <Label>Cargo</Label>
                <Select value={role} onValueChange={setRole}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {OPERATOR_ROLES.map((r) => (
                      <SelectItem key={r.value} value={r.value}>
                        {r.label}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
              <div className="space-y-2">
                <Label>Sessão</Label>
                <Select value={sessionPolicy} onValueChange={setSessionPolicy}>
                  <SelectTrigger>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="single">Um dispositivo</SelectItem>
                    <SelectItem value="multi">Vários dispositivos</SelectItem>
                  </SelectContent>
                </Select>
              </div>
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancelar
            </Button>
            <Button type="submit" disabled={mutation.isPending}>
              {mutation.isPending ? "Concedendo..." : "Dar acesso ao app"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
