import { useEffect, useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "react-router-dom";
import { toast } from "sonner";
import { Plus, Search, Building, Building2, Users, Power, PowerOff, MoreHorizontal, Pencil } from "lucide-react";
import { cn } from "@/lib/utils";
import { errorMessage } from "@/lib/errors";
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
  ExportCsvButton,
} from "@/components/shared";
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
import { useUrlFilterState } from "@/hooks/useUrlFilterState";
import { countUnitStats, listUnits, setUnitActive, timezoneLabel, type Unit } from "./queries";
import { CondominioFormDialog } from "./CondominioFormDialog";
import type { CsvColumn } from "@/lib/csv";

const UNIT_EXPORT_COLUMNS: CsvColumn<Unit>[] = [
  { header: "nome", value: (row) => row.name },
  { header: "codigo", value: (row) => row.code },
  { header: "cidade", value: (row) => row.city },
  { header: "estado", value: (row) => row.state },
  { header: "operadores", value: (row) => row.operator_count },
  { header: "status", value: (row) => row.active ? "ativo" : "inativo" },
  { header: "criado_em", value: (row) => row.created_at },
];

export function CondominiosPage() {
  const qc = useQueryClient();
  const navigate = useNavigate();
  const [pageSize, setPageSize] = useState(25);
  const [search, setSearch] = useUrlFilterState("q", "");
  const [activeFilter, setActiveFilter] = useUrlFilterState<"all" | "active" | "inactive">("active", "all", ["all", "active", "inactive"]);
  const [page, setPage] = useState(1);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Unit | null>(null);
  const [confirmToggle, setConfirmToggle] = useState<Unit | null>(null);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, activeFilter]);

  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
    queryKey: ["units", page, pageSize, debouncedSearch, activeFilter],
    queryFn: () => listUnits({ page, pageSize, search: debouncedSearch, active: activeFilter }),
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  });
  const statsQuery = useQuery({
    queryKey: ["unit-stats"],
    queryFn: countUnitStats,
    staleTime: 30_000,
  });

  const toggleMutation = useMutation({
    mutationFn: ({ unit, active }: { unit: Unit; active: boolean }) => setUnitActive(unit, active),
    onSuccess: (_d, vars) => {
      qc.invalidateQueries({ queryKey: ["units"] });
      qc.invalidateQueries({ queryKey: ["unit-stats"] });
      toast.success(vars.active ? "Condomínio ativado" : "Condomínio desativado");
      setConfirmToggle(null);
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível atualizar", {
        description: errorMessage(err),
      });
    },
  });

  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const stats = statsQuery.data ?? { active: 0, inactive: 0, operators: 0, cities: null };
  const totalUnits = stats.active + stats.inactive;
  const hasFilters = Boolean(debouncedSearch.trim()) || activeFilter !== "all";

  const clearFilters = () => {
    setSearch("");
    setActiveFilter("all");
  };
  const openNew = () => {
    setEditing(null);
    setDialogOpen(true);
  };
  const openEdit = (unit: Unit) => {
    setEditing(unit);
    setDialogOpen(true);
  };

  return (
    <>
      <PageHeader
        title="Condomínios"
        description="Unidades vinculadas à operação e aos operadores."
        action={<><ExportCsvButton filename="condominios-filtrados" rows={rows} columns={UNIT_EXPORT_COLUMNS} /><Button onClick={openNew}><Plus className="h-4 w-4" /> Novo condomínio</Button></>}
      />

      <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard icon={<Building2 className="h-5 w-5" />} iconClassName="bg-primary/10 text-primary" label="Condomínios ativos" value={stats.active} loading={statsQuery.isLoading} />
        <StatCard icon={<Users className="h-5 w-5" />} iconClassName="bg-secondary/10 text-secondary" label="Operadores vinculados" value={stats.operators} loading={statsQuery.isLoading} />
        <StatCard icon={<Building className="h-5 w-5" />} iconClassName="bg-success/25 text-success-foreground" label="Total de condomínios" value={totalUnits} loading={statsQuery.isLoading} />
        <StatCard icon={<Power className="h-5 w-5" />} iconClassName="bg-muted text-muted-foreground" label="Condomínios inativos" value={stats.inactive} loading={statsQuery.isLoading} />
      </div>

      <FilterBar resultText={!isError ? `${rows.length} de ${total}` : undefined}>
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar por nome, código ou cidade..."
        />
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
        {hasFilters && <Button variant="outline" onClick={clearFilters}>Limpar filtros</Button>}
      </FilterBar>

      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar os condomínios."
            description={(error as Error)?.message}
            action={<RetryButton onClick={() => refetch()} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <DataTable minWidth={860}>
          <TableHeader>
            <TableRow>
              <TableHead>Nome</TableHead>
              <TableHead>Código</TableHead>
              <TableHead>Cidade</TableHead>
              <TableHead>Operadores</TableHead>
              <TableHead>Fuso</TableHead>
              <TableHead>Status</TableHead>
              <TableHead className="w-[64px] text-right">Ações</TableHead>
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
                    <EmptyState icon={<Search className="h-6 w-6" />} title="Nenhum condomínio encontrado." description="Ajuste ou limpe os filtros para encontrar a unidade." action={<Button variant="outline" size="sm" onClick={clearFilters}>Limpar filtros</Button>} />
                  ) : (
                    <EmptyState icon={<Building2 className="h-6 w-6" />} title="Nenhum condomínio cadastrado ainda." description="Cadastre um condomínio para vincular operadores, turnos e playlists da operação." action={<Button variant="outline" size="sm" onClick={openNew}><Plus className="h-4 w-4" /> Novo condomínio</Button>} />
                  )}
                </TableCell>
              </TableRow>
            )}

            {!isLoading && rows.map((unit) => (
              <TableRow key={unit.id} className="cursor-pointer" onClick={() => openEdit(unit)}>
                <TableCell className="font-medium">{unit.name}</TableCell>
                <TableCell className="text-muted-foreground">{unit.code}</TableCell>
                <TableCell className="text-muted-foreground">
                  {unit.city ? <>{unit.city}{unit.state ? `/${unit.state}` : ""}</> : "—"}
                </TableCell>
                <TableCell>{unit.operator_count}</TableCell>
                <TableCell className="text-muted-foreground">{timezoneLabel(unit.timezone)}</TableCell>
                <TableCell><StatusBadge status={unit.active ? "ativo" : "inativo"} /></TableCell>
                <TableCell className="text-right" onClick={(e) => e.stopPropagation()}>
                  <DropdownMenu>
                    <DropdownMenuTrigger asChild>
                      <Button variant="ghost" size="icon" className="h-8 w-8" aria-label="Ações do condomínio">
                        <MoreHorizontal className="h-4 w-4" />
                      </Button>
                    </DropdownMenuTrigger>
                    <DropdownMenuContent align="end">
                      <DropdownMenuItem onClick={() => openEdit(unit)}>
                        <Pencil className="h-4 w-4" /> Editar
                      </DropdownMenuItem>
                      <DropdownMenuItem onClick={() => navigate(`/usuarios?unit=${unit.id}`)}>
                        <Users className="h-4 w-4" /> Ver operadores
                      </DropdownMenuItem>
                      <DropdownMenuSeparator />
                      {unit.active ? (
                        <DropdownMenuItem className="text-destructive focus:text-destructive" onClick={() => setConfirmToggle(unit)}>
                          <PowerOff className="h-4 w-4" /> Desativar
                        </DropdownMenuItem>
                      ) : (
                        <DropdownMenuItem onClick={() => setConfirmToggle(unit)}>
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
        <p className="mt-3 text-xs text-muted-foreground">Clique na linha para editar, ou use o menu de ações para ver operadores e ativar/desativar.</p>
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

      <CondominioFormDialog open={dialogOpen} onOpenChange={setDialogOpen} unit={editing} />

      <AlertDialog open={Boolean(confirmToggle)} onOpenChange={(o) => !o && setConfirmToggle(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>{confirmToggle?.active ? "Desativar condomínio?" : "Ativar condomínio?"}</AlertDialogTitle>
            <AlertDialogDescription>
              {confirmToggle?.active
                ? `${confirmToggle?.name} deixará de aparecer para vínculos e operações até ser reativado.`
                : `${confirmToggle?.name} voltará a ficar disponível para vínculos e operações.`}
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={toggleMutation.isPending}>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              disabled={toggleMutation.isPending}
              className={cn(confirmToggle?.active && "bg-destructive text-destructive-foreground hover:bg-destructive/90")}
              onClick={(e) => {
                e.preventDefault();
                if (confirmToggle) toggleMutation.mutate({ unit: confirmToggle, active: !confirmToggle.active });
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
