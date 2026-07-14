import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
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
import { Textarea } from "@/components/ui/textarea";
import { useAuth } from "@/features/auth/AuthProvider";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  correctOperatorRegisteredName,
  provisionOperator,
  updateOperator,
  setOperatorShift,
  getOperatorEmail,
  listUnitOptions,
  unitLabel,
  OPERATOR_ROLES,
  SHIFT_TYPES,
  type Operator,
} from "./queries";

export function OperatorFormDialog({
  open,
  onOpenChange,
  operator,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  operator: Operator | null;
}) {
  const qc = useQueryClient();
  const { adminUser } = useAuth();
  const isEdit = Boolean(operator);
  const isSuperadmin = adminUser?.role === "superadmin";

  const { data: units = [] } = useQuery({
    queryKey: ["unit-options"],
    queryFn: listUnitOptions,
    staleTime: 60_000,
  });

  // E-mail de login (só aparece ao editar; é lido do servidor).
  const { data: loginEmail } = useQuery({
    queryKey: ["operator-email", operator?.id],
    queryFn: () => getOperatorEmail(operator!.id),
    enabled: open && isEdit && Boolean(operator?.id),
    staleTime: 60_000,
  });

  const [registeredName, setRegisteredName] = useState("");
  const [registeredNameReason, setRegisteredNameReason] = useState("");
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [unitId, setUnitId] = useState("");
  const [role, setRole] = useState("operador");
  const [sessionPolicy, setSessionPolicy] = useState("single");
  const [active, setActive] = useState(true);
  const [shiftKind, setShiftKind] = useState("none");
  const [shiftStart, setShiftStart] = useState("07:00");
  const [shiftEnd, setShiftEnd] = useState("16:00");

  useEffect(() => {
    if (open) {
      setRegisteredName(operator?.registered_name ?? operator?.display_name ?? "");
      setRegisteredNameReason("");
      setUsername(operator?.username ?? "");
      setEmail("");
      setPassword("");
      setUnitId(operator?.unit_id ?? "");
      setRole(operator?.role ?? "operador");
      setSessionPolicy(operator?.session_policy ?? "single");
      setActive(operator?.active ?? true);
      setShiftKind(operator?.shift_kind ?? "none");
      setShiftStart(operator?.shift_start ? operator.shift_start.slice(0, 5) : "07:00");
      setShiftEnd(operator?.shift_end ? operator.shift_end.slice(0, 5) : "16:00");
    }
  }, [open, operator]);

  const mutation = useMutation({
    mutationFn: async () => {
      let operatorId = operator?.id ?? null;
      if (operator) {
        await updateOperator(operator.id, {
          registered_name: operator.registered_name,
          username: username.trim() || null,
          unit_id: unitId,
          role,
          session_policy: sessionPolicy,
          active,
        });
        if (registeredName.trim() !== operator.registered_name) {
          await correctOperatorRegisteredName(
            operator.id,
            registeredName.trim(),
            registeredNameReason.trim(),
          );
        }
      } else {
        operatorId = await provisionOperator({
          display_name: registeredName.trim(),
          username: username.trim(),
          email: email.trim(),
          password,
          unit_id: unitId,
          role,
          session_policy: sessionPolicy,
          active,
        });
      }
      // Turno: 12x36 usa horário fixo; 6x1 usa o horário informado.
      if (operatorId) {
        await setOperatorShift(operatorId, shiftKind, shiftStart, shiftEnd);
      }
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["operators"] });
      toast.success(isEdit ? "Operador atualizado" : "Operador criado");
      onOpenChange(false);
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao salvar";
      toast.error("Não foi possível salvar", { description: msg });
    },
  });

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!unitId) {
      toast.error("Escolha um condomínio");
      return;
    }
    if (
      operator
      && registeredName.trim() !== operator.registered_name
      && registeredNameReason.trim().length < 3
    ) {
      toast.error("Informe a justificativa da correção cadastral");
      return;
    }
    if (!isEdit) {
      if (!email.trim()) {
        toast.error("Informe o e-mail de login");
        return;
      }
      if (password.length < 6) {
        toast.error("A senha precisa ter pelo menos 6 caracteres");
        return;
      }
    }
    mutation.mutate();
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <form onSubmit={onSubmit}>
          <DialogHeader>
            <DialogTitle>{isEdit ? "Editar operador" : "Novo operador"}</DialogTitle>
            <DialogDescription>
              {isEdit
                ? "Edite os dados do operador. Login e senha não são alterados aqui."
                : "Cadastro do operador com login de acesso ao app."}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-4">
            <div className="space-y-2">
              <Label htmlFor="registered_name">Nome cadastral</Label>
              <Input
                id="registered_name"
                value={registeredName}
                onChange={(e) => setRegisteredName(e.target.value)}
                placeholder="Ex.: João da Silva"
                readOnly={isEdit && !isSuperadmin}
                disabled={isEdit && !isSuperadmin}
                required
              />
              <p className="text-xs text-muted-foreground">
                {isEdit
                  ? isSuperadmin
                    ? "Como Super admin, você pode corrigir este nome. A alteração exige justificativa e será auditada."
                    : "Somente Super admin pode corrigir este nome cadastral."
                  : "Este será o nome cadastral e o nome de exibição inicial do Operador."}
              </p>
            </div>

            {isEdit && isSuperadmin && registeredName.trim() !== operator?.registered_name && (
              <div className="space-y-2 rounded-md border border-warning/40 bg-warning/5 p-3">
                <Label htmlFor="registered_name_reason">Justificativa da correção</Label>
                <Textarea
                  id="registered_name_reason"
                  value={registeredNameReason}
                  onChange={(event) => setRegisteredNameReason(event.target.value)}
                  placeholder="Explique por que o nome cadastral precisa ser corrigido."
                  maxLength={300}
                  rows={3}
                  required
                />
                <p className="text-xs text-muted-foreground">
                  Obrigatória, entre 3 e 300 caracteres. O nome de exibição no App não será alterado.
                </p>
              </div>
            )}

            {isEdit && operator && (
              <div className="space-y-2 rounded-md border border-border bg-muted/30 px-3 py-2.5">
                <Label htmlFor="current_display_name">Nome de exibição atual</Label>
                <Input id="current_display_name" value={operator.display_name} readOnly disabled />
                <p className="text-xs text-muted-foreground">
                  Este é o nome mostrado no App. As trocas e aprovações ficam na aba Nomes de exibição.
                </p>
              </div>
            )}

            <div className="space-y-2">
              <Label htmlFor="username">Usuário</Label>
              <Input
                id="username"
                value={username}
                onChange={(e) => setUsername(e.target.value)}
                placeholder="Ex.: joao.silva"
                autoCapitalize="none"
                required={!isEdit}
              />
              <p className="text-xs text-muted-foreground">
                Serve para o operador entrar no app (pode usar o usuário ou o e-mail).
              </p>
            </div>

            {isEdit && (
              <div className="space-y-2">
                <Label htmlFor="email_ro">E-mail de login</Label>
                <Input id="email_ro" value={loginEmail ?? "Carregando..."} readOnly disabled />
                <p className="text-xs text-muted-foreground">
                  O e-mail e a senha de login não são alterados por aqui.
                </p>
              </div>
            )}

            {!isEdit && (
              <>
                <div className="space-y-2">
                  <Label htmlFor="email">E-mail</Label>
                  <Input
                    id="email"
                    type="email"
                    value={email}
                    onChange={(e) => setEmail(e.target.value)}
                    placeholder="joao@exemplo.com"
                    autoCapitalize="none"
                    required
                  />
                </div>
                <div className="space-y-2">
                  <Label htmlFor="password">Senha</Label>
                  <Input
                    id="password"
                    type="password"
                    autoComplete="new-password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="Mínimo 6 caracteres"
                    required
                  />
                  <p className="text-xs text-muted-foreground">
                    Você define a senha e entrega ao operador.
                  </p>
                </div>
              </>
            )}

            <div className="space-y-2">
              <Label>Condomínio</Label>
              <Select value={unitId} onValueChange={setUnitId}>
                <SelectTrigger>
                  <SelectValue placeholder="Escolha o condomínio" />
                </SelectTrigger>
                <SelectContent>
                  {units.map((u) => (
                    <SelectItem key={u.id} value={u.id}>
                      {unitLabel(u)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            <div className="space-y-2">
              <Label>Turno</Label>
              <Select value={shiftKind} onValueChange={setShiftKind}>
                <SelectTrigger>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {SHIFT_TYPES.map((t) => (
                    <SelectItem key={t.value} value={t.value}>
                      {t.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {shiftKind === "6x1" && (
                <div className="grid grid-cols-2 gap-3 pt-1">
                  <div className="space-y-1">
                    <Label htmlFor="shift_start" className="text-xs text-muted-foreground">
                      Início
                    </Label>
                    <Input
                      id="shift_start"
                      type="time"
                      value={shiftStart}
                      onChange={(e) => setShiftStart(e.target.value)}
                    />
                  </div>
                  <div className="space-y-1">
                    <Label htmlFor="shift_end" className="text-xs text-muted-foreground">
                      Fim
                    </Label>
                    <Input
                      id="shift_end"
                      type="time"
                      value={shiftEnd}
                      onChange={(e) => setShiftEnd(e.target.value)}
                    />
                  </div>
                </div>
              )}
              <p className="text-xs text-muted-foreground">
                12x36 tem horário fixo. No 6x1 você define o horário (varia por condomínio).
              </p>
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
                    <SelectItem value="single">1 dispositivo</SelectItem>
                    <SelectItem value="multi">Vários dispositivos</SelectItem>
                  </SelectContent>
                </Select>
              </div>
            </div>

            <div className="flex items-center justify-between rounded-md border border-border px-3 py-2">
              <div>
                <Label htmlFor="active">Ativo</Label>
                <p className="text-xs text-muted-foreground">Operadores inativos não entram em plantão.</p>
              </div>
              <Switch id="active" checked={active} onCheckedChange={setActive} />
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
