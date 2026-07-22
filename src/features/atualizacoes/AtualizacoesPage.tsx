import type { ReactNode } from "react";
import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  AlertTriangle,
  Ban,
  Check,
  CheckCircle2,
  Clock,
  Eye,
  FileText,
  History,
  Loader2,
  Megaphone,
  Pencil,
  Plus,
  Rocket,
  RotateCcw,
  Search,
  ShieldAlert,
  Upload,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { errorMessage, isNonEditableReleaseError } from "@/lib/errors";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Switch } from "@/components/ui/switch";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { EmptyState, ExportCsvButton, StatCard, ErrorState, RetryButton, PaginationFooter, StatusBadge } from "@/components/shared";
import type { CsvColumn } from "@/lib/csv";
import { useDebounce } from "@/hooks/useDebounce";
import { useUrlFilterState } from "@/hooks/useUrlFilterState";
import {
  approveAppRelease,
  blockAppRelease,
  countActiveNotices,
  countAppReleaseStats,
  createAppRelease,
  getAppReleaseById,
  getCurrentAppRelease,
  listAppReleases,
  listAppNotices,
  listNoticeOperators,
  listNoticeAcknowledgements,
  listNoticeUnits,
  listReleaseHistory,
  listReleaseNotes,
  listReleaseOptions,
  noticeFormErrors,
  noticeStatusLabel,
  parseLatestYml,
  releaseAppRelease,
  releaseContractErrors,
  releaseFormErrors,
  releaseNoteFormErrors,
  releaseRequiredFieldsReady,
  rollbackAppRelease,
  sendAppReleaseToTesting,
  statusLabel,
  updateAppRelease,
  updateAppNoticeStatus,
  upsertAppNotice,
  upsertAppReleaseNote,
  NOTICE_SEVERITIES,
  NOTICE_STATUSES,
  RELEASE_STATUSES,
  type AppNotice,
  type AppNoticeInput,
  type AppRelease,
  type AppReleaseInput,
  type AppReleaseNote,
  type AppReleaseNoteInput,
  type NoticeSeverity,
  type NoticeStatus,
  type NoticeAcknowledgement,
  type ReleaseStatus,
} from "./queries";

const EMPTY_INPUT: AppReleaseInput = {
  version: "",
  title: "",
  release_notes: "",
  channel: "stable",
  status: "draft",
  mandatory: true,
  minimum_version: "",
  manifest_key: "",
  installer_key: "",
  blockmap_key: "",
  sha512: "",
  size_bytes: "",
};

const RELEASE_EXPORT_COLUMNS: CsvColumn<AppRelease>[] = [
  { header: "versao", value: (row) => row.version },
  { header: "titulo", value: (row) => row.title },
  { header: "canal", value: (row) => row.channel },
  { header: "status", value: (row) => row.status },
  { header: "obrigatoria", value: (row) => row.mandatory ? "sim" : "nao" },
  { header: "criada_em", value: (row) => row.created_at },
  { header: "publicada_em", value: (row) => row.released_at },
];

const NOTICE_EXPORT_COLUMNS: CsvColumn<AppNotice>[] = [
  { header: "titulo", value: (row) => row.title },
  { header: "mensagem", value: (row) => row.message },
  { header: "severidade", value: (row) => row.severity },
  { header: "status", value: (row) => row.status },
  { header: "publico", value: (row) => row.audience_type },
  { header: "leituras", value: (row) => row.read_count },
  { header: "confirmacoes", value: (row) => row.ack_count },
  { header: "atualizado_em", value: (row) => row.updated_at },
];

const EMPTY_NOTICE_INPUT: AppNoticeInput = {
  title: "",
  message: "",
  severity: "info",
  status: "draft",
  starts_at: "",
  ends_at: "",
  audience_type: "all",
  condominium_id: "",
  operator_id: "",
  shift: "",
  requires_ack: false,
};

type Tone = "success" | "warning" | "danger" | "info" | "neutral";

const RELEASE_STATUS_META: Record<ReleaseStatus, { label: string; tone: Tone }> = {
  draft: { label: "Rascunho", tone: "neutral" },
  testing: { label: "Teste", tone: "info" },
  approved: { label: "Aprovada", tone: "info" },
  released: { label: "Liberada", tone: "success" },
  blocked: { label: "Bloqueada", tone: "danger" },
  superseded: { label: "Substituída", tone: "neutral" },
};

const NOTICE_SEVERITY_META: Record<NoticeSeverity, { label: string; tone: Tone }> = {
  info: { label: "Informativo", tone: "info" },
  warning: { label: "Atenção", tone: "warning" },
  critical: { label: "Crítico", tone: "danger" },
  success: { label: "Sucesso", tone: "success" },
};

function noticeStatusTone(label: string): Tone {
  if (label === "Ativo") return "success";
  if (label === "Agendado") return "info";
  if (label === "Desativado") return "danger";
  return "neutral";
}

/** Badge de status de release — mostra "Produção" quando é a versão atual liberada. */
function ReleaseStatusBadge({ release }: { release: AppRelease }) {
  if (release.is_current && release.status === "released") {
    return <StatusBadge tone="success" label="Produção" />;
  }
  const meta = RELEASE_STATUS_META[release.status];
  return <StatusBadge tone={meta.tone} label={meta.label} />;
}

