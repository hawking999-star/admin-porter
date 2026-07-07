import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Users, ShieldCheck, UserCheck, UserX, KeyRound } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { StatCard, StatusBadge, EmptyState } from "@/components/shared";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  listOperators,
  listAdminUsers,
  operatorRoleLabel,
  adminRoleLabel,
  unitLabel,
  shiftLabel,
  type Operator,
  type AdminUser,
} from "./queries";
import { OperatorFormDialog } from "./OperatorFormDialog";
import { AdminUserEditDialog } from "./AdminUserEditDialog";

export function UsuariosPage() {
  return (
    <>
      <PageHeader
        title="Usuários"
        description="Operadores que usam o app e pessoas com acesso ao painel."
      />
      <Tabs defaultValue="operadores">
        <TabsList className="mb-4">
          <TabsTrigger value="operadores">
            <Users className="mr-1.5 h-4 w-4" /> Operadores
          </TabsTrigger>
          <TabsTrigger value="acessos">
            <ShieldCheck className="mr-1.5 h-4 w-4" /> Acessos ao admin
          </TabsTrigger>
        </TabsList>
        <TabsContent value="operadores">
          <OperadoresTab />
        </TabsContent>
        <TabsContent value="acessos">
          <AcessosTab />
        </TabsContent>
      </Tabs>
    </>
  );
}

/* ------------------------------- Operadores ------------------------------ */

function OperadoresTab() {
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["operators"],
    queryFn: listOperators,
    staleTime: 30_000,
  });
  const [search, setSearch] = useState("");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Operator | null>(null);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return data ?? [];
    return (data ?? []).filter(
      (o) =>
        o.display_name.toLowerCase().includes(term) ||
        (o.username ?? "").toLowerCase().includes(term) ||
        (o.unit_name ?? "").toLowerCase().includes(term) ||
        (o.unit_city ?? "").toLowerCase().includes(term),
    );
  }, [data, search]);

  const stats = useMemo(() => {
    const all = data ?? [];
    return {
      active: all.filter((o) => o.active).length,
      inactive: all.filter((o) => !o.active).length,
      supervisors: all.filter((o) => o.role === "supervisor").length,
      noLogin: all.filter((o) => !o.has_login).length,
    };
  }, [data]);

  const openNew = () => {
    setEditing(null);
    setDialogOpen(true);
  };

  return (
    <>
      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<UserCheck className="h-5 w-5" />}
          iconClassName="bg-success/25 text-success-foreground"
          label="Operadores ativos"
          value={stats.active}
          loading={isLoading}
        />
        <StatCard
          icon={<UserX className="h-5 w-5" />}
          iconClassName="bg-muted text-muted-foreground"
          label="Operadores inativos"
          value={stats.inactive}
          loading={isLoading}
        />
        <StatCard
          icon={<ShieldCheck className="h-5 w-5" />}
          iconClassName="bg-secondary/10 text-secondary"
          label="Supervisores"
          value={stats.supervisors}
          loading={isLoading}
        />
        <StatCard
          icon={<KeyRound className="h-5 w-5" />}
          iconClassName="bg-warning/15 text-warning-foreground"
          label="Sem login vinculado"
          value={stats.noLogin}
          loading={isLoading}
        />
      </div>

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome, usuário ou condomínio..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
        {data && (
          <span className="text-sm text-muted-foreground">
            {filtered.length} de {data.length}
          </span>
        )}
        <Button className="ml-auto" onClick={openNew}>
          <Plus className="h-4 w-4" /> Novo operador
        </Button>
      </div>

      <Card className="overflow-hidden shadow-sm">
        {isError ? (
          <div className="p-6 text-sm text-destructive">
            Erro ao carregar: {(error as Error)?.message}
          </div>
        ) : (
          <div className="overflow-x-auto">
          <Table className="min-w-[860px]">
            <TableHeader>
              <TableRow>
                <TableHead>Nome</TableHead>
                <TableHead>Usuário</TableHead>
                <TableHead>Condomínio</TableHead>
                <TableHead>Turno</TableHead>
                <TableHead>Cargo</TableHead>
                <TableHead>Login</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading &&
                Array.from({ length: 4 }).map((_, i) => (
                  <TableRow key={i}>
                    <TableCell colSpan={7}>
                      <Skeleton className="h-6 w-full" />
                    </TableCell>
                  </TableRow>
                ))}

              {!isLoading && filtered.length === 0 && (
                <TableRow className="hover:bg-transparent">
                  <TableCell colSpan={7}>
                    {search ? (
                      <EmptyState
                        icon={<Search className="h-6 w-6" />}
                        title="Nenhum operador encontrado"
                        description="Ajuste a busca por nome, usuário ou condomínio."
                      />
                    ) : (
                      <EmptyState
                        icon={<Users className="h-6 w-6" />}
                        title="Nenhum operador cadastrado ainda."
                        description="Cadastre operadores para vincular a condomínios, turnos e playlists."
                        action={
                          <Button variant="outline" size="sm" onClick={openNew}>
                            <Plus className="h-4 w-4" /> Novo operador
                          </Button>
                        }
                      />
                    )}
                  </TableCell>
                </TableRow>
              )}

              {!isLoading &&
                filtered.map((op) => (
                  <TableRow
                    key={op.id}
                    className="cursor-pointer"
                    onClick={() => {
                      setEditing(op);
                      setDialogOpen(true);
                    }}
                  >
                    <TableCell className="font-medium">{op.display_name}</TableCell>
                    <TableCell className="text-muted-foreground">{op.username ?? "—"}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {op.unit_name
                        ? unitLabel({ name: op.unit_name, city: op.unit_city, state: op.unit_state })
                        : "—"}
                    </TableCell>
                    <TableCell className="text-muted-foreground whitespace-nowrap">
                      {shiftLabel(op.shift_kind, op.shift_start, op.shift_end)}
                    </TableCell>
                    <TableCell>{operatorRoleLabel(op.role)}</TableCell>
                    <TableCell>
                      <StatusBadge status={op.has_login ? "vinculado" : "sem_login"} />
                    </TableCell>
                    <TableCell>
                      <StatusBadge status={op.active ? "ativo" : "inativo"} />
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          </div>
        )}
      </Card>

      {!isLoading && !isError && filtered.length > 0 && (
        <p className="mt-3 text-xs text-muted-foreground">
          Clique em um operador para editar cadastro, turno e vínculo.
        </p>
      )}

      <OperatorFormDialog open={dialogOpen} onOpenChange={setDialogOpen} operator={editing} />
    </>
  );
}

