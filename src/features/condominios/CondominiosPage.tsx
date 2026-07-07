import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Building2, Users, MapPin, Power } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { StatCard, StatusBadge, EmptyState } from "@/components/shared";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { listUnits, timezoneLabel, type Unit } from "./queries";
import { CondominioFormDialog } from "./CondominioFormDialog";

export function CondominiosPage() {
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["units"],
    queryFn: listUnits,
    staleTime: 30_000,
  });

  const [search, setSearch] = useState("");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<Unit | null>(null);

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return data ?? [];
    return (data ?? []).filter(
      (u) =>
        u.name.toLowerCase().includes(term) ||
        u.code.toLowerCase().includes(term) ||
        (u.city ?? "").toLowerCase().includes(term),
    );
  }, [data, search]);

  const stats = useMemo(() => {
    const all = data ?? [];
    const cities = new Set(
      all.filter((u) => u.active && u.city).map((u) => `${u.city}/${u.state ?? ""}`),
    );
    return {
      active: all.filter((u) => u.active).length,
      operators: all.reduce((sum, u) => sum + (u.operator_count ?? 0), 0),
      cities: cities.size,
      inactive: all.filter((u) => !u.active).length,
    };
  }, [data]);

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
        action={
          <Button onClick={openNew}>
            <Plus className="h-4 w-4" /> Novo condomínio
          </Button>
        }
      />

      {/* Cards de resumo */}
      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<Building2 className="h-5 w-5" />}
          iconClassName="bg-primary/10 text-primary"
          label="Condomínios ativos"
          value={stats.active}
          loading={isLoading}
        />
        <StatCard
          icon={<Users className="h-5 w-5" />}
          iconClassName="bg-secondary/10 text-secondary"
          label="Operadores vinculados"
          value={stats.operators}
          loading={isLoading}
        />
        <StatCard
          icon={<MapPin className="h-5 w-5" />}
          iconClassName="bg-success/25 text-success-foreground"
          label="Cidades atendidas"
          value={stats.cities}
          loading={isLoading}
        />
        <StatCard
          icon={<Power className="h-5 w-5" />}
          iconClassName="bg-muted text-muted-foreground"
          label="Condomínios inativos"
          value={stats.inactive}
          loading={isLoading}
        />
      </div>

      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome, código ou cidade..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
        {data && (
          <span className="ml-auto text-sm text-muted-foreground">
            {filtered.length} de {data.length}
          </span>
        )}
      </div>

      <Card className="overflow-hidden shadow-sm">
        {isError ? (
          <div className="p-6 text-sm text-destructive">
            Erro ao carregar: {(error as Error)?.message}
          </div>
        ) : (
          <div className="overflow-x-auto">
          <Table className="min-w-[760px]">
            <TableHeader>
              <TableRow>
                <TableHead>Nome</TableHead>
                <TableHead>Código</TableHead>
                <TableHead>Cidade</TableHead>
                <TableHead>Operadores</TableHead>
                <TableHead>Fuso</TableHead>
                <TableHead>Status</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading &&
                Array.from({ length: 4 }).map((_, i) => (
                  <TableRow key={i}>
                    <TableCell colSpan={6}>
                      <Skeleton className="h-6 w-full" />
                    </TableCell>
                  </TableRow>
                ))}

              {!isLoading && filtered.length === 0 && (
                <TableRow className="hover:bg-transparent">
                  <TableCell colSpan={6}>
                    {search ? (
                      <EmptyState
                        icon={<Search className="h-6 w-6" />}
                        title="Nenhum condomínio encontrado"
                        description="Ajuste a busca para encontrar a unidade que procura."
                      />
                    ) : (
                      <EmptyState
                        icon={<Building2 className="h-6 w-6" />}
                        title="Você ainda tem poucos condomínios cadastrados."
                        description="Cadastre novas unidades para vincular operadores, playlists e métricas da operação."
                        action={
                          <Button variant="outline" size="sm" onClick={openNew}>
                            <Plus className="h-4 w-4" /> Novo condomínio
                          </Button>
                        }
                      />
                    )}
                  </TableCell>
                </TableRow>
              )}

              {!isLoading &&
                filtered.map((unit) => (
                  <TableRow
                    key={unit.id}
                    className="cursor-pointer"
                    onClick={() => openEdit(unit)}
                  >
                    <TableCell className="font-medium">{unit.name}</TableCell>
                    <TableCell className="text-muted-foreground">{unit.code}</TableCell>
                    <TableCell className="text-muted-foreground">
                      {unit.city ? (
                        <>
                          {unit.city}
                          {unit.state ? `/${unit.state}` : ""}
                        </>
                      ) : (
                        "—"
                      )}
                    </TableCell>
                    <TableCell>{unit.operator_count}</TableCell>
                    <TableCell className="text-muted-foreground">{timezoneLabel(unit.timezone)}</TableCell>
                    <TableCell>
                      <StatusBadge status={unit.active ? "ativo" : "inativo"} />
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
          Clique em um condomínio para editar os dados da unidade.
        </p>
      )}

      <CondominioFormDialog open={dialogOpen} onOpenChange={setDialogOpen} unit={editing} />
    </>
  );
}
