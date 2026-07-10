import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
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
import { StatCard, StatusBadge, EmptyState, ErrorState, RetryButton, PaginationFooter } from "@/components/shared";
import { useDebounce } from "@/hooks/useDebounce";
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

export function LogsPage() {
  const qc = useQueryClient();
  const [search, setSearch] = useState("");
  const [actor, setActor] = useState("");
  const [category, setCategory] = useState<LogCategory | "all">("all");
  const [level, setLevel] = useState<LogLevel | "all">("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const debouncedSearch = useDebounce(search, 350);
  const debouncedActor = useDebounce(actor, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, debouncedActor, category, level, dateFrom, dateTo]);

  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["logs", page, pageSize, debouncedSearch, debouncedActor, category, level, dateFrom, dateTo],
    queryFn: () =>
      fetchLogs({
        page,
        pageSize,
        search: debouncedSearch,
        actor: debouncedActor,
        category,
        level,
        dateFrom,
        dateTo,
      }),
    staleTime: 20_000,
    placeholderData: keepPreviousData,
  });

  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const hasFilters =
    Boolean(debouncedSearch.trim()) ||
    Boolean(debouncedActor.trim()) ||
    category !== "all" ||
    level !== "all" ||
    Boolean(dateFrom) ||
    Boolean(dateTo);

  const stats = useMemo(
    () => ({
      total: rows.length,
      errors: rows.filter((l) => l.level === "error").length,
      warnings: rows.filter((l) => l.level === "warning").length,
      imports: rows.filter((l) => l.category === "importacao").length,
    }),
    [rows],
  );

  const clearFilters = () => {
    setSearch("");
    setActor("");
    setCategory("all");
    setLevel("all");
    setDateFrom("");
    setDateTo("");
  };

  const invalidate = () => qc.invalidateQueries({ queryKey: ["logs"] });

  return (
    <>
      <PageHeader
        title="Logs"
        description="Eventos operacionais, mudancas de status e diagnostico de importacoes."
        action={
          <Button variant="outline" size="sm" onClick={invalidate} disabled={isFetching}>
            <RotateCw className={cn("h-4 w-4", isFetching && "animate-spin")} />
            Atualizar
          </Button>
        }
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<ScrollText className="h-5 w-5" />}
          label="Registros nesta pagina"
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
          label="Importacoes"
          value={stats.imports}
          iconClassName="bg-primary/10 text-primary"
          loading={isLoading}
        />
      </div>

      <div className="sticky top-3 z-20 mb-4 flex flex-wrap items-center gap-2.5 rounded-xl border border-border/80 bg-card/95 p-3 shadow-sm backdrop-blur-sm">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar por descricao, motivo ou evento..."
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>

        <div className="relative w-full max-w-xs">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Operador ou usuario..."
            value={actor}
            onChange={(e) => setActor(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>

        <Select value={category} onValueChange={(value) => setCategory(value as LogCategory | "all")}>
          <SelectTrigger className="h-10 w-[190px] rounded-lg">
            <SelectValue placeholder="Tipo/evento" />
          </SelectTrigger>
          <SelectContent>
            {LOG_CATEGORIES.map((c) => (
              <SelectItem key={c.value} value={c.value}>
                {c.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        <Select value={level} onValueChange={(value) => setLevel(value as LogLevel | "all")}>
          <SelectTrigger className="h-10 w-[170px] rounded-lg">
            <SelectValue placeholder="Severidade" />
          </SelectTrigger>
          <SelectContent>
            {LOG_LEVELS.map((l) => (
              <SelectItem key={l.value} value={l.value}>
                {l.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>

        <Input
          type="date"
          value={dateFrom}
          onChange={(e) => setDateFrom(e.target.value)}
          className="h-10 w-[150px] rounded-lg"
          aria-label="Data inicial"
        />
        <Input
          type="date"
          value={dateTo}
          onChange={(e) => setDateTo(e.target.value)}
          className="h-10 w-[150px] rounded-lg"
          aria-label="Data final"
        />

        {hasFilters && (
          <Button variant="outline" onClick={clearFilters}>
            Limpar filtros
          </Button>
        )}

        {data && <span className="ml-auto text-sm text-muted-foreground">{rows.length} de {total}</span>}
      </div>

      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Nao foi possivel carregar os logs."
            description={(error as Error)?.message}
            action={<RetryButton onClick={invalidate} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <Card className="overflow-hidden shadow-sm">
          <div className="max-h-[620px] overflow-auto">
            <Table className="min-w-[760px]">
              <TableHeader className="sticky top-0 z-10 bg-card">
                <TableRow className="hover:bg-transparent">
                  <TableHead className="w-[130px]">Quando</TableHead>
                  <TableHead className="w-[140px]">Categoria</TableHead>
                  <TableHead>Descricao</TableHead>
                  <TableHead className="w-[110px]">Nivel</TableHead>
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

                {!isLoading && rows.length === 0 && (
                  <TableRow className="hover:bg-transparent">
                    <TableCell colSpan={4}>
                      <EmptyState
                        icon={<ScrollText className="h-6 w-6" />}
                        title="Nenhum registro encontrado."
                        description={
                          hasFilters
                            ? "Ajuste ou limpe os filtros para ampliar a busca."
                            : "Aguarde novos eventos da operacao."
                        }
                        action={
                          hasFilters ? (
                            <Button variant="outline" size="sm" onClick={clearFilters}>
                              Limpar filtros
                            </Button>
                          ) : undefined
                        }
                      />
                    </TableCell>
                  </TableRow>
                )}

                {!isLoading &&
                  rows.map((l: LogEntry) => (
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
                        <StatusBadge tone={LEVEL_META[l.level].tone} label={LEVEL_META[l.level].label} dot={false} />
                      </TableCell>
                    </TableRow>
                  ))}
              </TableBody>
            </Table>
          </div>
        </Card>
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
    </>
  );
}
