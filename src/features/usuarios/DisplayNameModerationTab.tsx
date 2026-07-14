import { useEffect, useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Pencil, Plus, ShieldAlert, X } from "lucide-react";
import { toast } from "sonner";
import { useAuth } from "@/features/auth/AuthProvider";
import { useDebounce } from "@/hooks/useDebounce";
import { errorMessage } from "@/lib/errors";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import {
  DataTable,
  EmptyState,
  ErrorState,
  FilterBar,
  PaginationFooter,
  RetryButton,
  SearchInput,
} from "@/components/shared";
import { DisplayNameReviewDialog } from "./DisplayNameReviewDialog";
import { DisplayNameTermDialog } from "./DisplayNameTermDialog";
import {
  listDisplayNameRequests,
  listDisplayNameTerms,
  listUnitOptions,
  reviewDisplayNameRequest,
  unitLabel,
  upsertDisplayNameTerm,
  type DisplayNameModerationTerm,
  type DisplayNameRequest,
  type DisplayNameResult,
  type DisplayNameTermInput,
} from "./queries";

const RESULT_LABELS: Record<DisplayNameResult, string> = {
  allowed: "Permitido",
  blocked: "Bloqueado",
  approved: "Aprovado",
  rejected: "Rejeitado",
  rate_limited: "Limitado",
};

const MATCH_TYPE_LABELS: Record<DisplayNameModerationTerm["match_type"], string> = {
  exact_name: "Nome exato",
  whole_word: "Palavra/frase",
  obfuscated: "Ofuscação",
};

function formatDateTime(value: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("pt-BR", { dateStyle: "short", timeStyle: "short" }).format(new Date(value));
}

function resultOf(request: DisplayNameRequest): DisplayNameResult {
  if (request.review_status === "approved") return "approved";
  if (request.review_status === "rejected") return "rejected";
  return request.moderation_result;
}

function resultClassName(result: DisplayNameResult) {
  if (result === "allowed" || result === "approved") return "border-success/40 bg-success/10 text-success-foreground";
  if (result === "blocked" || result === "rejected") return "border-destructive/30 bg-destructive/10 text-destructive";
  return "border-warning/40 bg-warning/10 text-warning-foreground";
}

function toStartIso(value: string) {
  return value ? new Date(`${value}T00:00:00`).toISOString() : undefined;
}

function toEndIso(value: string) {
  return value ? new Date(`${value}T23:59:59.999`).toISOString() : undefined;
}

export function DisplayNameModerationTab() {
  const { adminUser } = useAuth();
  const isSuperadmin = adminUser?.role === "superadmin";

  return (
    <Tabs defaultValue="history">
      <TabsList className="mb-4">
        <TabsTrigger value="history">Solicitações e histórico</TabsTrigger>
        {isSuperadmin && <TabsTrigger value="terms">Termos bloqueados</TabsTrigger>}
      </TabsList>
      <TabsContent value="history"><DisplayNameHistory /></TabsContent>
      {isSuperadmin && <TabsContent value="terms"><DisplayNameTerms /></TabsContent>}
    </Tabs>
  );
}