/* -------------------------------- Acessos -------------------------------- */

function AcessosTab() {
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["admin-users"],
    queryFn: listAdminUsers,
    staleTime: 30_000,
  });
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<AdminUser | null>(null);

  return (
    <>
      <Card className="overflow-hidden shadow-sm">
        {isError ? (
          <div className="p-6 text-sm text-destructive">
            Erro ao carregar: {(error as Error)?.message}
          </div>
        ) : (
          <div className="overflow-x-auto">
          <Table className="min-w-[720px]">
            <TableHeader>
              <TableRow>
                <TableHead>Nome</TableHead>
                <TableHead>Papel</TableHead>
                <TableHead>2FA</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading &&
                Array.from({ length: 3 }).map((_, i) => (
                  <TableRow key={i}>
                    <TableCell colSpan={4}>
                      <Skeleton className="h-6 w-full" />
                    </TableCell>
                  </TableRow>
                ))}

              {!isLoading && (data ?? []).length === 0 && (
                <TableRow className="hover:bg-transparent">
                  <TableCell colSpan={4}>
                    <EmptyState
                      icon={<ShieldCheck className="h-6 w-6" />}
                      title="Nenhum acesso ao painel cadastrado."
                      description="Os acessos administrativos aparecerão aqui após serem criados."
                    />
                  </TableCell>
                </TableRow>
              )}

              {!isLoading &&
                (data ?? []).map((a) => (
                  <TableRow
                    key={a.id}
                    className="cursor-pointer"
                    onClick={() => {
                      setEditing(a);
                      setDialogOpen(true);
                    }}
                  >
                    <TableCell className="font-medium">{a.display_name}</TableCell>
                    <TableCell>{adminRoleLabel(a.role)}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {a.mfa_required ? "Sim" : "Não"}
                    </TableCell>
                    <TableCell>
                      <StatusBadge status={a.active ? "ativo" : "inativo"} />
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
          </div>
        )}
      </Card>

      <p className="mt-3 text-xs text-muted-foreground">
        Para criar um acesso novo é preciso criar o login primeiro (Supabase Auth). Passo a passo no
        relatório do dev.
      </p>

      <AdminUserEditDialog open={dialogOpen} onOpenChange={setDialogOpen} adminUser={editing} />
    </>
  );
}
