import { useEffect, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useSearchParams } from "react-router-dom";
import { toast } from "sonner";
import { Plus, Search, Users, ShieldCheck, UserCheck, UserX, KeyRound, MoreHorizontal, Pencil, Power, PowerOff } from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  StatCard,
  StatusBadge,
  EmptyState,
  ErrorState,
  RetryButton,
  SearchInput,
  FilterBar,
  DataTable,
  PaginationFooter,
} from "@/components/shared";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import {
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
  setOperatorActive,
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
        description="Operadores que usam o app e pessoas com acesso ao painel administrativo."
      />
      <Tabs defaultValue="operadores">
        <TabsList className="mb-4">
          <TabsTrigger value="operadores">
            <Users className="mr-1.5 h-4 w-4" /> Operadores
          </TabsTrigger>
          <TabsTrigger value="acessos">
            <ShieldCheck className="mr-1.5 h-4 w-4" /> Acessos ao painel
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
  const qc = useQueryClient();
  const [searchParams] = useSearchParams();
  const [pageSize, setPageSize] = useState(25);
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(1);
  const [unitFilter, setUnitFilter] = useState(searchParams.get("unit") ?? "all");
  const [activeFilter, setActiveFilter] = useState<"all" | "active" | "inactive">("all");
  const [roleFilter, setRoleFilter] = useState("all");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Operator | null>(null);
  const [confirmToggle, setConfirmToggle] = useState<Operator | null>(null);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, unitFilter, activeFilter, roleFilter]);

  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
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

  const toggleMutation = useMutation({
    mutationFn: ({ op, active }: { op: Operator; active: boolean }) => setOperatorActive(op, active),
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ["operators"] });
      qc.invalidateQueries({ queryKey: ["operator-stats"] });
      toast.success(vars.active ? "Operador ativado" : "Operador desativado");
      setConfirmToggle(null);
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível atualizar", {
        description: err instanceof Error ? err.message : "Erro inesperado",
      });
    },
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
  const openEdit = (op: Operator) => {
    setEditing(op);
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

      <FilterBar>
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar por nome ou usuário..."
        />
        <Select value={unitFilter} onValueChange={setUnitFilter}>
          <SelectTrigger className="h-10 w-[210px] rounded-lg">
            <SelectValue placeholder="Condomínio" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os condomínios</SelectItem>
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
        <div className="ml-auto flex items-center gap-3">
          <span className="text-sm text-muted-foreground">{rows.length} de {total}</span>
          <Button onClick={openNew}>
            <Plus className="h-4 w-4" /> Novo operador
          </Button>
        </div>
      </FilterBar>

      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar os operadores."
            description={(error as Error)?.message}
            action={<RetryButton onClick={() => refetch()} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <DataTable minWidth={920}>
          <TableHeader>
            <TableRow>
              <TableHead>Nome</TableHead>
              <TableHead>Usuário</TableHead>
              <TableHead>Condomínio</TableHead>
              <TableHead>Turno</TableHead>
              <TableHead>Cargo</TableHead>
              <TableHead>Login</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="w-[64px] text-right">Ações</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {isLoading && Array.from({ length: 4 }).map((_, i) => (
              <TableRow key={i}><TableCell colSpan={8}><Skeleton className="h-6 w-full" /></TableCell></TableRow>
            ))}

            {!isLoading && rows.length === 0 && (
              <TableRow className="hover:bg-transparent">
                <TableCell colSpan={8}>
                  {hasFilters ? (
                    <EmptyState icon={<Search className="h-6 w-6" />} title="Nenhum operador encontrado." description="Ajuste ou limpe os filtros para ampliar a busca." action={<Button variant="outline" size="sm" onClick={clearFilters}>Limpar filtros</Button>} />
                  ) : (
                    <EmptyState icon={<Users className="h-6 w-6" />} title="Nenhum operador cadastrado ainda." description="Cadastre um operador para vincular a condomínios, turnos e playlists." action={<Button variant="outline" size="sm" onClick={openNew}><Plus className="h-4 w-4" /> Novo operador</Button>} />
                  )}
                </TableCell>
              </TableRow>
            )}

            {!isLoading && rows.map((op) => (
              <TableRow key={op.id} className="cursor-pointer" onClick={() => openEdit(op)}>
                <TableCell className="font-medium">{op.display_name}</TableCell>
                <TableCell className="text-muted-foreground">{op.username ?? "—"}</TableCell>
                <TableCell className="text-muted-foreground">
                  {op.unit_name ? unitLabel({ name: op.unit_name, city: op.unit_city, state: op.unit_state }) : "—"}
                </TableCell>
                <TableCell className="text-muted-foreground whitespace-nowrap">{shiftLabel(op.shift_kind, op.shift_start, op.shift_end)}</TableCell>
                <TableCell>{operatorRoleLabel(op.role)}</TableCell>
                <TableCell><StatusBadge status={op.has_login ? "vinculado" : "sem_login"} /></TableCell>
                <TableCell><StatusBadge status={op.active ? "ativo" : "inativo"} /></TableCell>
                <TableCell className="text-right" onClick={(e) => e.stopPropagation()}>
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="Ações do operador">
                        <MoreHorizontal className="h-4 w-4" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem onClick={() => openEdit(op)}>
                        <Pencil className="h-4 w-4" /> Editar
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      {op.active ? (
                        <DropdownMenuItem className="text-destructive focus:text-destructive" onClick={() => setConfirmToggle(op)}>
                          <PowerOff className="h-4 w-4" /> Desativar
                        </DropdownMenuItem>
                      ) : (
                        <DropdownMenuItem onClick={() => setConfirmToggle(op)}>
                          <Power className="h-4 w-4" /> Ativar
                        </DropdownMenuItem>
                      )}
                    </DropdownMenuContent>
                  </DropdownMenu>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </DataTable>
      )}

      {!isLoading && !isError && rows.length > 0 && (
        <p className="mt-3 text-xs text-muted-foreground">Clique na linha para editar, ou use o menu de ações para ativar/desativar.</p>
      )}
      {!isError && (
        <PaginationFooter
          page={page}
          pageSize={pageSize}
          total={total}
          isLoading={isLoading || isFetching}
          onPageChange={setPage}
          onPageSizeChange={(value) => {
            setPageSize(value);
            setPage(1);
          }}
        />
      )}

      <OperatorFormDialog open={dialogOpen} onOpenChange={setDialogOpen} operator={editing} />

      <AlertDialog open={Boolean(confirmToggle)} onOpenChange={(o) => !o && setConfirmToggle(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{confirmToggle?.active ? "Desativar operador?" : "Ativar operador?"}</AlertDialogTitle>
            <AlertDialogDescription>
              {confirmToggle?.active
                ? `${confirmToggle?.display_name} deixará de acessar o app até ser reativado.`
                : `${confirmToggle?.display_name} voltará a ter acesso ao app.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={toggleMutation.isPending}>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              disabled={toggleMutation.isPending}
              className={cn(confirmToggle?.active && "bg-destructive text-destructive-foreground hover:bg-destructive/90")}
              onClick={(e) => {
                e.preventDefault();
                if (confirmToggle) toggleMutation.mutate({ op: confirmToggle, active: !confirmToggle.active });
              }}
            >
              {confirmToggle?.active ? "Desativar" : "Ativar"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

function AcessosTab() {
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
    queryKey: ["admin-users", page, pageSize],
    queryFn: () => listAdminUsers({ page, pageSize }),
    staleTime: 30_000,
  });
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<AdminUser | null>(null);
  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;

  return (
    <>
      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar os acessos."
            description={(error as Error)?.message}
            action={<RetryButton onClick={() => refetch()} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <DataTable minWidth={720}>
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

            {!isLoading && rows.length === 0 && (
              <TableRow className="hover:bg-transparent">
                <TableCell colSpan={4}>
                  <EmptyState icon={<ShieldCheck className="h-6 w-6" />} title="Nenhum acesso ao painel cadastrado." description="Os acessos administrativos aparecerão aqui após serem criados." />
                </TableCell>
              </TableRow>
            )}

            {!isLoading && rows.map((a) => (
              <TableRow key={a.id} className="cursor-pointer" onClick={() => { setEditing(a); setDialogOpen(true); }}>
                <TableCell className="font-medium">{a.display_name}</TableCell>
                <TableCell>{adminRoleLabel(a.role)}</TableCell>
                <TableCell className="text-muted-foreground">{a.mfa_required ? "Sim" : "Não"}</TableCell>
                <TableCell><StatusBadge status={a.active ? "ativo" : "inativo"} /></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </DataTable>
      )}

      {!isError && (
        <PaginationFooter
          page={page}
          pageSize={pageSize}
          total={total}
          isLoading={isLoading || isFetching}
          onPageChange={setPage}
          onPageSizeChange={(value) => {
            setPageSize(value);
            setPage(1);
          }}
        />
      )}

      <p className="mt-3 text-xs text-muted-foreground">
        Para criar um novo acesso, é preciso primeiro criar o login no Supabase Auth. O passo a passo está no relatório técnico.
      </p>

      <AdminUserEditDialog open={dialogOpen} onOpenChange={setDialogOpen} adminUser={editing} />
    </>
  );
}
