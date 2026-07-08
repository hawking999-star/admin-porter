import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Building2, Users, MapPin, Power } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { StatCard, StatusBadge, EmptyState, PaginationFooter } from "@/components/shared";
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
import { countUnitStats, listUnits, timezoneLabel, type Unit } from "./queries";
import { CondominioFormDialog } from "./CondominioFormDialog";

export function CondominiosPage() {
  const pageSize = 25;
  const [search, setSearch] = useState("");
  const [activeFilter, setActiveFilter] = useState<"all" | "active" | "inactive">("all");
  const [page, setPage] = useState(1);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Unit | null>(null);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, activeFilter]);

  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["units", page, pageSize, debouncedSearch, activeFilter],
    queryFn: () => listUnits({ page, pageSize, search: debouncedSearch, active: activeFilter }),
    staleTime: 30_000,
  });
  const statsQuery = useQuery({
    queryKey: ["unit-stats"],
    queryFn: countUnitStats,
    staleTime: 30_000,
  });

  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const stats = statsQuery.data ?? { active: 0, inactive: 0, operators: 0, cities: null };
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
        title="Condominios"
        description="Unidades vinculadas a operacao e aos operadores."
        action={<Button onClick={openNew}><Plus className="h-4 w-4" /> Novo condominio</Button>}
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard icon={<Building2 className="h-5 w-5" />} iconClassName="bg-primary/10 text-primary" label="Condominios ativos" value={stats.active} loading={statsQuery.isLoading} />
        <StatCard icon={<Users className="h-5 w-5" />} iconClassName="bg-secondary/10 text-secondary" label="Operadores vinculados" value={stats.operators} loading={statsQuery.isLoading} />
        <StatCard icon={<MapPin className="h-5 w-5" />} iconClassName="bg-success/25 text-success-foreground" label="Cidades atendidas" value={stats.cities ?? "-"} hint="Confirmar via SQL remoto" loading={statsQuery.isLoading} />
        <StatCard icon={<Power className="h-5 w-5" />} iconClassName="bg-muted text-muted-foreground" label="Condominios inativos" value={stats.inactive} loading={statsQuery.isLoading} />
      </div>

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome, codigo ou cidade..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
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
        <span className="ml-auto text-sm text-muted-foreground">{rows.length} de {total}</span>
      </div>

      <Card className="overflow-hidden shadow-sm">
        {isError ? (
          <div className="p-6 text-sm text-destructive">Erro ao carregar: {(error as Error)?.message}</div>
        ) : (
          <div className="overflow-x-auto">
            <Table className="min-w-[760px]">
              <TableHeader>
                <TableRow>
                  <TableHead>Nome</TableHead>
                  <TableHead>Codigo</TableHead>
                  <TableHead>Cidade</TableHead>
                  <TableHead>Operadores</TableHead>
                  <TableHead>Fuso</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {isLoading && Array.from({ length: 4 }).map((_, i) => (
                  <TableRow key={i}><TableCell colSpan={6}><Skeleton className="h-6 w-full" /></TableCell></TableRow>
                ))}

                {!isLoading && rows.length === 0 && (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={6}>
                      {hasFilters ? (
                        <EmptyState icon={<Search className="h-6 w-6" />} title="Nenhum condominio encontrado" description="Ajuste ou limpe os filtros para encontrar a unidade." action={<Button variant="outline" size="sm" onClick={clearFilters}>Limpar filtros</Button>} />
                      ) : (
                        <EmptyState icon={<Building2 className="h-6 w-6" />} title="Voce ainda tem poucos condominios cadastrados." description="Cadastre novas unidades para vincular operadores, playlists e metricas da operacao." action={<Button variant="outline" size="sm" onClick={openNew}><Plus className="h-4 w-4" /> Novo condominio</Button>} />
                      )}
                    </TableCell>
                  </TableRow>
                )}

                {!isLoading && rows.map((unit) => (
                  <TableRow key={unit.id} className="cursor-pointer" onClick={() => openEdit(unit)}>
                    <TableCell className="font-medium">{unit.name}</TableCell>
                    <TableCell className="text-muted-foreground">{unit.code}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {unit.city ? <>{unit.city}{unit.state ? `/${unit.state}` : ""}</> : "-"}
                    </TableCell>
                    <TableCell>{unit.operator_count}</TableCell>
                    <TableCell className="text-muted-foreground">{timezoneLabel(unit.timezone)}</TableCell>
                    <TableCell><StatusBadge status={unit.active ? "ativo" : "inativo"} /></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </Card>

      {!isLoading && !isError && rows.length > 0 && (
        <p className="mt-3 text-xs text-muted-foreground">Clique em um condominio para editar os dados da unidade.</p>
      )}
      {!isError && <PaginationFooter page={page} pageSize={pageSize} total={total} isLoading={isLoading || isFetching} onPageChange={setPage} />}

      <CondominioFormDialog open={dialogOpen} onOpenChange={setDialogOpen} unit={editing} />
    </>
  );
}
