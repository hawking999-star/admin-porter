import { useEffect, useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  BellDot,
  CheckCircle2,
  AlertTriangle,
  CalendarClock,
  Building2,
  Inbox,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  StatCard,
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
import {
  countFeedbackStats,
  listFeedback,
  updateFeedbackStatus,
  FEEDBACK_TYPES,
  FEEDBACK_STATUSES,
  type Feedback,
  type FeedbackStatus,
} from "./queries";
import {
  FeedbackTypeIcon,
  FeedbackTypeBadge,
  OperatorAvatar,
} from "./components";

function unitText(f: Feedback) {
  if (!f.unit_name) return "-";
  const loc = [f.unit_city, f.unit_state].filter(Boolean).join("/");
  return loc ? `${f.unit_name} - ${loc}` : f.unit_name;
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

const STATUS_TRIGGER: Record<string, string> = {
  new: "bg-primary/10 text-primary hover:bg-primary/15",
  read: "bg-muted text-muted-foreground hover:bg-muted/70",
  resolved: "bg-success/30 text-success-foreground hover:bg-success/40",
};

function StatusSelect({
  value,
  onChange,
}: {
  value: FeedbackStatus;
  onChange: (v: FeedbackStatus) => void;
}) {
  return (
    <Select value={value} onValueChange={(v) => onChange(v as FeedbackStatus)}>
      <SelectTrigger
        onClick={(e) => e.stopPropagation()}
        className={cn(
          "h-8 w-[130px] rounded-full border-transparent px-3 text-xs font-semibold shadow-none",
          "transition-colors duration-200",
          STATUS_TRIGGER[value] ?? "bg-muted text-muted-foreground",
        )}
      >
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {FEEDBACK_STATUSES.map((s) => (
          <SelectItem key={s.value} value={s.value}>
            {s.label}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function FeedbackCard({
  feedback,
  onStatusChange,
}: {
  feedback: Feedback;
  onStatusChange: (status: FeedbackStatus) => void;
}) {
  const f = feedback;
  return (
    <Card className={cn("group flex gap-4 p-5 shadow-sm", "transition-all duration-200 hover:border-primary/40 hover:shadow-md")}>
      <FeedbackTypeIcon type={f.type} className="mt-0.5" />

      <div className="min-w-0 flex-1 space-y-2.5">
        <div className="flex flex-wrap items-center gap-2">
          <FeedbackTypeBadge type={f.type} />
          {f.status === "new" && (
            <span className="inline-flex items-center gap-1.5 text-xs font-medium text-primary">
              <span className="h-1.5 w-1.5 rounded-full bg-primary" />
              Novo
            </span>
          )}
          <span className="ml-auto whitespace-nowrap text-xs text-muted-foreground">
            {fmtDate(f.created_at)}
          </span>
        </div>

        <p className="whitespace-pre-wrap text-[15px] font-semibold leading-relaxed text-foreground">
          {f.message}
        </p>

        <div className="flex flex-wrap items-center gap-x-3 gap-y-2 pt-1">
          <div className="flex min-w-0 items-center gap-2">
            <OperatorAvatar name={f.operator_name} />
            <span className="truncate text-sm font-medium text-foreground">
              {f.operator_name ?? "-"}
            </span>
          </div>

          <span className="hidden text-border sm:inline">-</span>

          <div className="flex min-w-0 items-center gap-1.5 text-sm font-normal text-muted-foreground">
            <Building2 className="h-3.5 w-3.5 shrink-0" />
            <span className="truncate">{unitText(f)}</span>
          </div>

          <div className="ml-auto">
            <StatusSelect value={f.status} onChange={onStatusChange} />
          </div>
        </div>
      </div>
    </Card>
  );
}

function FeedbackCardSkeleton() {
  return (
    <Card className="flex gap-4 p-5 shadow-sm">
      <Skeleton className="h-10 w-10 rounded-xl" />
      <div className="flex-1 space-y-3">
        <div className="flex items-center justify-between">
          <Skeleton className="h-5 w-20 rounded-full" />
          <Skeleton className="h-4 w-24" />
        </div>
        <Skeleton className="h-5 w-3/4" />
        <div className="flex items-center justify-between">
          <Skeleton className="h-7 w-40 rounded-full" />
          <Skeleton className="h-8 w-[130px] rounded-full" />
        </div>
      </div>
    </Card>
  );
}

export function FeedbackPage() {
  const qc = useQueryClient();
  const [pageSize, setPageSize] = useState(25);
  const [search, setSearch] = useState("");
  const [typeFilter, setTypeFilter] = useState<string>("all");
  const [statusFilter, setStatusFilter] = useState<string>("all");
  const [page, setPage] = useState(1);
  const debouncedSearch = useDebounce(search, 350);

  useEffect(() => {
    setPage(1);
  }, [debouncedSearch, typeFilter, statusFilter]);

  const { data, isLoading, isError, error, isFetching, refetch } = useQuery({
    queryKey: ["feedback", page, pageSize, debouncedSearch, typeFilter, statusFilter],
    queryFn: () =>
      listFeedback({
        page,
        pageSize,
        search: debouncedSearch,
        type: typeFilter,
        status: statusFilter,
      }),
    staleTime: 30_000,
    placeholderData: keepPreviousData,
  });
  const statsQuery = useQuery({
    queryKey: ["feedback-stats"],
    queryFn: countFeedbackStats,
    staleTime: 30_000,
  });

  const mutation = useMutation({
    mutationFn: ({ id, status }: { id: string; status: FeedbackStatus }) =>
      updateFeedbackStatus(id, status),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feedback"] });
      qc.invalidateQueries({ queryKey: ["feedback-stats"] });
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao salvar";
      toast.error("Não foi possível atualizar", { description: msg });
    },
  });

  const rows = data?.rows ?? [];
  const total = data?.total ?? 0;
  const stats = statsQuery.data ?? { pending: 0, resolved: 0, problems: 0, today: 0 };
  const hasFilters = Boolean(debouncedSearch.trim()) || typeFilter !== "all" || statusFilter !== "all";
  const clearFilters = () => {
    setSearch("");
    setTypeFilter("all");
    setStatusFilter("all");
  };

  return (
    <>
      <PageHeader title="Feedback" description="Retornos enviados pelos operadores dentro do app." />

      <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatCard icon={<BellDot className="h-5 w-5" />} label="Pendentes" value={stats.pending} hint="Aguardando leitura" iconClassName="bg-warning/15 text-warning-foreground" loading={statsQuery.isLoading} />
        <StatCard icon={<CheckCircle2 className="h-5 w-5" />} label="Resolvidos" value={stats.resolved} hint="Já respondidos" iconClassName="bg-success/30 text-success-foreground" loading={statsQuery.isLoading} />
        <StatCard icon={<AlertTriangle className="h-5 w-5" />} label="Problemas" value={stats.problems} hint="Relatos de erro" iconClassName="bg-destructive/10 text-destructive" loading={statsQuery.isLoading} />
        <StatCard icon={<CalendarClock className="h-5 w-5" />} label="Recebidos hoje" value={stats.today} hint="Nas últimas horas" iconClassName="bg-primary/10 text-primary" loading={statsQuery.isLoading} />
      </div>

      <FilterBar resultText={!isError ? `${rows.length} de ${total}` : undefined}>
        <SearchInput
          value={search}
          onChange={setSearch}
          placeholder="Buscar na mensagem..."
        />

        <Select value={typeFilter} onValueChange={setTypeFilter}>
          <SelectTrigger className="h-10 w-[170px] rounded-lg">
            <SelectValue placeholder="Tipo" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os tipos</SelectItem>
            {FEEDBACK_TYPES.map((t) => (
              <SelectItem key={t.value} value={t.value}>{t.label}</SelectItem>
            ))}
          </SelectContent>
        </Select>

        <Select value={statusFilter} onValueChange={setStatusFilter}>
          <SelectTrigger className="h-10 w-[170px] rounded-lg">
            <SelectValue placeholder="Status" />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="all">Todos os status</SelectItem>
            {FEEDBACK_STATUSES.map((s) => (
              <SelectItem key={s.value} value={s.value}>{s.label}</SelectItem>
            ))}
          </SelectContent>
        </Select>

        {hasFilters && <Button variant="outline" onClick={clearFilters}>Limpar filtros</Button>}
      </FilterBar>

      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar os feedbacks."
            description={(error as Error)?.message}
            action={<RetryButton onClick={() => refetch()} disabled={isFetching} />}
          />
        </Card>
      ) : (
        <div className="space-y-3">
          {isLoading && Array.from({ length: 4 }).map((_, i) => <FeedbackCardSkeleton key={i} />)}

          {!isLoading && rows.length === 0 && (
            <Card className="shadow-sm">
              <EmptyState
                icon={<Inbox className="h-6 w-6" />}
                title={hasFilters ? "Nenhum feedback encontrado." : "Nenhum feedback por aqui ainda."}
                description={hasFilters ? "Ajuste ou limpe os filtros para ampliar a busca." : "Quando operadores enviarem feedbacks pelo app, eles aparecerão nesta lista."}
                action={hasFilters ? <Button variant="outline" size="sm" onClick={clearFilters}>Limpar filtros</Button> : undefined}
              />
            </Card>
          )}

          {!isLoading && rows.map((f) => (
            <FeedbackCard
              key={f.id}
              feedback={f}
              onStatusChange={(status) => mutation.mutate({ id: f.id, status })}
            />
          ))}
        </div>
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
