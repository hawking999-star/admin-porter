import { useMemo, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Plus, Search, Users, ShieldCheck } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
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
        description="Operadores que usam o app e pessoas com acesso ao admin."
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

  const openNew = () => {
    setEditing(null);
    setDialogOpen(true);
  };

  return (
    <>
      <div className="mb-4 flex items-center gap-2">
        <div className="relative w-full max-w-xs">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
          <Input
            placeholder="Buscar por nome, usuário ou condomínio..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="pl-8"
          />
        </div>
        <Button className="ml-auto" onClick={openNew}>
          <Plus className="mr-1 h-4 w-4" /> Novo operador
        </Button>
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
                <TableRow>
                  <TableCell colSpan={7}>
                    <div className="flex flex-col items-center gap-2 py-12 text-center text-muted-foreground">
                      <Users className="h-7 w-7" />
                      <p className="text-sm">Nenhum operador ainda.</p>
                      <Button variant="outline" size="sm" onClick={openNew}>
                        <Plus className="mr-1 h-4 w-4" /> Cadastrar o primeiro
                      </Button>
                    </div>
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
                      <Badge variant={op.has_login ? "default" : "secondary"}>
                        {op.has_login ? "Vinculado" : "Sem login"}
                      </Badge>
                    </TableCell>
                    <TableCell>
                      <Badge variant={op.active ? "default" : "secondary"}>
                        {op.active ? "Ativo" : "Inativo"}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
        )}
      </Card>

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
                <TableRow>
                  <TableCell colSpan={4}>
                    <div className="flex flex-col items-center gap-2 py-12 text-center text-muted-foreground">
                      <ShieldCheck className="h-7 w-7" />
                      <p className="text-sm">Nenhum acesso cadastrado.</p>
                    </div>
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
                      <Badge variant={a.active ? "default" : "secondary"}>
                        {a.active ? "Ativo" : "Inativo"}
                      </Badge>
                    </TableCell>
                  </TableRow>
                ))}
            </TableBody>
          </Table>
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
