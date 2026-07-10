import { useMemo, useRef, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Puzzle,
  Upload,
  Download,
  Clock,
  ShieldBan,
  Building2,
  Globe,
  ListChecks,
  FileText,
  Hash,
  CheckCircle2,
  PencilRuler,
  Layers,
  FileSpreadsheet,
  FileUp,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  StatCard,
  StatusBadge,
  EmptyState,
  ErrorState,
  RetryButton,
  SearchInput,
  FilterBar,
  PaginationFooter,
} from "@/components/shared";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useDebounce } from "@/hooks/useDebounce";
import { listUnitOptions, unitLabel } from "@/features/usuarios/queries";
import {
  countChallengeStats,
  listChallenges,
  challengeCsvTemplate,
  challengeKindLabel,
  challengeStatusBadge,
  CHALLENGE_STATUSES,
  CHALLENGE_KINDS,
  type Challenge,
} from "./queries";

const KIND_ICON: Record<string, typeof ListChecks> = {
  multiple_choice: ListChecks,
  text: FileText,
  numeric: Hash,
};

function unitText(c: Challenge) {
  if (!c.unit_name) return "Global";
  const loc = [c.unit_city, c.unit_state].filter(Boolean).join("/");
  return loc ? `${c.unit_name} — ${loc}` : c.unit_name;
}

function fmtDate(iso: string) {
  try {
    return new Date(iso).toLocaleString("pt-BR", {
      day: "2-digit",
      month: "2-digit",
      year: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    });
  } catch {
    return iso;
  }
}

function fmtSeconds(s: number | null) {
  if (!s || s <= 0) return "—";
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return sec ? `${m}min ${sec}s` : `${m}min`;
}