function fmtDate(iso: string | null) {
  if (!iso) return "-";
  return new Date(iso).toLocaleString("pt-BR", {
    day: "2-digit",
    month: "2-digit",
    year: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function fmtBytes(value: number | null) {
  if (!value) return "-";
  const mb = value / 1024 / 1024;
  return `${mb.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} MB`;
}

function toDateTimeInput(iso: string | null) {
  if (!iso) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  const offset = date.getTimezoneOffset();
  const local = new Date(date.getTime() - offset * 60_000);
  return local.toISOString().slice(0, 16);
}

function splitNoteContent(content: string | null | undefined) {
  const text = content ?? "";
  const pick = (label: string, next?: string) => {
    const end = next ? `\\n\\s*(?:${next})\\s*\\n` : "$";
    const match = text.match(new RegExp(`(?:${label})\\s*\\n([\\s\\S]*?)(?:${end})`, "i"));
    return match?.[1]?.trim() ?? "";
  };
  const novidades = pick("Novidades", "Correções|Correcoes");
  const correcoes = pick("Correções|Correcoes", "Observações|Observacoes");
  const observacoes = pick("Observações|Observacoes");
  if (!novidades && !correcoes && !observacoes) return { novidades: text.trim(), correcoes: "", observacoes: "" };
  return { novidades, correcoes, observacoes };
}

function buildNoteContent(novidades: string, correcoes: string, observacoes: string) {
  return [
    ["Novidades", novidades.trim()],
    ["Correções", correcoes.trim()],
    ["Observações", observacoes.trim()],
  ]
    .filter(([, value]) => value)
    .map(([label, value]) => `${label}\n${value}`)
    .join("\n\n");
}

function shiftLabel(value: string | null) {
  if (value === "day") return "Diurno";
  if (value === "night") return "Noturno";
  if (value === "other") return "Outro";
  return "-";
}

function audienceLabel(notice: AppNotice) {
  if (notice.audience_type === "all") return "Todos";
  if (notice.audience_type === "condominium") return notice.condominium_name ?? "Condomínio";
  if (notice.audience_type === "user") return notice.operator_name ?? "Operador";
  return `Turno ${shiftLabel(notice.shift)}`;
}

/** Último evento do ciclo de vida da release, para a coluna "Última ação". */
function lastAction(r: AppRelease): { label: string; at: string | null; by: string | null } {
  if (r.status === "blocked" && r.blocked_at) return { label: "Bloqueada", at: r.blocked_at, by: r.blocked_by_name };
  if (r.released_at) return { label: "Liberada", at: r.released_at, by: r.released_by_name };
  if (r.approved_at) return { label: "Aprovada", at: r.approved_at, by: r.approved_by_name };
  return { label: "Criada", at: r.created_at, by: r.created_by_name };
}

function toInput(release: AppRelease): AppReleaseInput {
  return {
    version: release.version,
    title: release.title ?? "",
    release_notes: release.release_notes ?? "",
    channel: release.channel,
    status: release.status === "testing" ? "testing" : "draft",
    mandatory: release.mandatory,
    minimum_version: release.minimum_version ?? "",
    manifest_key: release.manifest_key ?? "",
    installer_key: release.installer_key ?? "",
    blockmap_key: release.blockmap_key ?? "",
    sha512: release.sha512 ?? "",
    size_bytes: release.size_bytes ? String(release.size_bytes) : "",
  };
}

export function AtualizacoesPage() {
  const qc = useQueryClient();
  const [tab, setTab] = useUrlFilterState("tab", "versoes");
  const [search, setSearch] = useUrlFilterState("q", "");
  const [status, setStatus] = useUrlFilterState<ReleaseStatus | "all">("status", "all");
  const [page, setPage] = useState(1);
  const [pageSize, setPageSize] = useState(25);
  const [noticeSearch, setNoticeSearch] = useState("");
  const [noticeStatus, setNoticeStatus] = useState<NoticeStatus | "all">("all");
  const [noticeSeverity, setNoticeSeverity] = useState<NoticeSeverity | "all">("all");
  const [noticePage, setNoticePage] = useState(1);
  const [noticePageSize, setNoticePageSize] = useState(10);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState<AppRelease | null>(null);
  const [noteDialogRelease, setNoteDialogRelease] = useState<AppRelease | null>(null);
  const [pendingNoteId, setPendingNoteId] = useState<string | null>(null);
  const [versionPickerOpen, setVersionPickerOpen] = useState(false);
  const [noticeDialog, setNoticeDialog] = useState<AppNotice | null | "new">(null);
  const [noticeReadsTarget, setNoticeReadsTarget] = useState<AppNotice | null>(null);
  const [confirm, setConfirm] = useState<null | {
    release: AppRelease;
    action: "approve" | "release" | "block" | "rollback";
  }>(null);
  const [blockReason, setBlockReason] = useState("");
  const debouncedSearch = useDebounce(search, 350);
  const debouncedNoticeSearch = useDebounce(noticeSearch, 350);
  const noticeDialogOpen = Boolean(noticeDialog);

  const { data, isLoading, isError, error, isFetching } = useQuery({
    queryKey: ["app-releases", page, pageSize, debouncedSearch, status],
    queryFn: () => listAppReleases({ page, pageSize, search: debouncedSearch, status }),
    staleTime: 20_000,
    placeholderData: keepPreviousData,
  });
  const statsQuery = useQuery({
    queryKey: ["app-release-stats"],
    queryFn: countAppReleaseStats,
    staleTime: 30_000,
  });
  const activeNoticesQuery = useQuery({
    queryKey: ["app-notices-active-count"],
    queryFn: countActiveNotices,
    staleTime: 30_000,
  });
  const currentQuery = useQuery({
    queryKey: ["app-release-current"],
    queryFn: getCurrentAppRelease,
    staleTime: 30_000,
  });
  const releaseNotesQuery = useQuery({
    queryKey: ["release-notes-list"],
    queryFn: listReleaseNotes,
    staleTime: 30_000,
  });
  const historyQuery = useQuery({
    queryKey: ["app-release-history"],
    queryFn: listReleaseHistory,
    staleTime: 30_000,
  });
  const releaseOptionsQuery = useQuery({
    queryKey: ["release-options"],
    queryFn: listReleaseOptions,
    staleTime: 30_000,
    enabled: versionPickerOpen,
  });
  const noticesQuery = useQuery({
    queryKey: ["app-notices", noticePage, noticePageSize, debouncedNoticeSearch, noticeStatus, noticeSeverity],
    queryFn: () => listAppNotices({
      page: noticePage,
      pageSize: noticePageSize,
      search: debouncedNoticeSearch,
      status: noticeStatus,
      severity: noticeSeverity,
    }),
    staleTime: 20_000,
    placeholderData: keepPreviousData,
    enabled: tab === "avisos",
  });
  const noticeUnitsQuery = useQuery({
    queryKey: ["notice-units"],
    queryFn: listNoticeUnits,
    staleTime: 60_000,
    enabled: noticeDialogOpen,
  });
  const noticeOperatorsQuery = useQuery({
    queryKey: ["notice-operators"],
    queryFn: listNoticeOperators,
    staleTime: 60_000,
    enabled: noticeDialogOpen,
  });
  const noticeReadsQuery = useQuery({
    queryKey: ["notice-acknowledgements", noticeReadsTarget?.id],
    queryFn: () => listNoticeAcknowledgements(noticeReadsTarget?.id as string),
    enabled: Boolean(noticeReadsTarget),
    staleTime: 15_000,
  });

  // Abre o editor de nota a partir da aba Notas / seletor de versão: carrega a
  // release completa por id e só então abre o diálogo (que exige a release).
  const pendingNoteQuery = useQuery({
    queryKey: ["release-by-id", pendingNoteId],
    queryFn: () => getAppReleaseById(pendingNoteId as string),
    enabled: Boolean(pendingNoteId),
  });

  useEffect(() => {
    if (!pendingNoteId) return;
    if (pendingNoteQuery.data) {
      setNoteDialogRelease(pendingNoteQuery.data);
      setPendingNoteId(null);
    } else if (pendingNoteQuery.isError) {
      toast.error("Não foi possível abrir a nota desta versão.");
      setPendingNoteId(null);
    }
  }, [pendingNoteId, pendingNoteQuery.data, pendingNoteQuery.isError]);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, status]);

  useEffect(() => {
    setNoticePage(1);
  }, [debouncedNoticeSearch, noticeStatus, noticeSeverity]);

  const releases = data?.rows ?? [];
  const total = data?.total ?? 0;
  const current = currentQuery.data ?? null;
  const stats = statsQuery.data ?? { drafts: 0, approved: 0, released: 0 };
  const activeNotices = activeNoticesQuery.data ?? 0;
  const releaseNotes = releaseNotesQuery.data ?? [];
  const history = historyQuery.data ?? [];
  const releaseOptions = releaseOptionsQuery.data ?? [];
  const notices = noticesQuery.data?.rows ?? [];
  const noticesTotal = noticesQuery.data?.total ?? 0;
  const hasFilters = Boolean(debouncedSearch.trim()) || status !== "all";
  const hasNoticeFilters = Boolean(debouncedNoticeSearch.trim()) || noticeStatus !== "all" || noticeSeverity !== "all";

  // Avisos ativos sempre no topo da lista da página atual.
  const sortedNotices = useMemo(
    () => [...notices].sort((a, b) => Number(b.status === "active") - Number(a.status === "active")),
    [notices],
  );

  const invalidate = () => {
    qc.invalidateQueries({ queryKey: ["app-releases"] });
    qc.invalidateQueries({ queryKey: ["app-release-stats"] });
    qc.invalidateQueries({ queryKey: ["app-notices-active-count"] });
    qc.invalidateQueries({ queryKey: ["app-release-current"] });
    qc.invalidateQueries({ queryKey: ["release-notes-list"] });
    qc.invalidateQueries({ queryKey: ["app-release-history"] });
    qc.invalidateQueries({ queryKey: ["release-options"] });
    qc.invalidateQueries({ queryKey: ["app-notices"] });
  };

  const actionMutation = useMutation({
    mutationFn: async () => {
      if (!confirm) return;
      if (confirm.action === "approve") return approveAppRelease(confirm.release.id);
      if (confirm.action === "release") return releaseAppRelease(confirm.release.id);
      if (confirm.action === "rollback") return rollbackAppRelease(confirm.release.id);
      return blockAppRelease(confirm.release.id, blockReason);
    },
    onSuccess: () => {
      invalidate();
      toast.success("Ação registrada");
      setConfirm(null);
      setBlockReason("");
    },
    onError: (err: unknown) => {
      invalidate();
      toast.error("Não foi possível concluir", {
        description: errorMessage(err),
      });
    },
  });

  const testingMutation = useMutation({
    mutationFn: sendAppReleaseToTesting,
    onSuccess: () => {
      invalidate();
      toast.success("Versão enviada para teste");
    },
    onError: (err: unknown) => {
      invalidate();
      toast.error("Não foi possível enviar para teste", {
        description: errorMessage(err),
      });
    },
  });

  const noticeStatusMutation = useMutation({
    mutationFn: ({ id, status }: { id: string; status: NoticeStatus }) => updateAppNoticeStatus(id, status),
    onSuccess: () => {
      invalidate();
      toast.success("Status do aviso atualizado");
    },
    onError: (err: unknown) => {
      invalidate();
      toast.error("Não foi possível atualizar o aviso", {
        description: errorMessage(err),
      });
    },
  });

  return (
    <>
      <PageHeader
        title="Atualizações"
        description="Gerencie versões do app, notas de atualização e avisos enviados aos operadores."
        action={
          <div className="flex flex-wrap items-center gap-2">
            {tab === "versoes"
              ? <ExportCsvButton filename="versoes-filtradas" rows={releases} columns={RELEASE_EXPORT_COLUMNS} />
              : <ExportCsvButton filename="avisos-filtrados" rows={sortedNotices} columns={NOTICE_EXPORT_COLUMNS} />}
            <Button variant="outline" size="sm" onClick={() => setNoticeDialog("new")}>
              <Megaphone className="h-4 w-4" /> Novo aviso
            </Button>
            <Button
              size="sm"
              onClick={() => {
                setEditing(null);
                setDialogOpen(true);
              }}
            >
              <Plus className="h-4 w-4" /> Nova versão
            </Button>
          </div>
        }
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard
          icon={<Rocket className="h-5 w-5" />}
          iconClassName="bg-success/25 text-success-foreground"
          label="Versão em produção"
          value={current?.version ?? "—"}
          hint={current ? `Liberada em ${fmtDate(current.released_at)}` : "Nenhuma versão ativa"}
          loading={isLoading || currentQuery.isLoading}
        />
        <StatCard
          icon={<FileText className="h-5 w-5" />}
          label="Versões em rascunho"
          value={stats.drafts}
          hint="Rascunho ou em teste"
          loading={statsQuery.isLoading}
        />
        <StatCard
          icon={<Check className="h-5 w-5" />}
          label="Versões aprovadas"
          value={stats.approved}
          hint="Prontas para liberar"
          loading={statsQuery.isLoading}
        />
        <StatCard
          icon={<Megaphone className="h-5 w-5" />}
          iconClassName="bg-warning/20 text-warning-foreground"
          label="Avisos ativos"
          value={activeNotices}
          hint={`${stats.released} versões no histórico`}
          loading={activeNoticesQuery.isLoading}
        />
      </div>

      {current && (
        <CurrentReleaseCard
          current={current}
          onEditNote={() => setNoteDialogRelease(current)}
          onBlock={() => {
            setBlockReason("");
            setConfirm({ release: current, action: "block" });
          }}
        />
      )}

      <Tabs value={tab} onValueChange={setTab} className="w-full">
        <div className="mb-5 overflow-x-auto pb-1">
          <TabsList className="h-auto flex-wrap">
            <TabsTrigger value="versoes">
              Versões <TabCount value={total} />
            </TabsTrigger>
            <TabsTrigger value="notas">
              Notas de atualização <TabCount value={releaseNotes.length} />
            </TabsTrigger>
            <TabsTrigger value="avisos">
              Avisos <TabCount value={activeNotices} tone="warning" />
            </TabsTrigger>
            <TabsTrigger value="historico">
              Histórico <TabCount value={history.length} />
            </TabsTrigger>
          </TabsList>
        </div>

        {/* ---------------------------- ABA VERSÕES ---------------------------- */}
        <TabsContent value="versoes" className="mt-0 space-y-5">
          <div className="flex flex-wrap items-center gap-3">
            <div className="relative w-full max-w-md flex-1">
              <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                placeholder="Buscar versão, título, canal, arquivo..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                className="h-10 rounded-lg pl-9"
              />
            </div>
            <Select value={status} onValueChange={(value) => setStatus(value as ReleaseStatus | "all")}>
              <SelectTrigger className="h-10 w-[180px] rounded-lg">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {RELEASE_STATUSES.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Button variant="outline" size="sm" onClick={invalidate} disabled={isFetching}>
              {isFetching ? <Loader2 className="h-4 w-4 animate-spin" /> : <RotateCcw className="h-4 w-4" />}
              Atualizar
            </Button>
            {hasFilters && (
              <Button variant="outline" size="sm" onClick={() => { setSearch(""); setStatus("all"); }}>
                Limpar filtros
              </Button>
            )}
            {data && (
              <span className="ml-auto text-sm text-muted-foreground">
                {releases.length} de {total} versões
              </span>
            )}
          </div>

          {isError ? (
            <Card className="shadow-sm">
              <ErrorState
                title="Não foi possível carregar as versões."
                description={(error as Error)?.message}
                action={<RetryButton onClick={invalidate} disabled={isFetching} />}
              />
            </Card>
          ) : (
            <Card className="overflow-hidden shadow-sm">
              <div className="overflow-x-auto">
                <Table className="min-w-[1080px]">
                  <TableHeader>
                    <TableRow>
                      <TableHead>Versão</TableHead>
                      <TableHead>Status</TableHead>
                      <TableHead>Arquivos</TableHead>
                      <TableHead>Nota</TableHead>
                      <TableHead>Responsáveis</TableHead>
                      <TableHead>Última ação</TableHead>
                      <TableHead className="text-right">Ações</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {isLoading &&
                      Array.from({ length: 5 }).map((_, i) => (
                        <TableRow key={i}>
                          <TableCell colSpan={7}>
                            <Skeleton className="h-8 w-full" />
                          </TableCell>
                        </TableRow>
                      ))}

                    {!isLoading && releases.length === 0 && (
                      <TableRow>
                        <TableCell colSpan={7}>
                          <EmptyState
                            icon={<Rocket className="h-6 w-6" />}
                            title={hasFilters ? "Nenhuma versão para este filtro." : "Nenhuma versão cadastrada."}
                            description={
                              hasFilters
                                ? "Ajuste a busca ou o filtro de status para ver outras versões."
                                : "Registre uma versão em rascunho para iniciar o fluxo de aprovação e liberação."
                            }
                            action={
                              hasFilters ? (
                                <Button variant="outline" size="sm" onClick={() => { setSearch(""); setStatus("all"); }}>
                                  Limpar filtros
                                </Button>
                              ) : (
                                <Button size="sm" onClick={() => { setEditing(null); setDialogOpen(true); }}>
                                  <Plus className="h-4 w-4" /> Nova versão
                                </Button>
                              )
                            }
                          />
                        </TableCell>
                      </TableRow>
                    )}

                    {!isLoading &&
                      releases.map((release) => (
                        <ReleaseRow
                          key={release.id}
                          release={release}
                          onEdit={() => {
                            setEditing(release);
                            setDialogOpen(true);
                          }}
                          onConfirm={(action) => {
                            setBlockReason("");
                            setConfirm({ release, action });
                          }}
                          onNote={() => setNoteDialogRelease(release)}
                          onSendToTesting={() => testingMutation.mutate(release)}
                          busyTesting={testingMutation.isPending}
                        />
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
        </TabsContent>

        {/* ------------------------- ABA NOTAS DE ATUALIZAÇÃO ------------------------- */}
        <TabsContent value="notas" className="mt-0 space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="min-w-0">
              <h2 className="font-display text-lg font-semibold">Notas de atualização</h2>
              <p className="text-sm text-muted-foreground">
                Cada nota pertence sempre a uma versão real do app e só aparece para o operador quando publicada.
              </p>
            </div>
            <Button size="sm" onClick={() => setVersionPickerOpen(true)}>
              <Plus className="h-4 w-4" /> Nova nota
            </Button>
          </div>

          {releaseNotesQuery.isError ? (
            <Card className="shadow-sm">
              <ErrorState
                title="Não foi possível carregar as notas."
                description={(releaseNotesQuery.error as Error)?.message}
                action={<RetryButton onClick={invalidate} disabled={releaseNotesQuery.isFetching} />}
              />
            </Card>
          ) : (
            <div className="grid gap-3">
              {releaseNotesQuery.isLoading &&
                Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-28 w-full" />)}

              {!releaseNotesQuery.isLoading && releaseNotes.length === 0 && (
                <Card className="shadow-sm">
                  <EmptyState
                    icon={<FileText className="h-6 w-6" />}
                    title="Nenhuma nota de atualização cadastrada."
                    description="Ao liberar uma versão, você pode criar uma nota para comunicar as novidades aos operadores."
                    action={
                      <Button size="sm" onClick={() => setVersionPickerOpen(true)}>
                        <Plus className="h-4 w-4" /> Nova nota
                      </Button>
                    }
                  />
                </Card>
              )}

              {releaseNotes.map((note) => (
                <ReleaseNoteRow key={note.id} note={note} onOpen={() => setPendingNoteId(note.app_release_id)} />
              ))}
            </div>
          )}
        </TabsContent>

        {/* ------------------------------- ABA AVISOS ------------------------------- */}
        <TabsContent value="avisos" className="mt-0 space-y-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="min-w-0">
              <h2 className="font-display text-lg font-semibold">Avisos</h2>
              <p className="text-sm text-muted-foreground">
                Comunicados independentes de versão para o app dos operadores. Avisos ativos aparecem primeiro.
              </p>
            </div>
            <Button size="sm" onClick={() => setNoticeDialog("new")}>
              <Plus className="h-4 w-4" /> Novo aviso
            </Button>
          </div>

          <div className="flex flex-wrap items-center gap-3">
            <div className="relative w-full max-w-md flex-1">
              <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
              <Input
                placeholder="Buscar título ou mensagem..."
                value={noticeSearch}
                onChange={(e) => setNoticeSearch(e.target.value)}
                className="h-10 rounded-lg pl-9"
              />
            </div>
            <Select value={noticeStatus} onValueChange={(value) => setNoticeStatus(value as NoticeStatus | "all")}>
              <SelectTrigger className="h-10 w-[160px] rounded-lg">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {NOTICE_STATUSES.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <Select value={noticeSeverity} onValueChange={(value) => setNoticeSeverity(value as NoticeSeverity | "all")}>
              <SelectTrigger className="h-10 w-[160px] rounded-lg">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {NOTICE_SEVERITIES.map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            {hasNoticeFilters && (
              <Button
                variant="outline"
                size="sm"
                onClick={() => { setNoticeSearch(""); setNoticeStatus("all"); setNoticeSeverity("all"); }}
              >
                Limpar filtros
              </Button>
            )}
            {noticesQuery.data && (
              <span className="ml-auto text-sm text-muted-foreground">
                {notices.length} de {noticesTotal} avisos
              </span>
            )}
          </div>

          {noticesQuery.isError ? (
            <Card className="shadow-sm">
              <ErrorState
                title="Não foi possível carregar os avisos."
                description={(noticesQuery.error as Error)?.message}
                action={<RetryButton onClick={invalidate} disabled={noticesQuery.isFetching} />}
              />
            </Card>
          ) : (
            <div className="grid gap-3">
              {noticesQuery.isLoading &&
                Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-28 w-full" />)}

              {!noticesQuery.isLoading && notices.length === 0 && (
                <Card className="shadow-sm">
                  <EmptyState
                    icon={<Megaphone className="h-6 w-6" />}
                    title={hasNoticeFilters ? "Nenhum aviso para este filtro." : "Nenhum aviso cadastrado."}
                    description={
                      hasNoticeFilters
                        ? "Ajuste a busca, o status ou a severidade para ver outros avisos."
                        : "Crie um aviso para comunicar instabilidade, manutenção ou uma orientação aos operadores."
                    }
                    action={
                      hasNoticeFilters ? (
                        <Button
                          variant="outline"
                          size="sm"
                          onClick={() => { setNoticeSearch(""); setNoticeStatus("all"); setNoticeSeverity("all"); }}
                        >
                          Limpar filtros
                        </Button>
                      ) : (
                        <Button size="sm" onClick={() => setNoticeDialog("new")}>
                          <Plus className="h-4 w-4" /> Novo aviso
                        </Button>
                      )
                    }
                  />
                </Card>
              )}

              {sortedNotices.map((notice) => (
                <NoticeCard
                  key={notice.id}
                  notice={notice}
                  busy={noticeStatusMutation.isPending}
                  onEdit={() => setNoticeDialog(notice)}
                  onStatus={(nextStatus) => noticeStatusMutation.mutate({ id: notice.id, status: nextStatus })}
                  onViewReads={() => setNoticeReadsTarget(notice)}
                />
              ))}
            </div>
          )}

          {!noticesQuery.isError && (
            <PaginationFooter
              page={noticePage}
              pageSize={noticePageSize}
              total={noticesTotal}
              isLoading={noticesQuery.isLoading || noticesQuery.isFetching}
              onPageChange={setNoticePage}
              onPageSizeChange={(value) => {
                setNoticePageSize(value);
                setNoticePage(1);
              }}
            />
          )}
        </TabsContent>

        {/* ------------------------------ ABA HISTÓRICO ------------------------------ */}
        <TabsContent value="historico" className="mt-0 space-y-4">
          <div className="min-w-0">
            <h2 className="font-display text-lg font-semibold">Histórico</h2>
            <p className="text-sm text-muted-foreground">
              Versões liberadas, bloqueadas e substituídas, com responsáveis e motivos.
            </p>
          </div>

          {historyQuery.isError ? (
            <Card className="shadow-sm">
              <ErrorState
                title="Não foi possível carregar o histórico."
                description={(historyQuery.error as Error)?.message}
                action={<RetryButton onClick={invalidate} disabled={historyQuery.isFetching} />}
              />
            </Card>
          ) : (
            <div className="grid gap-3">
              {historyQuery.isLoading &&
                Array.from({ length: 3 }).map((_, i) => <Skeleton key={i} className="h-24 w-full" />)}

              {!historyQuery.isLoading && history.length === 0 && (
                <Card className="shadow-sm">
                  <EmptyState
                    icon={<History className="h-6 w-6" />}
                    title="Nenhum evento no histórico ainda."
                    description="Quando uma versão for liberada ou bloqueada, o evento aparece aqui com o responsável."
                  />
                </Card>
              )}

              {history.map((release) => (
                <HistoryRow key={release.id} release={release} />
              ))}
            </div>
          )}
        </TabsContent>
      </Tabs>

      <ReleaseDialog
        open={dialogOpen}
        onOpenChange={setDialogOpen}
        release={editing}
        onSaved={() => {
          setDialogOpen(false);
          setEditing(null);
          invalidate();
        }}
        onStale={() => {
          setDialogOpen(false);
          setEditing(null);
          invalidate();
        }}
      />

      <VersionPickerDialog
        open={versionPickerOpen}
        options={releaseOptions}
        loading={releaseOptionsQuery.isLoading}
        onOpenChange={setVersionPickerOpen}
        onPick={(id) => {
          setVersionPickerOpen(false);
          setPendingNoteId(id);
        }}
      />

      <ReleaseNoteDialog
        release={noteDialogRelease}
        open={Boolean(noteDialogRelease)}
        onOpenChange={(open) => !open && setNoteDialogRelease(null)}
        onSaved={() => {
          setNoteDialogRelease(null);
          invalidate();
        }}
      />

      <NoticeDialog
        open={Boolean(noticeDialog)}
        notice={noticeDialog === "new" ? null : noticeDialog}
        units={noticeUnitsQuery.data ?? []}
        operators={noticeOperatorsQuery.data ?? []}
        onOpenChange={(open) => !open && setNoticeDialog(null)}
        onSaved={() => {
          setNoticeDialog(null);
          invalidate();
        }}
      />

      <NoticeReadDialog
        notice={noticeReadsTarget}
        rows={noticeReadsQuery.data ?? []}
        loading={noticeReadsQuery.isLoading}
        error={noticeReadsQuery.error as Error | null}
        onOpenChange={(open) => !open && setNoticeReadsTarget(null)}
      />

      <ConfirmActionDialog
        confirm={confirm}
        reason={blockReason}
        onReasonChange={setBlockReason}
        busy={actionMutation.isPending}
        onCancel={() => setConfirm(null)}
        onConfirm={() => actionMutation.mutate()}
      />
    </>
  );
}

function TabCount({ value, tone = "neutral" }: { value: number; tone?: "neutral" | "warning" }) {
  if (!value) return null;
  return (
    <span
      className={cn(
        "ml-1.5 inline-flex min-w-5 items-center justify-center rounded-full px-1.5 py-0.5 text-[11px] font-semibold tabular-nums",
        tone === "warning" ? "bg-warning/20 text-warning-foreground" : "bg-muted text-muted-foreground",
      )}
    >
      {value}
    </span>
  );
}

function DefItem({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <span className="text-xs text-muted-foreground">{label}</span>
      <span className="text-sm font-medium text-foreground">{value}</span>
    </div>
  );
}

function CurrentReleaseCard({
  current,
  onEditNote,
  onBlock,
}: {
  current: AppRelease;
  onEditNote: () => void;
  onBlock: () => void;
}) {
  const note = current.release_note;
  return (
    <Card className="mb-6 border-success/40 p-5 shadow-sm">
      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 flex-1">
          <div className="mb-3 flex flex-wrap items-center gap-2">
            <StatusBadge tone="success" label="Produção" />
            <span className="font-display text-2xl font-semibold tracking-tight">{current.version}</span>
            <span className="text-sm text-muted-foreground">{current.title ?? "Sem título"}</span>
          </div>

          <div className="grid grid-cols-2 gap-4 sm:grid-cols-3 xl:grid-cols-4">
            <DefItem label="Canal" value={current.channel} />
            <DefItem label="Obrigatória" value={current.mandatory ? "Sim" : "Não"} />
            <DefItem label="Versão mínima" value={current.minimum_version ?? "—"} />
            <DefItem label="Liberada por" value={current.released_by_name ?? "—"} />
            <DefItem label="Liberada em" value={fmtDate(current.released_at)} />
          </div>

          {(note?.status === "published" || current.release_notes) && (
            <div className="mt-4 max-w-3xl rounded-lg border border-border bg-muted/30 p-3">
              {note?.status === "published" ? (
                <>
                  <div className="mb-1 flex flex-wrap items-center gap-2">
                    <Badge variant="outline">Nota publicada</Badge>
                    <span className="text-sm font-semibold">{note.title}</span>
                  </div>
                  <p className="text-sm text-muted-foreground">{note.summary}</p>
                </>
              ) : (
                <p className="whitespace-pre-wrap text-sm text-muted-foreground">{current.release_notes}</p>
              )}
            </div>
          )}
        </div>

        <div className="flex shrink-0 flex-row flex-wrap gap-2 lg:flex-col">
          <Button size="sm" variant="outline" onClick={onEditNote}>
            {note ? <Pencil className="h-4 w-4" /> : <Plus className="h-4 w-4" />}
            {note ? "Editar nota" : "Criar nota"}
          </Button>
          <Button size="sm" variant="outline" className="text-destructive" onClick={onBlock}>
            <ShieldAlert className="h-4 w-4" /> Bloquear versão
          </Button>
        </div>
      </div>
    </Card>
  );
}

function FileLine({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="truncate" title={value ?? ""}>
      <span className="text-muted-foreground/70">{label}:</span> {value ?? "—"}
    </div>
  );
}

function ReleaseRow({
  release,
  onEdit,
  onConfirm,
  onNote,
  onSendToTesting,
  busyTesting,
}: {
  release: AppRelease;
  onEdit: () => void;
  onConfirm: (action: "approve" | "release" | "block" | "rollback") => void;
  onNote: () => void;
  onSendToTesting: () => void;
  busyTesting: boolean;
}) {
  const ready = releaseRequiredFieldsReady(release);
  const canEdit = release.status === "draft" || release.status === "testing";
  const canSendToTesting = release.status === "draft";
  const canApprove = (release.status === "draft" || release.status === "testing") && ready;
  const canRelease = release.status === "approved" && ready;
  const canBlock = release.status !== "blocked" && release.status !== "superseded";
  const canRollback = (release.status === "released" || release.status === "superseded") && !release.is_current && ready;
  const last = lastAction(release);

  return (
    <TableRow>
      <TableCell className="align-top">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-semibold">{release.version}</span>
        </div>
        <div className="mt-1 text-xs text-muted-foreground">
          {release.channel} · {release.mandatory ? "obrigatória" : "opcional"} · mín. {release.minimum_version ?? "—"}
        </div>
        <div className="mt-0.5 max-w-[180px] truncate text-xs text-muted-foreground" title={release.title ?? ""}>
          {release.title ?? "Sem título"}
        </div>
      </TableCell>

      <TableCell className="align-top">
        <ReleaseStatusBadge release={release} />
        {!ready && (
          <p className="mt-2 flex items-start gap-1 text-xs text-destructive">
            <AlertTriangle className="mt-0.5 h-3 w-3 shrink-0" />
            Campos obrigatórios incompletos.
          </p>
        )}
      </TableCell>

      <TableCell className="max-w-[240px] align-top">
        <div className="grid gap-0.5 rounded-md bg-muted/40 p-2 font-mono text-[11px] leading-relaxed text-muted-foreground">
          <FileLine label="manifest" value={release.manifest_key} />
          <FileLine label="installer" value={release.installer_key} />
          <FileLine label="blockmap" value={release.blockmap_key} />
          <FileLine label="sha512" value={release.sha512} />
          <div className="pt-0.5 text-foreground/70">{fmtBytes(release.size_bytes)}</div>
        </div>
      </TableCell>

      <TableCell className="max-w-[210px] align-top">
        {release.release_note ? (
          <div className="grid gap-2">
            <StatusBadge
              tone={release.release_note.status === "published" ? "success" : "neutral"}
              label={release.release_note.status === "published" ? "Publicada" : "Rascunho"}
              className="w-fit"
            />
            <p className="line-clamp-2 text-sm text-muted-foreground">{release.release_note.summary}</p>
            <Button size="sm" variant="outline" onClick={onNote}>
              {canEdit ? <Pencil className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
              {canEdit ? "Editar nota" : "Ver nota"}
            </Button>
          </div>
        ) : (
          <Button size="sm" variant="outline" onClick={onNote}>
            <Plus className="h-4 w-4" /> Criar nota
          </Button>
        )}
      </TableCell>

      <TableCell className="align-top text-xs text-muted-foreground">
        <div className="grid gap-0.5">
          {release.created_by_name && <div>Criada: {release.created_by_name}</div>}
          {release.approved_by_name && <div>Aprovada: {release.approved_by_name}</div>}
          {release.released_by_name && <div>Liberada: {release.released_by_name}</div>}
          {release.blocked_by_name && <div className="text-destructive">Bloqueada: {release.blocked_by_name}</div>}
          {!release.created_by_name &&
            !release.approved_by_name &&
            !release.released_by_name &&
            !release.blocked_by_name && <div>—</div>}
        </div>
      </TableCell>

      <TableCell className="max-w-[180px] align-top text-xs text-muted-foreground">
        <div className="font-medium text-foreground/80">{last.label}</div>
        <div>{fmtDate(last.at)}</div>
        {release.block_reason && (
          <div className="mt-1 line-clamp-2 text-destructive" title={release.block_reason}>
            Motivo: {release.block_reason}
          </div>
        )}
      </TableCell>

      <TableCell className="align-top">
        <div className="flex flex-wrap justify-end gap-1.5">
          {canEdit && (
            <Button size="sm" variant="outline" onClick={onEdit}>
              Editar
            </Button>
          )}
          {canSendToTesting && (
            <Button size="sm" variant="outline" onClick={onSendToTesting} disabled={busyTesting}>
              {busyTesting && <Loader2 className="h-4 w-4 animate-spin" />}
              Enviar para teste
            </Button>
          )}
          {canApprove && (
            <Button size="sm" variant="outline" onClick={() => onConfirm("approve")}>
              <Check className="h-4 w-4" /> Aprovar
            </Button>
          )}
          {canRelease && (
            <Button size="sm" onClick={() => onConfirm("release")}>
              <Rocket className="h-4 w-4" /> Liberar
            </Button>
          )}
          {canBlock && (
            <Button size="sm" variant="outline" className="text-destructive" onClick={() => onConfirm("block")}>
              <ShieldAlert className="h-4 w-4" /> Bloquear
            </Button>
          )}
          {canRollback && (
            <Button size="sm" variant="outline" onClick={() => onConfirm("rollback")}>
              <RotateCcw className="h-4 w-4" /> Rollback
            </Button>
          )}
        </div>
      </TableCell>
    </TableRow>
  );
}

function ReleaseNoteRow({ note, onOpen }: { note: AppReleaseNote; onOpen: () => void }) {
  const published = note.status === "published";
  return (
    <Card className="p-4 shadow-sm">
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0 flex-1">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <Badge variant="outline">Versão {note.version_number}</Badge>
            <StatusBadge tone={published ? "success" : "neutral"} label={published ? "Publicada" : "Rascunho"} />
            {note.release_is_current && <StatusBadge tone="success" label="Produção" />}
          </div>
          <p className="font-medium">{note.title}</p>
          <p className="mt-1 text-sm text-muted-foreground">{note.summary}</p>
          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <span>{published ? `Publicada: ${fmtDate(note.published_at)}` : `Atualizada: ${fmtDate(note.updated_at)}`}</span>
            {note.created_by_name && <span>Criada por: {note.created_by_name}</span>}
            {published && <span>Lidas: {note.read_count}</span>}
            {published && <span>Confirmadas: {note.ack_count}</span>}
          </div>
        </div>
        <div className="shrink-0">
          <Button size="sm" variant="outline" onClick={onOpen}>
            <Pencil className="h-4 w-4" /> Ver / editar
          </Button>
        </div>
      </div>
    </Card>
  );
}

function HistoryRow({ release }: { release: AppRelease }) {
  const last = lastAction(release);
  const meta = RELEASE_STATUS_META[release.status];
  const Icon =
    release.status === "blocked" ? Ban : release.status === "released" ? CheckCircle2 : Clock;
  const iconClass =
    release.status === "blocked"
      ? "bg-destructive/10 text-destructive"
      : release.status === "released"
        ? "bg-success/25 text-success-foreground"
        : "bg-muted text-muted-foreground";

  return (
    <Card className="p-4 shadow-sm">
      <div className="flex items-start gap-3">
        <div className={cn("flex h-9 w-9 shrink-0 items-center justify-center rounded-lg", iconClass)}>
          <Icon className="h-5 w-5" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <span className="font-semibold">{release.version}</span>
            <ReleaseStatusBadge release={release} />
            <span className="ml-auto text-xs text-muted-foreground">{fmtDate(last.at)}</span>
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {last.label}
            {last.by ? ` por ${last.by}` : ""}
            {release.title ? ` · ${release.title}` : ""}
          </p>
          {release.status === "blocked" && release.block_reason && (
            <p className="mt-2 rounded-md border border-destructive/30 bg-destructive/5 p-2 text-xs text-destructive">
              Motivo do bloqueio: {release.block_reason}
            </p>
          )}
        </div>
      </div>
    </Card>
  );
}

function NoticeCard({
  notice,
  busy,
  onEdit,
  onStatus,
  onViewReads,
}: {
  notice: AppNotice;
  busy: boolean;
  onEdit: () => void;
  onStatus: (status: NoticeStatus) => void;
  onViewReads: () => void;
}) {
  const label = noticeStatusLabel(notice);
  const severity = NOTICE_SEVERITY_META[notice.severity];
  const isActive = notice.status === "active";

  return (
    <Card className={cn("p-4 shadow-sm", isActive && "border-success/40")}>
      <div className="flex flex-col gap-3 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
          <div className="mb-2 flex flex-wrap items-center gap-2">
            <StatusBadge tone={noticeStatusTone(label)} label={label} />
            <StatusBadge tone={severity.tone} label={severity.label} dot={false} />
            {notice.requires_ack && <Badge variant="outline">Exige confirmação</Badge>}
            <span className="text-xs text-muted-foreground">Público: {audienceLabel(notice)}</span>
          </div>
          <p className="font-semibold">{notice.title}</p>
          <p className="mt-1 whitespace-pre-wrap text-sm text-muted-foreground">{notice.message}</p>
          <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <span>Início: {fmtDate(notice.starts_at)}</span>
            <span>Fim: {fmtDate(notice.ends_at)}</span>
            <span>Lidas: {notice.read_count}</span>
            <span>Confirmadas: {notice.ack_count}</span>
            <span>Atualizado: {fmtDate(notice.updated_at)}</span>
          </div>
        </div>
        <div className="flex shrink-0 flex-wrap justify-end gap-1.5">
          <Button size="sm" variant="outline" onClick={onViewReads}>
            <Eye className="h-4 w-4" /> Ver leituras
          </Button>
          <Button size="sm" variant="outline" onClick={onEdit}>
            <Pencil className="h-4 w-4" /> Editar
          </Button>
          {notice.status !== "active" && (
            <Button size="sm" variant="outline" onClick={() => onStatus("active")} disabled={busy}>
              Ativar
            </Button>
          )}
          {notice.status === "active" && (
            <>
              <Button size="sm" variant="outline" onClick={() => onStatus("disabled")} disabled={busy}>
                Desativar
              </Button>
              <Button size="sm" variant="outline" onClick={() => onStatus("expired")} disabled={busy}>
                Expirar agora
              </Button>
            </>
          )}
        </div>
      </div>
    </Card>
  );
}

function VersionPickerDialog({
  open,
  options,
  loading,
  onOpenChange,
  onPick,
}: {
  open: boolean;
  options: { id: string; version: string; status: ReleaseStatus; has_note: boolean }[];
  loading: boolean;
  onOpenChange: (open: boolean) => void;
  onPick: (id: string) => void;
}) {
  const [selected, setSelected] = useState<string>("");

  useEffect(() => {
    if (!open) setSelected("");
  }, [open]);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Nova nota de atualização</DialogTitle>
          <DialogDescription>
            Selecione a versão à qual esta nota ficará vinculada. Toda nota pertence sempre a uma versão real do app.
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-2">
          <Label>Versão</Label>
          <Select value={selected || undefined} onValueChange={setSelected} disabled={loading}>
            <SelectTrigger>
              <SelectValue placeholder={loading ? "Carregando versões..." : "Selecione a versão"} />
            </SelectTrigger>
            <SelectContent>
              {options.map((opt) => (
                <SelectItem key={opt.id} value={opt.id}>
                  {opt.version} · {statusLabel(opt.status)}
                  {opt.has_note ? " · já tem nota" : ""}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          {!loading && options.length === 0 && (
            <p className="text-xs text-muted-foreground">
              Nenhuma versão cadastrada ainda. Crie uma versão para poder vincular uma nota.
            </p>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={() => selected && onPick(selected)} disabled={!selected}>
            Continuar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ReleaseNoteDialog({
  release,
  open,
  onOpenChange,
  onSaved,
}: {
  release: AppRelease | null;
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [input, setInput] = useState<AppReleaseNoteInput>({
    app_release_id: "",
    title: "",
    summary: "",
    content: "",
    status: "draft",
  });
  const [novidades, setNovidades] = useState("");
  const [correcoes, setCorrecoes] = useState("");
  const [observacoes, setObservacoes] = useState("");

  useEffect(() => {
    if (!release) return;
    const note = release.release_note;
    const sections = splitNoteContent(note?.content);
    setInput({
      app_release_id: release.id,
      title: note?.title ?? `Atualização ${release.version}`,
      summary: note?.summary ?? "",
      content: note?.content ?? "",
      status: note?.status ?? "draft",
    });
    setNovidades(sections.novidades);
    setCorrecoes(sections.correcoes);
    setObservacoes(sections.observacoes);
  }, [release, open]);

  const payload = {
    ...input,
    content: buildNoteContent(novidades, correcoes, observacoes),
  };
  const formErrors = releaseNoteFormErrors(payload);
  const previewSections = [
    { title: "Novidades", content: novidades },
    { title: "Correções", content: correcoes },
    { title: "Observações", content: observacoes },
  ].filter((section) => section.content.trim());

  const mutation = useMutation({
    mutationFn: () => upsertAppReleaseNote(payload),
    onSuccess: () => {
      toast.success(input.status === "published" ? "Nota publicada" : "Nota salva como rascunho");
      onSaved();
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível salvar a nota", {
        description: errorMessage(err),
      });
    },
  });

  if (!release) return null;

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-5xl">
        <DialogHeader>
          <DialogTitle>{release.release_note ? "Editar nota" : "Criar nota"} · {release.version}</DialogTitle>
          <DialogDescription>
            A nota fica vinculada somente a esta versão. Ela só deve ser publicada quando estiver pronta para o app dos operadores.
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_300px]">
          <div className="space-y-4">
            <div className="grid gap-3 sm:grid-cols-[minmax(0,1fr)_180px]">
          <Field label="Versão">
            <Input value={release.version} disabled readOnly />
          </Field>
          <Field label="Status da nota">
            <Select value={input.status} onValueChange={(value) => setInput((cur) => ({ ...cur, status: value as "draft" | "published" }))}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="draft">Rascunho</SelectItem>
                <SelectItem value="published">Publicada</SelectItem>
              </SelectContent>
            </Select>
          </Field>
            </div>
          <Field label="Título" className="sm:col-span-2">
            <Input value={input.title} onChange={(e) => setInput((cur) => ({ ...cur, title: e.target.value }))} />
          </Field>
          <Field label="Resumo curto" className="sm:col-span-2">
            <Textarea value={input.summary} onChange={(e) => setInput((cur) => ({ ...cur, summary: e.target.value }))} rows={2} />
          </Field>
          <Field label="Novidades" className="sm:col-span-2">
            <Textarea value={novidades} onChange={(e) => setNovidades(e.target.value)} rows={6} placeholder="Uma novidade por linha." />
          </Field>
          <details className="rounded-lg border border-border bg-muted/20 px-3 py-2">
            <summary className="cursor-pointer text-sm font-medium">Detalhes opcionais</summary>
            <div className="mt-4 space-y-4">
          <Field label="Correções" className="sm:col-span-2">
            <Textarea value={correcoes} onChange={(e) => setCorrecoes(e.target.value)} rows={4} />
          </Field>
          <Field label="Observações" className="sm:col-span-2">
            <Textarea value={observacoes} onChange={(e) => setObservacoes(e.target.value)} rows={3} />
          </Field>
            </div>
          </details>
        </div>

          <ReleaseNotePreview
            version={release.version}
            status={input.status}
            title={input.title}
            summary={input.summary}
            sections={previewSections}
          />
        </div>

        {formErrors.length > 0 && (
          <ul className="list-disc space-y-1 rounded-lg border border-destructive/40 bg-destructive/5 p-3 pl-6 text-xs text-destructive">
            {formErrors.map((err) => (
              <li key={err}>{err}</li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={() => mutation.mutate()} disabled={mutation.isPending || formErrors.length > 0}>
            {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            Salvar nota
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function ReleaseNotePreview({
  version,
  status,
  title,
  summary,
  sections,
}: {
  version: string;
  status: "draft" | "published";
  title: string;
  summary: string;
  sections: Array<{ title: string; content: string }>;
}) {
  return (
    <aside className="lg:sticky lg:top-0 lg:self-start">
      <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Prévia no app</p>
      <div className="overflow-hidden rounded-lg border border-border bg-background shadow-sm">
        <div className="flex items-center justify-between border-b border-border bg-muted/40 px-4 py-3">
          <div>
            <p className="text-xs text-muted-foreground">Porter Music</p>
            <p className="text-sm font-semibold">Atualização disponível</p>
          </div>
          <Badge variant={status === "published" ? "default" : "secondary"} className="text-[10px]">
            {status === "published" ? "Publicada" : "Rascunho"}
          </Badge>
        </div>
        <div className="max-h-[470px] space-y-4 overflow-y-auto p-4">
          <div className="flex items-center gap-2 text-xs text-muted-foreground">
            <span className="rounded bg-primary/10 px-2 py-1 font-medium text-primary">v{version}</span>
            <span>Novidades do app</span>
          </div>
          <div>
            <h3 className="text-base font-semibold leading-tight">{title.trim() || `Atualização ${version}`}</h3>
            {summary.trim() && <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{summary}</p>}
          </div>
          {sections.length > 0 ? (
            sections.map((section) => (
              <section key={section.title}>
                <h4 className="text-sm font-semibold">{section.title}</h4>
                <ul className="mt-2 space-y-1.5 text-sm text-muted-foreground">
                  {section.content
                    .split("\n")
                    .map((line) => line.replace(/^[-•]\s*/, "").trim())
                    .filter((line) => Boolean(line) && line.toLocaleLowerCase() !== section.title.toLocaleLowerCase())
                    .map((line) => (
                      <li key={line} className="flex gap-2">
                        <span className="text-primary">•</span>
                        <span>{line}</span>
                      </li>
                    ))}
                </ul>
              </section>
            ))
          ) : (
            <p className="rounded-md border border-dashed border-border p-3 text-sm text-muted-foreground">
              A prévia aparecerá aqui enquanto você escreve.
            </p>
          )}
        </div>
      </div>
    </aside>
  );
}

function NoticeReadDialog({
  notice,
  rows,
  loading,
  error,
  onOpenChange,
}: {
  notice: AppNotice | null;
  rows: NoticeAcknowledgement[];
  loading: boolean;
  error: Error | null;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={Boolean(notice)} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>Leituras do aviso</DialogTitle>
          <DialogDescription>{notice?.title ?? "Aviso"}</DialogDescription>
        </DialogHeader>

        {error ? (
          <ErrorState title="Não foi possível carregar as leituras." description={error.message} />
        ) : loading ? (
          <div className="space-y-2">
            {Array.from({ length: 4 }).map((_, index) => <Skeleton key={index} className="h-14 w-full" />)}
          </div>
        ) : rows.length ? (
          <div className="overflow-hidden rounded-lg border border-border">
            <div className="divide-y divide-border">
              {rows.map((row) => (
                <div key={row.id} className="flex flex-col gap-2 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                  <div className="min-w-0">
                    <p className="truncate text-sm font-medium">{row.operator_name}</p>
                    <p className="text-xs text-muted-foreground">{row.unit_name ?? "Condomínio não informado"}</p>
                  </div>
                  <div className="shrink-0 text-xs text-muted-foreground sm:text-right">
                    <p>Lido: {fmtDate(row.read_at)}</p>
                    <p>{row.acknowledged_at ? `Confirmado: ${fmtDate(row.acknowledged_at)}` : "Sem confirmação"}</p>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <div className="rounded-lg border border-dashed border-border px-5 py-10 text-center text-sm text-muted-foreground">
            Nenhum operador leu este aviso ainda.
          </div>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>Fechar</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function NoticeDialog({
  open,
  notice,
  units,
  operators,
  onOpenChange,
  onSaved,
}: {
  open: boolean;
  notice: AppNotice | null;
  units: { id: string; label: string }[];
  operators: { id: string; label: string }[];
  onOpenChange: (open: boolean) => void;
  onSaved: () => void;
}) {
  const [input, setInput] = useState<AppNoticeInput>(EMPTY_NOTICE_INPUT);

  useEffect(() => {
    if (!open) return;
    setInput(
      notice
        ? {
            id: notice.id,
            title: notice.title,
            message: notice.message,
            severity: notice.severity,
            status: notice.status,
            starts_at: toDateTimeInput(notice.starts_at),
            ends_at: toDateTimeInput(notice.ends_at),
            audience_type: notice.audience_type,
            condominium_id: notice.condominium_id ?? "",
            operator_id: notice.operator_id ?? "",
            shift: notice.shift ?? "",
            requires_ack: notice.requires_ack,
          }
        : EMPTY_NOTICE_INPUT,
    );
  }, [notice, open]);

  const update = <K extends keyof AppNoticeInput>(key: K, value: AppNoticeInput[K]) =>
    setInput((cur) => ({ ...cur, [key]: value }));

  const formErrors = noticeFormErrors(input);
  const mutation = useMutation({
    mutationFn: () => upsertAppNotice(input),
    onSuccess: () => {
      toast.success(notice ? "Aviso atualizado" : "Aviso criado");
      onSaved();
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível salvar o aviso", {
        description: errorMessage(err),
      });
    },
  });

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-5xl">
        <DialogHeader>
          <DialogTitle>{notice ? "Editar aviso" : "Novo aviso"}</DialogTitle>
          <DialogDescription>
            Avisos são independentes de versão e aparecem no app conforme status, período e público.
          </DialogDescription>
        </DialogHeader>

        <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_300px]">
          <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Título" className="sm:col-span-2">
            <Input value={input.title} onChange={(e) => update("title", e.target.value)} />
          </Field>
          <Field label="Mensagem" className="sm:col-span-2">
            <Textarea value={input.message} onChange={(e) => update("message", e.target.value)} rows={5} />
          </Field>
          <Field label="Severidade">
            <Select value={input.severity} onValueChange={(value) => update("severity", value as NoticeSeverity)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {NOTICE_SEVERITIES.filter((item) => item.value !== "all").map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <Field label="Status">
            <Select value={input.status} onValueChange={(value) => update("status", value as NoticeStatus)}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {NOTICE_STATUSES.filter((item) => item.value !== "all").map((item) => (
                  <SelectItem key={item.value} value={item.value}>
                    {item.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>
          <Field label="Início">
            <Input type="datetime-local" value={input.starts_at} onChange={(e) => update("starts_at", e.target.value)} />
          </Field>
          <Field label="Fim">
            <Input type="datetime-local" value={input.ends_at} onChange={(e) => update("ends_at", e.target.value)} />
          </Field>
          <Field label="Público">
            <Select value={input.audience_type} onValueChange={(value) => update("audience_type", value as AppNoticeInput["audience_type"])}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="all">Todos</SelectItem>
                <SelectItem value="condominium">Condomínio</SelectItem>
                <SelectItem value="shift">Turno</SelectItem>
                <SelectItem value="user">Operador</SelectItem>
              </SelectContent>
            </Select>
          </Field>
          {input.audience_type === "condominium" && (
            <Field label="Condomínio">
              <Select value={input.condominium_id || undefined} onValueChange={(value) => update("condominium_id", value)}>
                <SelectTrigger>
                  <SelectValue placeholder="Selecione" />
                </SelectTrigger>
                <SelectContent>
                  {units.map((unit) => (
                    <SelectItem key={unit.id} value={unit.id}>
                      {unit.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          )}
          {input.audience_type === "shift" && (
            <Field label="Turno">
              <Select value={input.shift || undefined} onValueChange={(value) => update("shift", value)}>
                <SelectTrigger>
                  <SelectValue placeholder="Selecione" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="day">Diurno</SelectItem>
                  <SelectItem value="night">Noturno</SelectItem>
                  <SelectItem value="other">Outro</SelectItem>
                </SelectContent>
              </Select>
            </Field>
          )}
          {input.audience_type === "user" && (
            <Field label="Operador">
              <Select value={input.operator_id || undefined} onValueChange={(value) => update("operator_id", value)}>
                <SelectTrigger>
                  <SelectValue placeholder="Selecione" />
                </SelectTrigger>
                <SelectContent>
                  {operators.map((operator) => (
                    <SelectItem key={operator.id} value={operator.id}>
                      {operator.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </Field>
          )}
          <div className="flex items-center justify-between rounded-lg border border-border p-3 sm:col-span-2">
            <div>
              <Label>Exige confirmação de leitura</Label>
              <p className="text-xs text-muted-foreground">O app deve registrar confirmação quando o operador aceitar o aviso.</p>
            </div>
            <Switch checked={input.requires_ack} onCheckedChange={(value) => update("requires_ack", value)} />
          </div>
          </div>

          <NoticePreview input={input} />
        </div>

        {formErrors.length > 0 && (
          <ul className="list-disc space-y-1 rounded-lg border border-destructive/40 bg-destructive/5 p-3 pl-6 text-xs text-destructive">
            {formErrors.map((err) => (
              <li key={err}>{err}</li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={() => mutation.mutate()} disabled={mutation.isPending || formErrors.length > 0}>
            {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            Salvar aviso
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function NoticePreview({ input }: { input: AppNoticeInput }) {
  const severity = NOTICE_SEVERITY_META[input.severity];
  const colors: Record<NoticeSeverity, { header: string; icon: string; accent: string }> = {
    info: {
      header: "bg-blue-50 text-blue-950 dark:bg-blue-950/40 dark:text-blue-100",
      icon: "bg-blue-100 text-blue-700 dark:bg-blue-900/70 dark:text-blue-200",
      accent: "text-blue-600",
    },
    warning: {
      header: "bg-amber-50 text-amber-950 dark:bg-amber-950/40 dark:text-amber-100",
      icon: "bg-amber-100 text-amber-700 dark:bg-amber-900/70 dark:text-amber-200",
      accent: "text-amber-600",
    },
    critical: {
      header: "bg-red-50 text-red-950 dark:bg-red-950/40 dark:text-red-100",
      icon: "bg-red-100 text-red-700 dark:bg-red-900/70 dark:text-red-200",
      accent: "text-red-600",
    },
    success: {
      header: "bg-emerald-50 text-emerald-950 dark:bg-emerald-950/40 dark:text-emerald-100",
      icon: "bg-emerald-100 text-emerald-700 dark:bg-emerald-900/70 dark:text-emerald-200",
      accent: "text-emerald-600",
    },
  };
  const color = colors[input.severity];

  return (
    <aside className="lg:sticky lg:top-0 lg:self-start">
      <p className="mb-2 text-xs font-medium uppercase tracking-wide text-muted-foreground">Prévia no app</p>
      <div className="overflow-hidden rounded-lg border border-border bg-background shadow-sm">
        <div className={cn("flex items-center gap-3 border-b border-border px-4 py-3", color.header)}>
          <span className={cn("flex h-9 w-9 shrink-0 items-center justify-center rounded-full", color.icon)}>
            <Megaphone className="h-4 w-4" />
          </span>
          <div className="min-w-0 flex-1">
            <p className="text-xs opacity-70">Porter Music</p>
            <p className="text-sm font-semibold">Novo aviso</p>
          </div>
          <StatusBadge tone={severity.tone} label={severity.label} dot={false} />
        </div>
        <div className="max-h-[470px] space-y-4 overflow-y-auto p-4">
          <div>
            <h3 className="text-base font-semibold leading-tight">{input.title.trim() || "Título do aviso"}</h3>
            {input.message.trim() ? (
              <p className="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-muted-foreground">{input.message}</p>
            ) : (
              <p className="mt-2 rounded-md border border-dashed border-border p-3 text-sm text-muted-foreground">
                A mensagem aparecerá aqui enquanto você escreve.
              </p>
            )}
          </div>
          {input.requires_ack && (
            <div className="flex items-center gap-2 rounded-md border border-border bg-muted/30 p-3 text-sm">
              <Check className={cn("h-4 w-4 shrink-0", color.accent)} />
              <span>Li e confirmo este aviso</span>
            </div>
          )}
        </div>
      </div>
    </aside>
  );
}

function ReleaseDialog({
  open,
  onOpenChange,
  release,
  onSaved,
  onStale,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  release: AppRelease | null;
  onSaved: () => void;
  onStale: () => void;
}) {
  const [input, setInput] = useState<AppReleaseInput>(EMPTY_INPUT);
  const [ymlText, setYmlText] = useState("");

  useEffect(() => {
    setInput(release ? toInput(release) : EMPTY_INPUT);
    setYmlText("");
  }, [release, open]);

  const applyYml = (text: string) => {
    const trimmed = text.trim();
    if (!trimmed) {
      toast.error("Cole o conteúdo do latest.yml ou selecione o arquivo.");
      return;
    }
    try {
      const fields = parseLatestYml(trimmed, input.channel);
      setInput((cur) => ({ ...cur, ...fields }));
      toast.success(`Campos preenchidos da versão ${fields.version}`, {
        description: "Confira as chaves do R2 (installer/blockmap/manifest) antes de salvar.",
      });
    } catch (err) {
      toast.error("latest.yml inválido", {
        description: err instanceof Error ? err.message : "Não foi possível ler o arquivo.",
      });
    }
  };

  const onPickFile = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = ""; // permite reselecionar o mesmo arquivo
    if (!file) return;
    const text = await file.text();
    setYmlText(text);
    applyYml(text);
  };

  const mutation = useMutation({
    mutationFn: async () => {
      if (release) {
        await updateAppRelease(release.id, input);
        return;
      }
      await createAppRelease(input);
    },
    onSuccess: () => {
      toast.success(release ? "Versão atualizada" : "Versão criada");
      onSaved();
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível salvar", {
        description: errorMessage(err),
      });
      // Se a versão não está mais em rascunho/teste (ex.: bloqueada ou liberada
      // em outra aba), o formulário está desatualizado: fecha e recarrega a lista
      // para que o botão "Editar" desapareça e reflita o status real.
      if (isNonEditableReleaseError(err)) onStale();
    },
  });

  const update = <K extends keyof AppReleaseInput>(key: K, value: AppReleaseInput[K]) =>
    setInput((cur) => ({ ...cur, [key]: value }));

  const formErrors = releaseFormErrors(input);

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-3xl">
        <DialogHeader>
          <DialogTitle>{release ? `Editar ${release.version}` : "Nova versão"}</DialogTitle>
          <DialogDescription>
            A versão só chega ao Worker depois de aprovada e liberada explicitamente.
          </DialogDescription>
        </DialogHeader>

        <div className="rounded-lg border border-dashed border-border bg-muted/30 p-3">
          <div className="mb-2 flex items-center gap-2">
            <Upload className="h-4 w-4 text-primary" />
            <span className="text-sm font-medium">Importar do latest.yml</span>
          </div>
          <p className="mb-3 text-xs text-muted-foreground">
            Cole o conteúdo do <code>latest.yml</code> gerado pelo build (ou selecione o arquivo) para
            preencher versão, SHA-512, tamanho e as chaves do R2 automaticamente — sem digitação manual.
          </p>
          <Textarea
            value={ymlText}
            onChange={(e) => setYmlText(e.target.value)}
            rows={4}
            placeholder={"version: 1.0.6\npath: Porter-Music-Setup-1.0.6-x64.exe\nsha512: ...\nfiles:\n  - size: 123456789"}
            className="mb-2 font-mono text-xs"
          />
          <div className="flex flex-wrap items-center gap-2">
            <Button type="button" size="sm" onClick={() => applyYml(ymlText)}>
              Preencher campos
            </Button>
            <Button asChild type="button" size="sm" variant="outline">
              <label className="cursor-pointer">
                Selecionar arquivo .yml
                <input type="file" accept=".yml,.yaml,text/yaml" className="hidden" onChange={onPickFile} />
              </label>
            </Button>
          </div>
        </div>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Versão">
            <Input
              value={input.version ?? ""}
              onChange={(e) => update("version", e.target.value)}
              placeholder="1.0.6"
              disabled={Boolean(release)}
            />
          </Field>
          <Field label="Canal">
            <Input value={input.channel} disabled readOnly />
            <p className="text-xs text-muted-foreground">
              Fixo em <code>stable</code> — as chaves do R2 seguem o prefixo <code>stable/</code>.
            </p>
          </Field>
          <Field label="Título">
            <Input value={input.title} onChange={(e) => update("title", e.target.value)} />
          </Field>
          <Field label="Status inicial">
            <Select value={input.status} onValueChange={(v) => update("status", v as "draft" | "testing")}>
              <SelectTrigger>
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="draft">Rascunho</SelectItem>
                <SelectItem value="testing">Teste</SelectItem>
              </SelectContent>
            </Select>
          </Field>
          <Field label="Versão mínima">
            <Input value={input.minimum_version} onChange={(e) => update("minimum_version", e.target.value)} placeholder="1.0.0" />
          </Field>
          <Field label="Tamanho em bytes">
            <Input value={input.size_bytes} onChange={(e) => update("size_bytes", e.target.value)} inputMode="numeric" />
          </Field>
          <Field label="Manifest key">
            <Input value={input.manifest_key} onChange={(e) => update("manifest_key", e.target.value)} placeholder="stable/manifests/1.0.6.yml" />
          </Field>
          <Field label="Installer key">
            <Input value={input.installer_key} onChange={(e) => update("installer_key", e.target.value)} placeholder="stable/Porter-Music-Setup-1.0.6-x64.exe" />
          </Field>
          <Field label="Blockmap key">
            <Input value={input.blockmap_key} onChange={(e) => update("blockmap_key", e.target.value)} placeholder="stable/Porter-Music-Setup-1.0.6-x64.exe.blockmap" />
          </Field>
          <Field label="SHA-512">
            <Input value={input.sha512} onChange={(e) => update("sha512", e.target.value)} />
          </Field>
          <div className="flex items-center justify-between rounded-lg border border-border p-3 sm:col-span-2">
            <div>
              <Label>Atualização obrigatória</Label>
              <p className="text-xs text-muted-foreground">O Worker deve tratar como obrigatória quando liberada.</p>
            </div>
            <Switch checked={input.mandatory} onCheckedChange={(v) => update("mandatory", v)} />
          </div>
          <Field label="Notas da atualização" className="sm:col-span-2">
            <Textarea
              value={input.release_notes}
              onChange={(e) => update("release_notes", e.target.value)}
              rows={5}
              placeholder="Notas que aparecerão no histórico quando a versão estiver liberada."
            />
          </Field>
        </div>

        {formErrors.length > 0 && (
          <ul className="list-disc space-y-1 rounded-lg border border-destructive/40 bg-destructive/5 p-3 pl-6 text-xs text-destructive">
            {formErrors.map((err) => (
              <li key={err}>{err}</li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button
            onClick={() => mutation.mutate()}
            disabled={mutation.isPending || formErrors.length > 0}
          >
            {mutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
            Salvar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Field({
  label,
  children,
  className,
}: {
  label: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("grid gap-1.5", className)}>
      <Label>{label}</Label>
      {children}
    </div>
  );
}

function ConfirmActionDialog({
  confirm,
  reason,
  onReasonChange,
  busy,
  onCancel,
  onConfirm,
}: {
  confirm: { release: AppRelease; action: "approve" | "release" | "block" | "rollback" } | null;
  reason: string;
  onReasonChange: (reason: string) => void;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const action = confirm?.action;
  const title =
    action === "approve"
      ? "Aprovar versão?"
      : action === "release"
        ? "Liberar em produção?"
        : action === "rollback"
          ? "Executar rollback?"
          : "Bloquear versão?";
  const description =
    action === "release"
      ? "Após confirmar, os PCs passam a encontrar esta atualização ao abrir o Porter Music. A release anterior deste canal deixa de ser a atual."
      : action === "rollback"
        ? "A versão atual será substituída por esta versão anterior em uma única transação."
        : action === "block"
          ? "A versão bloqueada não será entregue pelo endpoint interno."
          : "A versão ficará pronta para liberação, mas ainda não será entregue ao Worker.";

  const release = confirm?.release ?? null;
  const contractErrors = release && action === "release" ? releaseContractErrors(release) : [];

  return (
    <AlertDialog open={Boolean(confirm)} onOpenChange={(open) => !open && onCancel()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{title}</AlertDialogTitle>
          <AlertDialogDescription>
            {release?.version} · {description}
          </AlertDialogDescription>
        </AlertDialogHeader>

        {action === "release" && release && (
          <div className="grid gap-2 rounded-lg border border-border bg-muted/30 p-3 text-sm">
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Versão</span>
              <span className="font-semibold">{release.version}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-muted-foreground">Canal</span>
              <span className="font-medium">{release.channel}</span>
            </div>
            <div className="grid gap-1 border-t border-border pt-2 font-mono text-xs">
              <div className="break-all">
                <span className="text-muted-foreground">manifest_key: </span>
                {release.manifest_key ?? "-"}
              </div>
              <div className="break-all">
                <span className="text-muted-foreground">installer_key: </span>
                {release.installer_key ?? "-"}
              </div>
              <div className="break-all">
                <span className="text-muted-foreground">blockmap_key: </span>
                {release.blockmap_key ?? "-"}
              </div>
            </div>
            <p className="text-xs text-muted-foreground">
              Confirme que os 3 objetos acima já foram enviados ao bucket R2 privado (
              <code>npm run release:publish:r2</code>). O Admin não acessa o R2 diretamente — a
              existência dos arquivos depende de confirmação operacional.
            </p>
          </div>
        )}

        {action === "release" && release && release.release_note?.status !== "published" && (
          <div className="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm">
            <div className="font-medium">Nota de atualização não publicada</div>
            <p className="mt-1 text-muted-foreground">
              Esta versão pode ser liberada, mas o app só terá nota oficial se houver uma nota publicada vinculada a ela.
            </p>
          </div>
        )}

        {action === "release" && contractErrors.length > 0 && (
          <ul className="list-disc space-y-1 rounded-lg border border-destructive/40 bg-destructive/5 p-3 pl-6 text-xs text-destructive">
            {contractErrors.map((err) => (
              <li key={err}>{err}</li>
            ))}
          </ul>
        )}

        {action === "block" && (
          <div className="grid gap-2">
            <Label>Motivo do bloqueio</Label>
            <Textarea value={reason} onChange={(e) => onReasonChange(e.target.value)} rows={3} />
          </div>
        )}

        <AlertDialogFooter>
          <AlertDialogCancel disabled={busy}>Cancelar</AlertDialogCancel>
          <AlertDialogAction
            onClick={(event) => {
              event.preventDefault();
              onConfirm();
            }}
            disabled={
              busy ||
              (action === "block" && !reason.trim()) ||
              (action === "release" && contractErrors.length > 0)
            }
            className={cn(action === "block" && "bg-destructive text-destructive-foreground hover:bg-destructive/90")}
          >
            {busy && <Loader2 className="h-4 w-4 animate-spin" />}
            Confirmar
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
