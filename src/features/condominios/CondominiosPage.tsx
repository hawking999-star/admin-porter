import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Building2 } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
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
        description="Unidades onde os operadores trabalham. Base de toda a operação."
        action={
          <Button onClick={openNew}>
            <Plus className="mr-1 h-4 w-4" /> Novo condomínio
          </Button>
        }
      />

      <div className="mb-4 flex items-center gap-2">
        <div className="relative w-full max-w-xs">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome ou código..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-8"
          />
        </div>
        {data && (
          <span className="text-sm text-muted-foreground">
            {filtered.length} de {data.length}
          </span>
        )}
      </div>

      <Card>
        {isError ? (
          <div className="p-6 text-sm text-destructive">
            Erro ao carregar: {(error as Error)?.message}
          </div>
        ) : (
          <Table>
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
                <TableRow>
                  <TableCell colSpan={6}>
                    <div className="flex flex-col items-center gap-2 py-12 text-center text-muted-foreground">
                      <Building2 className="h-7 w-7" />
                      <p className="text-sm">Nenhum condomínio ainda.</p>
                      <Button variant="outline" size="sm" onClick={openNew}>
                        <Plus className="mr-1 h-4 w-4" /> Criar o primeiro
                      </Button>
                    </div>
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
                      <Badge variant={unit.active ? "default" : "secondary"}>
                        {unit.active ? "Ativo" : "Inativo"}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
        )}
      </Card>

      <CondominioFormDialog open={dialogOpen} onOpenChange={setDialogOpen} unit={editing} />
    </>
  );
}
