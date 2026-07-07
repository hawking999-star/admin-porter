import type { ReactNode } from "react";
import { useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Search,
  RotateCw,
  ScrollText,
  AlertTriangle,
  XCircle,
  Music,
  Radio,
  Activity,
  Info,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Input } from "@/components/ui/input";
import { Card } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { StatCard, StatusBadge, EmptyState } from "@/components/shared";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import {
  fetchLogs,
  categoryLabel,
  fmtLogDate,
  fmtLogRelative,
  LOG_CATEGORIES,
  LOG_LEVELS,
  type LogEntry,
  type LogCategory,
  type LogLevel,
} from "./queries";

/* ------------------------------ Aparência -------------------------------- */

const LEVEL_META: Record<LogLevel, { label: string; tone: "neutral" | "warning" | "danger" }> = {
  info: { label: "Info", tone: "neutral" },
  warning: { label: "Aviso", tone: "warning" },
  error: { label: "Erro", tone: "danger" },
};

const CATEGORY_ICON: Record<LogCategory, ReactNode> = {
  sessao: <Radio className="h-3.5 w-3.5 text-secondary" />,
  status: <Activity className="h-3.5 w-3.5 text-primary" />,
  importacao: <Music className="h-3.5 w-3.5 text-primary" />,
  evento: <Info className="h-3.5 w-3.5 text-muted-foreground" />,
};

/* -------------------------------- Página --------------------------------- */

export function LogsPage() {
  const qc = useQueryClient();
  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["logs"],
    queryFn: fetchLogs,
    staleTime: 20_000,
  });

  const [search, setSearch] = useState("");
  const [category, setCategory] = useState<string>("all");
  const [level, setLevel] = useState<string>("all");

  const filtered = useMemo(() => {
    const term = search.trim().toLowerCase();
    return (data ?? []).filter((l) => {
      if (category !== "all" && l.category !== category) return false;
      if (level !== "all" && l.level !== level) return false;
      if (!term) return true;
      return (
        l.title.toLowerCase().includes(term) ||
        (l.detail ?? "").toLowerCase().includes(term) ||
        (l.actor ?? "").toLowerCase().includes(term)
      );
    });
  }, [data, search, category, level]);

  const stats = useMemo(() => {
    const all = data ?? [];
    return {
      total: all.length,
      errors: all.filter((l) => l.level === "error").length,
      warnings: all.filter((l) => l.level === "warning").length,
      imports: all.filter((l) => l.category === "importacao").length,
    };
  }, [data]);

  return (
    <>
      <PageHeader
        title="Logs"
        description="Eventos operacionais, mudanças de status e diagnóstico de importações."
        action={
          <Button variant="outline" size="sm" onClick={() => qc.invalidateQueries({ queryKey: ["logs"] })} disabled={isFetching}>
            <RotateCw className={cn("h-4 w-4", isFetching && "animate-spin")} />
            Atualizar
          </Button>
        }
      />

      {/* Estatísticas */}
      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<ScrollText className="h-5 w-5" />}
          label="Registros recentes"
          value={stats.total}
          iconClassName="bg-secondary/10 text-secondary"
          loading={isLoading}
        />
        <StatCard
          icon={<XCircle className="h-5 w-5" />}
          label="Erros"
          value={stats.errors}
          iconClassName="bg-destructive/10 text-destructive"
          loading={isLoading}
        />
        <StatCard
          icon={<AlertTriangle className="h-5 w-5" />}
          label="Avisos"
          value={stats.warnings}
          iconClassName="bg-warning/15 text-warning-foreground"
          loading={isLoading}
        />
        <StatCard
          icon={<Music className="h-5 w-5" />}
          label="Importações"
          value={stats.imports}
          iconClassName="bg-primary/10 text-primary"
          loading={isLoading}
        />
      </div>

      {/* Filtros */}
      <div className="mb-5 flex flex-wrap items-center gap-3">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por operador, descrição ou motivo..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>

        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger className="h-10 w-[190px] rounded-lg">
            <SelectValue placeholder="Categoria" />
          </SelectTrigger>
          <SelectContent>
            {LOG_CATEGORIES.map((c) => (
              <SelectItem key={c.value} value={c.value}>
                {c.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        <Select value={level} onValueChange={setLevel}>
          <SelectTrigger className="h-10 w-[170px] rounded-lg">
            <SelectValue placeholder="Nível" />
          </SelectTrigger>
          <SelectContent>
            {LOG_LEVELS.map((l) => (
              <SelectItem key={l.value} value={l.value}>
                {l.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        {data && (
          <span className="ml-auto text-sm text-muted-foreground">
            {filtered.length} de {data.length}
          </span>
        )}
      </div>

      {/* Tabela */}
      {isError ? (
        <Card className="p-6 text-sm text-destructive">
          Erro ao carregar os logs: {(error as Error)?.message}
        </Card>
      ) : (
        <Card className="overflow-hidden shadow-sm">
          <div className="overflow-x-auto">
          <Table className="min-w-[760px]">
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead className="w-[130px]">Quando</TableHead>
                <TableHead className="w-[140px]">Categoria</TableHead>
                <TableHead>Descrição</TableHead>
                <TableHead className="w-[110px]">Nível</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {isLoading &&
                Array.from({ length: 8 }).map((_, i) => (
                  <TableRow key={i}>
                    <TableCell colSpan={4}>
                      <Skeleton className="h-6 w-full" />
                    </TableCell>
                  </TableRow>
                ))}

              {!isLoading && filtered.length === 0 && (
                <TableRow className="hover:bg-transparent">
                  <TableCell colSpan={4}>
                    <EmptyState
                      icon={<ScrollText className="h-6 w-6" />}
                      title="Nenhum registro encontrado."
                      description="Ajuste os filtros ou aguarde novos eventos da operação."
                    />
                  </TableCell>
                </TableRow>
              )}

              {!isLoading && filtered.map((l: LogEntry) => (
                <TableRow key={l.id}>
                  <TableCell className="align-top text-muted-foreground" title={fmtLogDate(l.occurred_at)}>
                    <span className="text-sm">{fmtLogRelative(l.occurred_at)}</span>
                  </TableCell>
                  <TableCell className="align-top">
                    <span className="inline-flex items-center gap-1.5 text-sm">
                      {CATEGORY_ICON[l.category]}
                      {categoryLabel(l.category)}
                    </span>
                  </TableCell>
                  <TableCell className="align-top">
                    <div className="text-sm font-medium text-foreground">{l.title}</div>
                    {l.detail && <div className="mt-0.5 text-xs text-muted-foreground">{l.detail}</div>}
                  </TableCell>
                  <TableCell className="align-top">
                    <StatusBadge
                      tone={LEVEL_META[l.level].tone}
                      label={LEVEL_META[l.level].label}
                      dot={false}
                    />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          </div>
        </Card>
      )}
    </>
  );
}
