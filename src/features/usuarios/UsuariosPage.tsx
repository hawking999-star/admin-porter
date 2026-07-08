import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Users, ShieldCheck, UserCheck, UserX, KeyRound } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { StatCard, StatusBadge, EmptyState, PaginationFooter } from "@/components/shared";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { useDebounce } from "@/hooks/useDebounce";
import {
  listOperators,
  listAdminUsers,
  listUnitOptions,
  countOperatorStats,
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
        title="Usuarios"
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

function OperadoresTab() {
  const pageSize = 25;
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(1);
  const [unitFilter, setUnitFilter] = useState("all");
  const [activeFilter, setActiveFilter] = useState<"all" | "active" | "inactive">("all");
  const [roleFilter, setRoleFilter] = useState("all");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Operator | null>(null);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, unitFilter, activeFilter, roleFilter]);

  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["operators", page, pageSize, debouncedSearch, unitFilter, activeFilter, roleFilter],
    queryFn: () =>
      listOperators({
        page,
        pageSize,
        search: debouncedSearch,
        unitId: unitFilter,
        active: activeFilter,
        role: roleFilter,
      }),
    staleTime: 30_000,
  });
  const statsQuery = useQuery({
    queryKey: ["operator-stats"],
    queryFn: countOperatorStats,
    staleTime: 30_000,
  });
  const unitOptionsQuery = useQuery({
    queryKey: ["unit-options"],
    queryFn: listUnitOptions,
    staleTime: 60_000,
  });

  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const stats = statsQuery.data ?? { active: 0, inactive: 0, supervisors: 0, noLogin: 0 };
  const hasFilters = Boolean(debouncedSearch.trim()) || unitFilter !== "all" || activeFilter !== "all" || roleFilter !== "all";

  const clearFilters = () => {
    setSearch("");
    setUnitFilter("all");
    setActiveFilter("all");
    setRoleFilter("all");
  };
  const openNew = () => {
    setEditing(null);
    setDialogOpen(true);
  };

  return (
    <>
      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard icon={<UserCheck className="h-5 w-5" />} iconClassName="bg-success/25 text-success-foreground" label="Operadores ativos" value={stats.active} loading={statsQuery.isLoading} />
        <StatCard icon={<UserX className="h-5 w-5" />} iconClassName="bg-muted text-muted-foreground" label="Operadores inativos" value={stats.inactive} loading={statsQuery.isLoading} />
        <StatCard icon={<ShieldCheck className="h-5 w-5" />} iconClassName="bg-secondary/10 text-secondary" label="Supervisores" value={stats.supervisors} loading={statsQuery.isLoading} />
        <StatCard icon={<KeyRound className="h-5 w-5" />} iconClassName="bg-warning/15 text-warning-foreground" label="Sem login vinculado" value={stats.noLogin} loading={statsQuery.isLoading} />
      </div>

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome ou usuario..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
        <Select value={unitFilter} onValueChange={setUnitFilter}>
          <SelectTrigger className="h-10 w-[210px] rounded-lg">
            <SelectValue placeholder="Condominio" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os condominios</SelectItem>
            {(unitOptionsQuery.data ?? []).map((unit) => (
              <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={activeFilter} onValueChange={(value) => setActiveFilter(value as "all" | "active" | "inactive")}>
          <SelectTrigger className="h-10 w-[150px] rounded-lg">
            <SelectValue placeholder="Status" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            <SelectItem value="active">Ativos</SelectItem>
            <SelectItem value="inactive">Inativos</SelectItem>
          </SelectContent>
        </Select>
        <Select value={roleFilter} onValueChange={setRoleFilter}>
          <SelectTrigger className="h-10 w-[150px] rounded-lg">
            <SelectValue placeholder="Cargo" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos</SelectItem>
            <SelectItem value="operador">Operador</SelectItem>
            <SelectItem value="supervisor">Supervisor</SelectItem>
          </SelectContent>
        </Select>
        {hasFilters && <Button variant="outline" onClick={clearFilters}>Limpar filtros</Button>}
        <span className="text-sm text-muted-foreground">{rows.length} de {total}</span>
        <Button className="ml-auto" onClick={openNew}>
          <Plus className="h-4 w-4" /> Novo operador
        </Button>
      </div>

      <Card className="overflow-hidden shadow-sm">
        {isError ? (
          <div className="p-6 text-sm text-destructive">Erro ao carregar: {(error as Error)?.message}</div>
        ) : (
          <div className="overflow-x-auto">
            <Table className="min-w-[860px]">
              <TableHeader>
                <TableRow>
                  <TableHead>Nome</TableHead>
                  <TableHead>Usuario</TableHead>
                  <TableHead>Condominio</TableHead>
                  <TableHead>Turno</TableHead>
                  <TableHead>Cargo</TableHead>
                  <TableHead>Login</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {isLoading && Array.from({ length: 4 }).map((_, i) => (
                  <TableRow key={i}><TableCell colSpan={7}><Skeleton className="h-6 w-full" /></TableCell></TableRow>
                ))}

                {!isLoading && rows.length === 0 && (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={7}>
                      {hasFilters ? (
                        <EmptyState icon={<Search className="h-6 w-6" />} title="Nenhum operador encontrado" description="Ajuste ou limpe os filtros para ampliar a busca." action={<Button variant="outline" size="sm" onClick={clearFilters}>Limpar filtros</Button>} />
                      ) : (
                        <EmptyState icon={<Users className="h-6 w-6" />} title="Nenhum operador cadastrado ainda." description="Cadastre operadores para vincular a condominios, turnos e playlists." action={<Button variant="outline" size="sm" onClick={openNew}><Plus className="h-4 w-4" /> Novo operador</Button>} />
                      )}
                    </TableCell>
                  </TableRow>
                )}

                {!isLoading && rows.map((op) => (
                  <TableRow key={op.id} className="cursor-pointer" onClick={() => { setEditing(op); setDialogOpen(true); }}>
                    <TableCell className="font-medium">{op.display_name}</TableCell>
                    <TableCell className="text-muted-foreground">{op.username ?? "-"}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {op.unit_name ? unitLabel({ name: op.unit_name, city: op.unit_city, state: op.unit_state }) : "-"}
                    </TableCell>
                    <TableCell className="text-muted-foreground whitespace-nowrap">{shiftLabel(op.shift_kind, op.shift_start, op.shift_end)}</TableCell>
                    <TableCell>{operatorRoleLabel(op.role)}</TableCell>
                    <TableCell><StatusBadge status={op.has_login ? "vinculado" : "sem_login"} /></TableCell>
                    <TableCell><StatusBadge status={op.active ? "ativo" : "inativo"} /></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Card>

      {!isLoading && !isError && rows.length > 0 && (
        <p className="mt-3 text-xs text-muted-foreground">Clique em um operador para editar cadastro, turno e vinculo.</p>
      )}
      {!isError && <PaginationFooter page={page} pageSize={pageSize} total={total} isLoading={isLoading || isFetching} onPageChange={setPage} />}

      <OperatorFormDialog open={dialogOpen} onOpenChange={setDialogOpen} operator={editing} />
    </>
  );
}

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
          <div className="p-6 text-sm text-destructive">Erro ao carregar: {(error as Error)?.message}</div>
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
                {isLoading && Array.from({ length: 3 }).map((_, i) => (
                  <TableRow key={i}><TableCell colSpan={4}><Skeleton className="h-6 w-full" /></TableCell></TableRow>
                ))}

                {!isLoading && (data ?? []).length === 0 && (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={4}>
                      <EmptyState icon={<ShieldCheck className="h-6 w-6" />} title="Nenhum acesso ao painel cadastrado." description="Os acessos administrativos aparecerao aqui apos serem criados." />
                    </TableCell>
                  </TableRow>
                )}

                {!isLoading && (data ?? []).map((a) => (
                  <TableRow key={a.id} className="cursor-pointer" onClick={() => { setEditing(a); setDialogOpen(true); }}>
                    <TableCell className="font-medium">{a.display_name}</TableCell>
                    <TableCell>{adminRoleLabel(a.role)}</TableCell>
                    <TableCell className="text-muted-foreground">{a.mfa_required ? "Sim" : "Nao"}</TableCell>
                    <TableCell><StatusBadge status={a.active ? "ativo" : "inativo"} /></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Card>

      <p className="mt-3 text-xs text-muted-foreground">
        Para criar um acesso novo e preciso criar o login primeiro (Supabase Auth). Passo a passo no relatorio do dev.
      </p>

      <AdminUserEditDialog open={dialogOpen} onOpenChange={setDialogOpen} adminUser={editing} />
    </>
  );
}