function downloadCsvTemplate() {
  const blob = new Blob([challengeCsvTemplate()], { type: "text/csv;charset=utf-8;" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = "modelo-desafio-multipla-escolha.csv";
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

/* --------------------------- Diálogo de upload ---------------------------- */

type UnitOption = { id: string; name: string; city: string | null; state: string | null; code: string | null };

function UploadChallengeDialog({
  open,
  onOpenChange,
  units,
  unitsLoading,
}: {
  open: boolean;
  onOpenChange: (v: boolean) => void;
  units: UnitOption[];
  unitsLoading: boolean;
}) {
  const [unitId, setUnitId] = useState<string>("");
  const [file, setFile] = useState<File | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  function pickFile(f: File | null) {
    if (!f) return setFile(null);
    const ok = /\.(csv|pdf)$/i.test(f.name) || f.type === "text/csv" || f.type === "application/pdf";
    if (!ok) {
      toast.error("Formato não suportado. Envie um arquivo CSV ou PDF.");
      return;
    }
    setFile(f);
  }

  function submit() {
    if (!unitId) return toast.error("Escolha o condomínio do desafio.");
    if (!file) return toast.error("Selecione um arquivo CSV ou PDF.");
    // Processamento ainda não implementado — só validação visual por enquanto.
    toast.info("Arquivo recebido. O processamento do envio entra no ar em breve.");
    onOpenChange(false);
    setFile(null);
    setUnitId("");
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-lg">
        <DialogHeader>
          <DialogTitle>Enviar desafio</DialogTitle>
          <DialogDescription>
            Os desafios são por condomínio. Envie uma planilha (CSV) ou um PDF de múltipla escolha para o
            condomínio escolhido. Por enquanto aceitamos apenas o tipo <strong>múltipla escolha</strong>.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          {/* Condomínio de destino */}
          <div className="space-y-1.5">
            <label className="text-xs font-semibold text-muted-foreground">Condomínio</label>
            <Select value={unitId} onValueChange={setUnitId}>
              <SelectTrigger className="h-10 w-full rounded-lg">
                <SelectValue placeholder={unitsLoading ? "Carregando condomínios…" : "Selecione o condomínio"} />
              </SelectTrigger>
              <SelectContent>
                {units.map((u) => (
                  <SelectItem key={u.id} value={u.id}>
                    {unitLabel(u)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          {/* Exemplo CSV */}
          <div className="flex items-center justify-between gap-3 rounded-lg border border-border bg-muted/30 p-3">
            <div className="flex min-w-0 items-center gap-2.5">
              <FileSpreadsheet className="h-5 w-5 shrink-0 text-primary" />
              <div className="min-w-0 text-xs">
                <p className="font-semibold text-foreground">Não sabe o formato?</p>
                <p className="text-muted-foreground">Baixe a planilha de exemplo e preencha nela.</p>
              </div>
            </div>
            <Button size="sm" variant="outline" className="shrink-0" onClick={downloadCsvTemplate}>
              <Download className="h-4 w-4" /> Exemplo CSV
            </Button>
          </div>

          {/* Área de upload */}
          <input
            ref={inputRef}
            type="file"
            accept=".csv,text/csv,application/vnd.ms-excel,.pdf,application/pdf"
            className="hidden"
            onChange={(e) => pickFile(e.target.files?.[0] ?? null)}
          />
          {file ? (
            <div className="flex items-center justify-between gap-3 rounded-lg border border-primary/40 bg-primary/5 p-3 text-sm">
              <span className="inline-flex min-w-0 items-center gap-2">
                <FileUp className="h-4 w-4 shrink-0 text-primary" />
                <span className="truncate font-medium">{file.name}</span>
              </span>
              <button
                type="button"
                className="shrink-0 text-muted-foreground hover:text-destructive"
                onClick={() => setFile(null)}
                aria-label="Remover arquivo"
              >
                <X className="h-4 w-4" />
              </button>
            </div>
          ) : (
            <button
              type="button"
              onClick={() => inputRef.current?.click()}
              className="flex w-full flex-col items-center justify-center gap-1.5 rounded-lg border border-dashed border-border bg-background px-4 py-6 text-center text-sm text-muted-foreground transition-colors hover:border-primary/50 hover:bg-accent/30"
            >
              <Upload className="h-6 w-6 text-muted-foreground" />
              <span className="font-medium text-foreground">Clique para escolher o arquivo</span>
              <span className="text-xs">Aceita CSV ou PDF</span>
            </button>
          )}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button onClick={submit}>
            <Upload className="h-4 w-4" /> Enviar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

/* ------------------------------ Card / lista ------------------------------ */

function ChallengeCard({ challenge }: { challenge: Challenge }) {
  const c = challenge;
  const badge = challengeStatusBadge(c.status);
  const KindIcon = KIND_ICON[c.kind] ?? Puzzle;
  return (
    <Card
      className={cn(
        "group flex flex-col gap-3 p-5 shadow-sm",
        "transition-all duration-200 hover:border-primary/40 hover:shadow-md",
      )}
    >
      <div className="flex items-start gap-3">
        <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
          <KindIcon className="h-5 w-5" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="min-w-0 truncate font-display text-[15px] font-semibold text-foreground">
              {c.title}
            </h3>
            <StatusBadge label={badge.label} tone={badge.tone} />
          </div>
          <p className="mt-1 line-clamp-2 text-sm text-muted-foreground">{c.prompt}</p>
        </div>
      </div>

      <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 border-t border-border/70 pt-3 text-xs text-muted-foreground">
        <span className="inline-flex items-center gap-1.5">
          <PencilRuler className="h-3.5 w-3.5" /> {challengeKindLabel(c.kind)}
        </span>
        <span className="inline-flex items-center gap-1.5">
          <Clock className="h-3.5 w-3.5" /> {fmtSeconds(c.duration_seconds)}
        </span>
        {c.block_seconds ? (
          <span className="inline-flex items-center gap-1.5">
            <ShieldBan className="h-3.5 w-3.5" /> bloqueio {fmtSeconds(c.block_seconds)}
          </span>
        ) : null}
        <span className="inline-flex items-center gap-1.5">
          {c.unit_name ? <Building2 className="h-3.5 w-3.5" /> : <Globe className="h-3.5 w-3.5" />}
          <span className="truncate">{unitText(c)}</span>
        </span>
        <span className="ml-auto">{fmtDate(c.created_at)}</span>
      </div>
    </Card>
  );
}

function ChallengeCardSkeleton() {
  return (
    <Card className="flex flex-col gap-3 p-5 shadow-sm">
      <div className="flex items-start gap-3">
        <Skeleton className="h-10 w-10 rounded-lg" />
        <div className="flex-1 space-y-2">
          <Skeleton className="h-4 w-2/3" />
          <Skeleton className="h-3 w-full" />
          <Skeleton className="h-3 w-4/5" />
        </div>
      </div>
      <Skeleton className="h-3 w-1/2" />
    </Card>
  );
}

const PAGE_SIZE = 12;

export function ChallengesPage() {
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [kindFilter, setKindFilter] = useState<string>("all");
  const [unitFilter, setUnitFilter] = useState<string>("all");
  const [page, setPage] = useState(1);
  const [uploadOpen, setUploadOpen] = useState(false);
  const debouncedSearch = useDebounce(search, 300);

  const units = useQuery({
    queryKey: ["challenges", "units"],
    queryFn: listUnitOptions,
    staleTime: 60_000,
  });

  const stats = useQuery({
    queryKey: ["challenges", "stats"],
    queryFn: countChallengeStats,
    staleTime: 30_000,
  });

  const filters = useMemo(
    () => ({
      page,
      pageSize: PAGE_SIZE,
      search: debouncedSearch,
      status: statusFilter,
      kind: kindFilter,
      unit: unitFilter,
    }),
    [page, debouncedSearch, statusFilter, kindFilter, unitFilter],
  );

  const list = useQuery({
    queryKey: ["challenges", "list", filters],
    queryFn: () => listChallenges(filters),
    staleTime: 15_000,
  });

  const rows = list.data?.rows ?? [];
  const total = list.data?.total ?? 0;
  const hasFilter = statusFilter !== "all" || kindFilter !== "all" || unitFilter !== "all" || Boolean(debouncedSearch);

  function resetToFirstPage<T>(setter: (v: T) => void) {
    return (v: T) => {
      setter(v);
      setPage(1);
    };
  }

  return (
    <div>
      <PageHeader
        eyebrow="Engajamento"
        title="Desafios"
        description="Desafios por condomínio que aparecem para os operadores durante o turno. Visualização inicial — o processamento dos envios chega em breve."
        action={
          <Button onClick={() => setUploadOpen(true)}>
            <Upload className="h-4 w-4" /> Enviar desafio
          </Button>
        }
      />

      <div className="mb-5 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <StatCard
          icon={<Layers className="h-5 w-5" />}
          label="Total de desafios"
          value={stats.data?.total ?? 0}
          loading={stats.isLoading}
          active={statusFilter === "all"}
          onClick={() => resetToFirstPage(setStatusFilter)("all")}
        />
        <StatCard
          icon={<CheckCircle2 className="h-5 w-5" />}
          iconClassName="bg-success/20 text-success-foreground"
          label="Ativos"
          value={stats.data?.active ?? 0}
          loading={stats.isLoading}
          active={statusFilter === "active"}
          onClick={() => resetToFirstPage(setStatusFilter)("active")}
        />
        <StatCard
          icon={<PencilRuler className="h-5 w-5" />}
          iconClassName="bg-muted text-muted-foreground"
          label="Rascunhos"
          value={stats.data?.draft ?? 0}
          loading={stats.isLoading}
          active={statusFilter === "draft"}
          onClick={() => resetToFirstPage(setStatusFilter)("draft")}
        />
        <StatCard
          icon={<ListChecks className="h-5 w-5" />}
          label="Aplicações"
          value={stats.data?.applications ?? 0}
          hint="Registros em challenge_logs"
          loading={stats.isLoading}
        />
      </div>

      <FilterBar resultText={list.isLoading ? "Carregando…" : `${total} desafio(s)`}>
        <SearchInput value={search} onChange={resetToFirstPage(setSearch)} placeholder="Buscar por título ou enunciado…" />
        <Select value={unitFilter} onValueChange={resetToFirstPage(setUnitFilter)}>
          <SelectTrigger className="h-10 w-[190px] rounded-lg">
            <SelectValue placeholder="Condomínio" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os condomínios</SelectItem>
            <SelectItem value="global">Globais (sem condomínio)</SelectItem>
            {(units.data ?? []).map((u) => (
              <SelectItem key={u.id} value={u.id}>
                {unitLabel(u)}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={statusFilter} onValueChange={resetToFirstPage(setStatusFilter)}>
          <SelectTrigger className="h-10 w-[150px] rounded-lg">
            <SelectValue placeholder="Status" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os status</SelectItem>
            {CHALLENGE_STATUSES.map((s) => (
              <SelectItem key={s.value} value={s.value}>
                {s.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={kindFilter} onValueChange={resetToFirstPage(setKindFilter)}>
          <SelectTrigger className="h-10 w-[160px] rounded-lg">
            <SelectValue placeholder="Tipo" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os tipos</SelectItem>
            {CHALLENGE_KINDS.map((k) => (
              <SelectItem key={k.value} value={k.value}>
                {k.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </FilterBar>

      {list.isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar os desafios."
            description={(list.error as Error)?.message}
            action={<RetryButton onClick={() => list.refetch()} disabled={list.isFetching} />}
          />
        </Card>
      ) : list.isLoading ? (
        <div className="grid gap-3 md:grid-cols-2">
          {Array.from({ length: 4 }).map((_, i) => (
            <ChallengeCardSkeleton key={i} />
          ))}
        </div>
      ) : rows.length === 0 ? (
        <Card className="shadow-sm">
          <EmptyState
            icon={<Puzzle className="h-6 w-6" />}
            title={hasFilter ? "Nenhum desafio para esse filtro." : "Ainda não há desafios cadastrados."}
            description={
              hasFilter
                ? "Ajuste os filtros para ver outros desafios."
                : "Esta área já está ligada ao banco. Envie um desafio por condomínio para começar."
            }
            action={
              hasFilter ? undefined : (
                <Button variant="outline" onClick={() => setUploadOpen(true)}>
                  <Upload className="h-4 w-4" /> Enviar desafio
                </Button>
              )
            }
          />
        </Card>
      ) : (
        <div className="grid gap-3 md:grid-cols-2">
          {rows.map((c) => (
            <ChallengeCard key={c.id} challenge={c} />
          ))}
        </div>
      )}

      {!list.isError && total > 0 && (
        <PaginationFooter
          page={page}
          pageSize={PAGE_SIZE}
          total={total}
          isLoading={list.isLoading || list.isFetching}
          onPageChange={setPage}
        />
      )}

      <UploadChallengeDialog
        open={uploadOpen}
        onOpenChange={setUploadOpen}
        units={units.data ?? []}
        unitsLoading={units.isLoading}
      />
    </div>
  );
}
