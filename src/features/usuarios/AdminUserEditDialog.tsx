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
import { Switch } from "@/components/ui/switch";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { updateAdminUser, ADMIN_ROLES, type AdminUser, type AdminUserInput } from "./queries";

export function AdminUserEditDialog({
  open,
  onOpenChange,
  adminUser,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  adminUser: AdminUser | null;
}) {
  const qc = useQueryClient();

  const [displayName, setDisplayName] = useState("");
  const [role, setRole] = useState("superadmin");
  const [active, setActive] = useState(true);
  const [mfaRequired, setMfaRequired] = useState(false);

  useEffect(() => {
    if (open && adminUser) {
      setDisplayName(adminUser.display_name ?? "");
      setRole(adminUser.role);
      setActive(adminUser.active);
      setMfaRequired(adminUser.mfa_required);
    }
  }, [open, adminUser]);

  const mutation = useMutation({
    mutationFn: async (input: AdminUserInput) => {
      if (!adminUser) return;
      await updateAdminUser(adminUser.id, input);
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["admin-users"] });
      toast.success("Acesso atualizado");
      onOpenChange(false);
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao salvar";
      toast.error("Não foi possível salvar", { description: msg });
    },
  });

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    mutation.mutate({
      display_name: displayName.trim(),
      role,
      active,
      mfa_required: mfaRequired,
    });
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={onSubmit}>
          <DialogHeader>
            <DialogTitle>Editar acesso</DialogTitle>
            <DialogDescription>
              Quem pode entrar no admin. Criar um acesso novo precisa do login (ver relatório do dev).
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="admin_name">Nome</Label>
              <Input
                id="admin_name"
                value={displayName}
                onChange={(e) => setDisplayName(e.target.value)}
                required
              />
            </div>
            <div className="space-y-2">
              <Label>Papel</Label>
              <Select value={role} onValueChange={setRole}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {ADMIN_ROLES.map((r) => (
                    <SelectItem key={r.value} value={r.value}>
                      {r.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2">
              <div>
                <Label htmlFor="admin_active">Ativo</Label>
                <p className="text-xs text-muted-foreground">Desligado = não consegue entrar no admin.</p>
              </div>
              <Switch id="admin_active" checked={active} onCheckedChange={setActive} />
            </div>
            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2">
              <div>
                <Label htmlFor="admin_mfa">Exigir 2FA</Label>
                <p className="text-xs text-muted-foreground">Pedir verificação em dois fatores.</p>
              </div>
              <Switch id="admin_mfa" checked={mfaRequired} onCheckedChange={setMfaRequired} />
            </div>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)}>
              Cancelar
            </Button>
            <Button type="submit" disabled={mutation.isPending}>
              {mutation.isPending ? "Salvando..." : "Salvar"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
