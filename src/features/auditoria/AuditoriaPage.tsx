import { useEffect, useState } from "react";
import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query";
import { ClipboardList, Download, Eye, RefreshCw, Search } from "lucide-react";
import { toast } from "sonner";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState, ErrorState, PaginationFooter, RetryButton, StatusBadge } from "@/components/shared";
import { useDebounce } from "@/hooks/useDebounce";
import { errorMessage } from "@/lib/errors";
import {
  actionLabel,
  entityTypeLabel,
  exportAuditLogs,
  formatAuditDate,
  listAuditFilterOptions,
  listAuditLogs,
  type AuditFilters,
  type AuditLogRow,
} from "./queries";

function csvCell(value: unknown): string {
  const text = value == null ? "" : typeof value === "string" ? value : JSON.stringify(value);
  return `"${text.replace(/"/g, '""')}"`;
}

function downloadAuditCsv(rows: AuditLogRow[]) {
  const header = ["data", "autor", "acao", "area", "entidade_id", "motivo", "antes", "depois"];
  const lines = rows.map((row) => [
    row.occurred_at,
    row.admin_name ?? "Sistema",
    actionLabel(row.action),
    entityTypeLabel(row.entity_type),
    row.entity_id,
    row.reason,
    row.before_data,
    row.after_data,
  ].map(csvCell).join(","));
  const blob = new Blob([String.fromCharCode(0xfeff) + [header.map(csvCell).join(","), ...lines].join("\r\n")], {
    type: "text/csv;charset=utf-8;",
  });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = `auditoria-${new Date().toISOString().slice(0, 10)}.csv`;
  link.click();
  URL.revokeObjectURL(url);
}

function actionTone(action: string): "success" | "warning" | "danger" | "info" | "neutral" {
  if (/(approved|created|released|granted)/.test(action)) return "success";
  if (/(blocked|rejected|deleted)/.test(action)) return "danger";
  if (/(rollback|reset|requeued)/.test(action)) return "warning";
  if (/(updated|edited|changed|update)/.test(action)) return "info";
  return "neutral";
}

function JsonPanel({ title, value }: { title: string; value: unknown }) {
  if (value == null) return null;
  return (
    <div className="space-y-1.5">
      <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{title}</p>
      <pre className="max-h-56 overflow-auto rounded-lg border border-border bg-muted/40 p-3 text-xs leading-relaxed">
        {JSON.stringify(value, null, 2)}
      </pre>
    </div>
  );
}