function DisplayNameHistory() {
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const [search, setSearch] = useState("");
  const [unitFilter, setUnitFilter] = useState("all");
  const [resultFilter, setResultFilter] = useState<"all" | DisplayNameResult>("all");
  const [startDate, setStartDate] = useState("");
  const [endDate, setEndDate] = useState("");
  const [reviewTarget, setReviewTarget] = useState<DisplayNameRequest | null>(null);
  const [reviewDecision, setReviewDecision] = useState<"approve" | "reject">("approve");
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => setPage(1), [debouncedSearch, unitFilter, resultFilter, startDate, endDate]);

  const unitsQuery = useQuery({ queryKey: ["unit-options"], queryFn: listUnitOptions, staleTime: 60_000 });
  const historyQuery = useQuery({
    queryKey: ["operator-display-name-requests", page, pageSize, debouncedSearch, unitFilter, resultFilter, startDate, endDate],
    queryFn: () => listDisplayNameRequests({
      page,
      pageSize,
      search: debouncedSearch,
      unitId: unitFilter,
      result: resultFilter,
      startAt: toStartIso(startDate),
      endAt: toEndIso(endDate),
    }),
    staleTime: 20_000,
    placeholderData: keepPreviousData,
  });

  const reviewMutation = useMutation({
    mutationFn: ({ requestId, decision, reason }: { requestId: string; decision: "approve" | "reject"; reason: string }) =>
      reviewDisplayNameRequest(requestId, decision, reason),
    onSuccess: (_data, variables) => {
      toast.success(variables.decision === "approve" ? "Nome aprovado e aplicado" : "Solicitação rejeitada");
      setReviewTarget(null);
      queryClient.invalidateQueries({ queryKey: ["operator-display-name-requests"] });
      queryClient.invalidateQueries({ queryKey: ["operators"] });
    },
    onError: (error: unknown) => toast.error("Não foi possível revisar", { description: errorMessage(error) }),
  });

  const rows = historyQuery.data?.rows ?? [];
  const total = historyQuery.data?.total ?? 0;
  const hasFilters = Boolean(debouncedSearch) || unitFilter !== "all" || resultFilter !== "all" || Boolean(startDate) || Boolean(endDate);
  const clearFilters = () => {
    setSearch("");
    setUnitFilter("all");
    setResultFilter("all");
    setStartDate("");
    setEndDate("");
  };

  const openReview = (request: DisplayNameRequest, decision: "approve" | "reject") => {
    setReviewTarget(request);
    setReviewDecision(decision);
  };

  return (
    <>
      <div className="mb-4 rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm text-muted-foreground">
        <p className="font-medium text-foreground">Trocas controladas pelo servidor</p>
        <p className="mt-1">O Operador pode alterar o nome de exibição uma vez a cada 15 dias. O nome cadastral permanece separado e os bloqueios podem ser revisados aqui.</p>
      </div>

      <FilterBar className="items-end">
        <SearchInput value={search} onChange={setSearch} placeholder="Operador ou nome solicitado..." />
        <Select value={unitFilter} onValueChange={setUnitFilter}>
          <SelectTrigger className="h-10 w-[230px] rounded-lg"><SelectValue placeholder="Condomínio" /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os condomínios</SelectItem>
            {(unitsQuery.data ?? []).map((unit) => <SelectItem key={unit.id} value={unit.id}>{unitLabel(unit)}</SelectItem>)}
          </SelectContent>
        </Select>
        <Select value={resultFilter} onValueChange={(value) => setResultFilter(value as "all" | DisplayNameResult)}>
          <SelectTrigger className="h-10 w-[170px] rounded-lg"><SelectValue placeholder="Resultado" /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os resultados</SelectItem>
            {Object.entries(RESULT_LABELS).map(([value, label]) => <SelectItem key={value} value={value}>{label}</SelectItem>)}
          </SelectContent>
        </Select>
        <div className="space-y-1">
          <label htmlFor="display-name-start" className="text-xs text-muted-foreground">De</label>
          <Input id="display-name-start" type="date" value={startDate} onChange={(event) => setStartDate(event.target.value)} className="h-10 w-[150px]" />
        </div>
        <div className="space-y-1">
          <label htmlFor="display-name-end" className="text-xs text-muted-foreground">Até</label>
          <Input id="display-name-end" type="date" value={endDate} onChange={(event) => setEndDate(event.target.value)} className="h-10 w-[150px]" />
        </div>
        {hasFilters && <Button variant="outline" onClick={clearFilters}>Limpar filtros</Button>}
        <span className="ml-auto text-sm text-muted-foreground">{rows.length} de {total}</span>
      </FilterBar>

      {historyQuery.isError ? (
        <Card><ErrorState title="Não foi possível carregar o histórico." description={errorMessage(historyQuery.error)} action={<RetryButton onClick={() => historyQuery.refetch()} />} /></Card>
      ) : (
        <DataTable minWidth={1040}>
          <TableHeader>
            <TableRow>
              <TableHead>Operador</TableHead>
              <TableHead>Alteração solicitada</TableHead>
              <TableHead>Resultado</TableHead>
              <TableHead>Origem</TableHead>
              <TableHead>Data</TableHead>
              <TableHead className="w-[170px] text-right">Revisão</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {historyQuery.isLoading && Array.from({ length: 4 }).map((_, index) => (
              <TableRow key={index}><TableCell colSpan={6}><div className="h-9 animate-pulse rounded bg-muted" /></TableCell></TableRow>
            ))}
            {!historyQuery.isLoading && rows.length === 0 && (
              <TableRow><TableCell colSpan={6}>
                <EmptyState icon={<ShieldAlert className="h-6 w-6" />} title="Nenhuma solicitação encontrada." description={hasFilters ? "Ajuste os filtros para ampliar a busca." : "As próximas trocas e tentativas bloqueadas aparecerão aqui."} />
              </TableCell></TableRow>
            )}
            {rows.map((request) => {
              const result = resultOf(request);
              return (
                <TableRow key={request.id}>
                  <TableCell>
                    <p className="font-medium">{request.operator_name}</p>
                    <p className="max-w-[260px] truncate text-xs text-muted-foreground">
                      {unitLabel({ name: request.unit_name, city: request.unit_city, state: request.unit_state, code: request.unit_code })}
                    </p>
                  </TableCell>
                  <TableCell>
                    <p className="text-sm"><span className="text-muted-foreground">{request.previous_name}</span> → <span className="font-medium">{request.requested_name}</span></p>
                    {request.moderation_reason && <p className="mt-1 max-w-[340px] truncate text-xs text-muted-foreground" title={request.moderation_reason}>{request.moderation_reason}</p>}
                  </TableCell>
                  <TableCell><Badge variant="outline" className={resultClassName(result)}>{RESULT_LABELS[result]}</Badge></TableCell>
                  <TableCell className="text-muted-foreground">{request.source === "operator_app" ? "App do Operador" : request.source === "admin_approval" ? "Aprovação do Admin" : request.source === "admin_panel" ? "Painel" : "Sistema"}</TableCell>
                  <TableCell className="whitespace-nowrap text-muted-foreground">{formatDateTime(request.occurred_at)}</TableCell>
                  <TableCell className="text-right">
                    {request.moderation_result === "blocked" && request.review_status === "pending" ? (
                      <div className="flex justify-end gap-1">
                        <Button size="sm" variant="outline" onClick={() => openReview(request, "reject")}><X className="h-4 w-4" /> Rejeitar</Button>
                        <Button size="sm" onClick={() => openReview(request, "approve")}><Check className="h-4 w-4" /> Aprovar</Button>
                      </div>
                    ) : (
                      <span className="text-xs text-muted-foreground">{request.reviewed_by ? `Por ${request.reviewed_by}` : "—"}</span>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </DataTable>
      )}

      {!historyQuery.isError && <PaginationFooter page={page} pageSize={pageSize} total={total} isLoading={historyQuery.isLoading || historyQuery.isFetching} onPageChange={setPage} onPageSizeChange={(value) => { setPageSize(value); setPage(1); }} />}

      <DisplayNameReviewDialog
        open={Boolean(reviewTarget)}
        onOpenChange={(open) => !open && setReviewTarget(null)}
        request={reviewTarget}
        decision={reviewDecision}
        isPending={reviewMutation.isPending}
        onConfirm={(reason) => reviewTarget && reviewMutation.mutate({ requestId: reviewTarget.id, decision: reviewDecision, reason })}
      />
    </>
  );
}

function DisplayNameTerms() {
  const queryClient = useQueryClient();
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const [search, setSearch] = useState("");
  const [activeFilter, setActiveFilter] = useState<"all" | "active" | "inactive">("all");
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<DisplayNameModerationTerm | null>(null);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => setPage(1), [debouncedSearch, activeFilter]);

  const termsQuery = useQuery({
    queryKey: ["operator-display-name-terms", page, pageSize, debouncedSearch, activeFilter],
    queryFn: () => listDisplayNameTerms({ page, pageSize, search: debouncedSearch, active: activeFilter }),
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  });

  const mutation = useMutation({
    mutationFn: upsertDisplayNameTerm,
    onSuccess: () => {
      toast.success("Termo de moderação salvo");
      setDialogOpen(false);
      setEditing(null);
      queryClient.invalidateQueries({ queryKey: ["operator-display-name-terms"] });
    },
    onError: (error: unknown) => toast.error("Não foi possível salvar", { description: errorMessage(error) }),
  });

  const rows = termsQuery.data?.rows ?? [];
  const total = termsQuery.data?.total ?? 0;
  const editTerm = (term: DisplayNameModerationTerm) => { setEditing(term); setDialogOpen(true); };
  const openNew = () => { setEditing(null); setDialogOpen(true); };
  const toggleTerm = (term: DisplayNameModerationTerm) => mutation.mutate({ id: term.id, term: term.term, match_type: term.match_type, reason: term.reason, active: !term.active });

  return (
    <>
      <div className="mb-4 rounded-xl border border-warning/30 bg-warning/5 p-4 text-sm text-muted-foreground">
        <p className="font-medium text-foreground">Lista global do servidor</p>
        <p className="mt-1">Nenhum termo é enviado ao App. Use o modo de ofuscação somente quando necessário, pois ele faz uma comparação mais agressiva.</p>
      </div>

      <FilterBar>
        <SearchInput value={search} onChange={setSearch} placeholder="Buscar termo ou motivo..." />
        <Select value={activeFilter} onValueChange={(value) => setActiveFilter(value as "all" | "active" | "inactive")}>
          <SelectTrigger className="h-10 w-[160px] rounded-lg"><SelectValue /></SelectTrigger>
          <SelectContent><SelectItem value="all">Todos</SelectItem><SelectItem value="active">Ativos</SelectItem><SelectItem value="inactive">Inativos</SelectItem></SelectContent>
        </Select>
        <div className="ml-auto flex items-center gap-3">
          <span className="text-sm text-muted-foreground">{rows.length} de {total}</span>
          <Button onClick={openNew}><Plus className="h-4 w-4" /> Novo termo</Button>
        </div>
      </FilterBar>

      {termsQuery.isError ? (
        <Card><ErrorState title="Não foi possível carregar os termos." description={errorMessage(termsQuery.error)} action={<RetryButton onClick={() => termsQuery.refetch()} />} /></Card>
      ) : (
        <DataTable minWidth={780}>
          <TableHeader><TableRow><TableHead>Termo</TableHead><TableHead>Detecção</TableHead><TableHead>Motivo</TableHead><TableHead>Status</TableHead><TableHead>Atualizado</TableHead><TableHead className="w-[180px] text-right">Ações</TableHead></TableRow></TableHeader>
          <TableBody>
            {termsQuery.isLoading && Array.from({ length: 3 }).map((_, index) => <TableRow key={index}><TableCell colSpan={6}><div className="h-9 animate-pulse rounded bg-muted" /></TableCell></TableRow>)}
            {!termsQuery.isLoading && rows.length === 0 && <TableRow><TableCell colSpan={6}><EmptyState icon={<ShieldAlert className="h-6 w-6" />} title="Nenhum termo cadastrado." description="Cadastre somente os termos que devem ser avaliados pelo servidor." action={<Button variant="outline" size="sm" onClick={openNew}><Plus className="h-4 w-4" /> Novo termo</Button>} /></TableCell></TableRow>}
            {rows.map((term) => (
              <TableRow key={term.id}>
                <TableCell className="font-medium">{term.term}</TableCell>
                <TableCell>{MATCH_TYPE_LABELS[term.match_type]}</TableCell>
                <TableCell className="max-w-[360px] truncate text-muted-foreground" title={term.reason}>{term.reason}</TableCell>
                <TableCell><Badge variant="outline" className={term.active ? "border-success/40 bg-success/10 text-success-foreground" : "text-muted-foreground"}>{term.active ? "Ativo" : "Inativo"}</Badge></TableCell>
                <TableCell className="whitespace-nowrap text-muted-foreground">{formatDateTime(term.updated_at)}</TableCell>
                <TableCell className="text-right"><div className="flex justify-end gap-1"><Button variant="ghost" size="sm" onClick={() => editTerm(term)}><Pencil className="h-4 w-4" /> Editar</Button><Button variant="outline" size="sm" onClick={() => toggleTerm(term)} disabled={mutation.isPending}>{term.active ? "Desativar" : "Ativar"}</Button></div></TableCell>
              </TableRow>
            ))}
          </TableBody>
        </DataTable>
      )}

      {!termsQuery.isError && <PaginationFooter page={page} pageSize={pageSize} total={total} isLoading={termsQuery.isLoading || termsQuery.isFetching} onPageChange={setPage} onPageSizeChange={(value) => { setPageSize(value); setPage(1); }} />}

      <DisplayNameTermDialog open={dialogOpen} onOpenChange={(open) => { setDialogOpen(open); if (!open) setEditing(null); }} term={editing} isPending={mutation.isPending} onSubmit={(input: DisplayNameTermInput) => mutation.mutate(input)} />
    </>
  );
}