export function AuditoriaPage() {
  const queryClient = useQueryClient();
  const [search, setSearch] = useState("");
  const [action, setAction] = useState("all");
  const [entityType, setEntityType] = useState("all");
  const [adminId, setAdminId] = useState("all");
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const [detail, setDetail] = useState<AuditLogRow | null>(null);
  const [exporting, setExporting] = useState(false);
  const debouncedSearch = useDebounce(search, 300);

  useEffect(() => setPage(1), [debouncedSearch, action, entityType, adminId, dateFrom, dateTo]);

  const filters: AuditFilters = { page, pageSize, search: debouncedSearch, action, entityType, adminId, dateFrom, dateTo };
  const list = useQuery({
    queryKey: ["audit-logs", filters],
    queryFn: () => listAuditLogs(filters),
    placeholderData: keepPreviousData,
    staleTime: 20_000,
  });
  const options = useQuery({ queryKey: ["audit-log-options"], queryFn: listAuditFilterOptions, staleTime: 60_000 });
  const rows = list.data?.rows ?? [];
  const total = list.data?.total ?? 0;
  const hasFilters = Boolean(debouncedSearch || dateFrom || dateTo || action !== "all" || entityType !== "all" || adminId !== "all");

  const clearFilters = () => {
    setSearch("");
    setAction("all");
    setEntityType("all");
    setAdminId("all");
    setDateFrom("");
    setDateTo("");
  };

  const exportCsv = async () => {
    setExporting(true);
    try {
      const exportRows = await exportAuditLogs(filters);
      downloadAuditCsv(exportRows);
      toast.success(`${exportRows.length} registro(s) exportado(s).`);
    } catch (error) {
      toast.error(errorMessage(error, "Não foi possível exportar a auditoria."));
    } finally {
      setExporting(false);
    }
  };

  return (
    <>
      <PageHeader
        eyebrow="Gestão e sistema"
        title="Auditoria"
        description="Registro real das ações administrativas, com autor, data, área e alterações realizadas."
        action={
          <div className="flex gap-2">
            <Button variant="outline" size="sm" onClick={() => queryClient.invalidateQueries({ queryKey: ["audit-logs"] })} disabled={list.isFetching}>
              <RefreshCw className={list.isFetching ? "h-4 w-4 animate-spin" : "h-4 w-4"} /> Atualizar
            </Button>
            <Button size="sm" onClick={exportCsv} disabled={exporting || !total}>
              <Download className="h-4 w-4" /> {exporting ? "Exportando..." : "Exportar CSV"}
            </Button>
          </div>
        }
      />

      <Card className="mb-5 p-4 shadow-sm">
        <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-6">
          <div className="relative md:col-span-2">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Buscar ação, área ou motivo" className="pl-9" />
          </div>
          <Select value={entityType} onValueChange={setEntityType}>
            <SelectTrigger><SelectValue placeholder="Área" /></SelectTrigger>
            <SelectContent><SelectItem value="all">Todas as áreas</SelectItem>{(options.data?.entityTypes ?? []).map((value) => <SelectItem key={value} value={value}>{entityTypeLabel(value)}</SelectItem>)}</SelectContent>
          </Select>
          <Select value={action} onValueChange={setAction}>
            <SelectTrigger><SelectValue placeholder="Ação" /></SelectTrigger>
            <SelectContent><SelectItem value="all">Todas as ações</SelectItem>{(options.data?.actions ?? []).map((value) => <SelectItem key={value} value={value}>{actionLabel(value)}</SelectItem>)}</SelectContent>
          </Select>
          <Select value={adminId} onValueChange={setAdminId}>
            <SelectTrigger><SelectValue placeholder="Autor" /></SelectTrigger>
            <SelectContent><SelectItem value="all">Todos os autores</SelectItem>{(options.data?.admins ?? []).map((admin) => <SelectItem key={admin.id} value={admin.id}>{admin.name}</SelectItem>)}</SelectContent>
          </Select>
          <div className="flex gap-2">
            <Input type="date" value={dateFrom} onChange={(event) => setDateFrom(event.target.value)} aria-label="Data inicial" />
            <Input type="date" value={dateTo} onChange={(event) => setDateTo(event.target.value)} aria-label="Data final" />
          </div>
        </div>
        <div className="mt-3 flex items-center justify-between gap-3 text-sm text-muted-foreground">
          <span>{list.isLoading ? "Carregando..." : `${total} registro(s)`}</span>
          {hasFilters && <Button variant="ghost" size="sm" onClick={clearFilters}>Limpar filtros</Button>}
        </div>
      </Card>

      {list.isError ? (
        <Card><ErrorState title="Não foi possível carregar a Auditoria." description={(list.error as Error).message} action={<RetryButton onClick={() => list.refetch()} />} /></Card>
      ) : (
        <Card className="overflow-hidden shadow-sm">
          <div className="max-h-[620px] overflow-auto">
            <Table className="min-w-[860px]">
              <TableHeader className="sticky top-0 z-10 bg-card">
                <TableRow>
                  <TableHead className="w-[160px]">Data</TableHead>
                  <TableHead>Ação</TableHead>
                  <TableHead className="w-[170px]">Área</TableHead>
                  <TableHead className="w-[180px]">Autor</TableHead>
                  <TableHead className="w-[90px]"><span className="sr-only">Detalhes</span></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {list.isLoading && Array.from({ length: 8 }).map((_, index) => <TableRow key={index}><TableCell colSpan={5}><Skeleton className="h-6 w-full" /></TableCell></TableRow>)}
                {!list.isLoading && rows.length === 0 && <TableRow><TableCell colSpan={5}><EmptyState icon={<ClipboardList className="h-6 w-6" />} title="Nenhuma ação encontrada." description={hasFilters ? "Ajuste os filtros para ampliar a busca." : "As próximas ações administrativas aparecerão aqui."} /></TableCell></TableRow>}
                {!list.isLoading && rows.map((row) => (
                  <TableRow key={row.id}>
                    <TableCell className="text-sm text-muted-foreground">{formatAuditDate(row.occurred_at)}</TableCell>
                    <TableCell><StatusBadge label={actionLabel(row.action)} tone={actionTone(row.action)} dot={false} /></TableCell>
                    <TableCell className="text-sm">{entityTypeLabel(row.entity_type)}</TableCell>
                    <TableCell className="text-sm">{row.admin_name ?? "Sistema"}</TableCell>
                    <TableCell><Button variant="ghost" size="sm" onClick={() => setDetail(row)}><Eye className="h-4 w-4" /> Ver</Button></TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </Card>
      )}

      {!list.isError && <PaginationFooter page={page} pageSize={pageSize} total={total} isLoading={list.isFetching} onPageChange={setPage} onPageSizeChange={(value) => { setPageSize(value); setPage(1); }} />}

      <Dialog open={Boolean(detail)} onOpenChange={(open) => !open && setDetail(null)}>
        <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
          <DialogHeader>
            <DialogTitle>{detail ? actionLabel(detail.action) : "Detalhes da ação"}</DialogTitle>
            <DialogDescription>{detail ? `${formatAuditDate(detail.occurred_at)} · ${detail.admin_name ?? "Sistema"} · ${entityTypeLabel(detail.entity_type)}` : ""}</DialogDescription>
          </DialogHeader>
          {detail && (
            <div className="space-y-4">
              {detail.reason && <div className="rounded-lg border border-border bg-muted/30 p-3 text-sm"><strong>Motivo:</strong> {detail.reason}</div>}
              <JsonPanel title="Antes" value={detail.before_data} />
              <JsonPanel title="Depois" value={detail.after_data} />
              <div className="grid gap-2 text-xs text-muted-foreground sm:grid-cols-2">
                {detail.entity_id && <span>Entidade: {detail.entity_id}</span>}
                {detail.request_id && <span>Requisição: {detail.request_id}</span>}
              </div>
            </div>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}
