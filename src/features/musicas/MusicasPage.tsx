import { useEffect, useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  Search,
  Music,
  RefreshCw,
  ExternalLink,
  Copy,
  Check,
  X,
  Eye,
  Clock,
  CheckCircle2,
  XCircle,
  ListMusic,
  Building2,
  Inbox,
  Save,
  Download,
  Loader2,
  AlertTriangle,
  Users,
  UserRound,
  Library,
  Pencil,
  Trash2,
  Archive,
  ListOrdered,
  History,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Card } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/components/ui/sheet";
import {
  archiveSecondaryPlaylist,
  countPlaylistStats,
  listOperatorMusicLibraryPage,
  listPlaylists,
  removePlaylistTrack,
  renameMusicPlaylist,
  retryPlaylistImport,
  reviewPlaylist,
  playlistTypeLabel,
  type MusicLibraryPlaylist,
  type MusicTrack,
  type OperatorMusicLibrary,
  type OperatorRequestHistory,
  type Playlist,
} from "./queries";
import { PaginationFooter, StatCard } from "@/components/shared";
import { useDebounce } from "@/hooks/useDebounce";
import {
  OperatorAvatar,
  PlatformIcon,
  StatusPill,
  FilterChip,
  detectPlatform,
  platformMeta,
  buildEmbed,
  SpotifyIcon,
  type Platform,
} from "./components";

/* --------------------------------- Helpers -------------------------------- */

function unitText(p: Playlist) {
  if (!p.unit_name) return "—";
  const loc = [p.unit_city, p.unit_state].filter(Boolean).join("/");
  return loc ? `${p.unit_name} — ${loc}` : p.unit_name;
}

function operatorUnitText(operator: OperatorMusicLibrary) {
  if (!operator.unit_name) return "—";
  const loc = [operator.unit_city, operator.unit_state].filter(Boolean).join("/");
  return loc ? `${operator.unit_name} — ${loc}` : operator.unit_name;
}

function fmtDate(iso: string | null) {
  if (!iso) return "—";
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

function relOrDate(iso: string | null) {
  if (!iso) return "—";
  const diff = Date.now() - new Date(iso).getTime();
  const min = Math.floor(diff / 60000);
  if (min < 1) return "agora";
  if (min < 60) return `há ${min} min`;
  const h = Math.floor(min / 60);
  if (h < 24) return `há ${h}h`;
  const d = Math.floor(h / 24);
  if (d < 7) return `há ${d}d`;
  return fmtDate(iso);
}

function durationText(ms: number | null) {
  if (!ms || ms <= 0) return "—";
  const totalSeconds = Math.round(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

const TRACK_STATUS_PT: Record<string, string> = {
  ready: "Pronta",
  available: "Disponível",
  processing: "Processando",
  pending: "Pendente",
  failed: "Falhou",
  unavailable: "Indisponível",
  archived: "Arquivada",
};

function trackStatusLabel(status: string | null | undefined) {
  if (!status) return "—";
  return TRACK_STATUS_PT[status] ?? status.replace(/_/g, " ");
}

function playlistLibraryError(p: MusicLibraryPlaylist): string | null {
  const jobMessage =
    typeof p.latest_job?.error_message === "string"
      ? p.latest_job.error_message
      : typeof p.latest_job?.error === "string"
        ? p.latest_job.error
        : null;
  return p.error_message?.trim() || jobMessage?.trim() || null;
}

function operatorTotals(operator: OperatorMusicLibrary) {
  const principal = operator.playlists.filter((p) => p.type === "principal").length;
  const secondary = operator.playlists.filter((p) => p.type === "secondary").length;
  const tracks = operator.playlists.reduce((sum, p) => sum + (p.track_count ?? p.tracks.length), 0);
  const failed = operator.playlists.filter((p) => p.import_status === "failed").length;
  const processing = operator.playlists.filter((p) => p.import_status === "processing").length;
  return { principal, secondary, tracks, failed, processing };
}

function playlistImportError(p: Playlist): string | null {
  return (
    p.error_message?.trim() ||
    p.download?.error_message?.trim() ||
    p.download?.error?.trim() ||
    null
  );
}

function technicalErrorText(p: Playlist): string | null {
  const code = p.error_code || p.download?.error_code;
  const details = p.error_details || p.download?.error_details;
  const parts = [
    code ? `Código: ${code}` : null,
    details ? `Detalhes: ${JSON.stringify(details)}` : null,
  ].filter(Boolean);
  return parts.length ? parts.join("\n") : null;
}

const NOTES_KEY = "ptm:playlist-notes";
function loadNotes(): Record<string, string> {
  try {
    return JSON.parse(localStorage.getItem(NOTES_KEY) || "{}");
  } catch {
    return {};
  }
}

async function copy(text: string) {
  try {
    await navigator.clipboard.writeText(text);
    toast.success("Link copiado");
  } catch {
    toast.error("Não foi possível copiar");
  }
}

/* --------------------------------- Página --------------------------------- */

export function MusicasPage() {
  const qc = useQueryClient();
  const [activeArea, setActiveArea] = useState<"requests" | "library">("requests");
  const [search, setSearch] = useState("");
  const [librarySearch, setLibrarySearch] = useState("");
  const [requestsPage, setRequestsPage] = useState(1);
  const [libraryPage, setLibraryPage] = useState(1);
  const [statusFilter, setStatusFilter] = useState("all");
  const [typeFilter, setTypeFilter] = useState("all");
  const [platformFilter, setPlatformFilter] = useState("all");
  const [dateFilter, setDateFilter] = useState("all");
  const [operatorRequestFilter, setOperatorRequestFilter] = useState<string | null>(null);
  const requestsPageSize = 20;
  const libraryPageSize = 12;
  const debouncedSearch = useDebounce(search, 350);
  const debouncedLibrarySearch = useDebounce(librarySearch, 350);

  const [detailId, setDetailId] = useState<string | null>(null);
  const [selectedOperatorId, setSelectedOperatorId] = useState<string | null>(null);
  const [selectedPlaylistId, setSelectedPlaylistId] = useState<string | null>(null);
  const [renameTarget, setRenameTarget] = useState<MusicLibraryPlaylist | null>(null);
  const [renameName, setRenameName] = useState("");
  const [removeTrackTarget, setRemoveTrackTarget] = useState<{
    playlist: MusicLibraryPlaylist;
    track: MusicTrack;
  } | null>(null);
  const [archiveTarget, setArchiveTarget] = useState<MusicLibraryPlaylist | null>(null);
  const [confirmState, setConfirmState] = useState<{ id: string; action: "approve" | "reject" } | null>(
    null,
  );
  const [reason, setReason] = useState("");
  const [notes, setNotes] = useState<Record<string, string>>(() => loadNotes());
  const [noteDraft, setNoteDraft] = useState("");

  useEffect(() => {
    setRequestsPage(1);
  }, [debouncedSearch, statusFilter, typeFilter, platformFilter, dateFilter, operatorRequestFilter]);

  useEffect(() => {
    setLibraryPage(1);
  }, [debouncedLibrarySearch]);

  const { data, isLoading, isError, error, refetch, isFetching } = useQuery({
    queryKey: [
      "playlists",
      requestsPage,
      requestsPageSize,
      debouncedSearch,
      statusFilter,
      typeFilter,
      platformFilter,
      dateFilter,
      operatorRequestFilter,
    ],
    queryFn: () =>
      listPlaylists({
        page: requestsPage,
        pageSize: requestsPageSize,
        search: debouncedSearch,
        operatorId: operatorRequestFilter,
        status: statusFilter,
        type: typeFilter,
        platform: platformFilter,
        date: dateFilter as "all" | "today" | "7d" | "30d",
      }),
    staleTime: 30_000,
    enabled: activeArea === "requests",
    refetchInterval: (query) => {
      const rows = query.state.data?.rows;
      const active = rows?.some(
        (p) =>
          p.import_status === "processing" ||
          p.download?.status === "queued" ||
          p.download?.status === "running",
      );
      return active ? 5000 : false;
    },
  });
  const statsQuery = useQuery({
    queryKey: ["playlist-stats"],
    queryFn: countPlaylistStats,
    staleTime: 30_000,
  });
  const libraryQuery = useQuery({
    queryKey: ["music-library", libraryPage, libraryPageSize, debouncedLibrarySearch],
    queryFn: () =>
      listOperatorMusicLibraryPage({
        page: libraryPage,
        pageSize: libraryPageSize,
        search: debouncedLibrarySearch,
      }),
    staleTime: 30_000,
    enabled: activeArea === "library",
    refetchInterval: (query) => {
      const rows = query.state.data?.rows;
      const active = rows?.some((operator) =>
        operator.playlists.some((p) => p.import_status === "processing"),
      );
      return active ? 5000 : false;
    },
  });

  const toggle = (cur: string, val: string, set: (v: string) => void) =>
    set(cur === val ? "all" : val);
  const requestHasFilters =
    Boolean(debouncedSearch.trim()) ||
    statusFilter !== "all" ||
    typeFilter !== "all" ||
    platformFilter !== "all" ||
    dateFilter !== "all" ||
    Boolean(operatorRequestFilter);
  const clearRequestFilters = () => {
    setSearch("");
    setStatusFilter("all");
    setTypeFilter("all");
    setPlatformFilter("all");
    setDateFilter("all");
    setOperatorRequestFilter(null);
  };

  const invalidateMusic = () => {
    qc.invalidateQueries({ queryKey: ["playlists"] });
    qc.invalidateQueries({ queryKey: ["playlist-stats"] });
    qc.invalidateQueries({ queryKey: ["music-library"] });
  };

  const mutation = useMutation({
    mutationFn: ({ id, action, reason }: { id: string; action: "approve" | "reject"; reason?: string }) =>
      reviewPlaylist(id, action, reason),
    onSuccess: (_d, vars) => {
      invalidateMusic();
      toast.success(vars.action === "approve" ? "Playlist aprovada" : "Playlist rejeitada");
      setConfirmState(null);
      setReason("");
    },
    onError: (err: unknown) => {
      const raw = err instanceof Error ? err.message : "Erro ao salvar";
      const msg = raw.includes("already_reviewed")
        ? "Essa playlist já foi decidida. Atualize a lista."
        : raw;
      toast.error("Não foi possível salvar", { description: msg });
      invalidateMusic();
    },
  });

  const retryMutation = useMutation({
    mutationFn: ({ id }: { id: string }) => retryPlaylistImport(id),
    onSuccess: () => {
      invalidateMusic();
      toast.success("Importação reenfileirada");
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao reenfileirar importação";
      toast.error("Não foi possível tentar novamente", { description: msg });
      invalidateMusic();
    },
  });

  const renameMutation = useMutation({
    mutationFn: ({ id, name }: { id: string; name: string }) => renameMusicPlaylist(id, name),
    onSuccess: () => {
      invalidateMusic();
      toast.success("Playlist renomeada");
      setRenameTarget(null);
      setRenameName("");
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao renomear playlist";
      toast.error("Não foi possível renomear", { description: msg });
    },
  });

  const removeTrackMutation = useMutation({
    mutationFn: ({ playlistTrackId }: { playlistTrackId: string }) => removePlaylistTrack(playlistTrackId),
    onSuccess: () => {
      invalidateMusic();
      toast.success("Música removida da playlist");
      setRemoveTrackTarget(null);
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao remover música";
      toast.error("Não foi possível remover", { description: msg });
    },
  });

  const archiveMutation = useMutation({
    mutationFn: ({ id }: { id: string }) => archiveSecondaryPlaylist(id),
    onSuccess: () => {
      invalidateMusic();
      toast.success("Playlist secundária arquivada");
      setArchiveTarget(null);
      setSelectedPlaylistId(null);
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao arquivar playlist";
      toast.error("Não foi possível arquivar", { description: msg });
    },
  });

  const playlists = data?.rows ?? [];
  const playlistsTotal = data?.total ?? 0;
  const withPlatform = useMemo(
    () => playlists.map((p) => ({ p, platform: detectPlatform(p.source_url) })),
    [playlists],
  );
  const filtered = withPlatform;
  const stats = statsQuery.data ?? {
    pending: 0,
    approved: 0,
    rejected: 0,
    importFailed: 0,
    today: 0,
    week: 0,
  };

  const libraryStats = useMemo(() => {
    const rows = libraryQuery.data?.rows ?? [];
    return {
      operators: libraryQuery.data?.total ?? 0,
      withPlaylists: rows.filter((operator) => operator.playlists.length > 0).length,
      totalTracks: rows.reduce((sum, operator) => sum + operatorTotals(operator).tracks, 0),
      failedImports: rows.reduce((sum, operator) => sum + operatorTotals(operator).failed, 0),
    };
  }, [libraryQuery.data]);

  const operators = libraryQuery.data?.rows ?? [];
  const operatorsTotal = libraryQuery.data?.total ?? 0;

  const detail = useMemo(
    () => playlists.find((p) => p.id === detailId) ?? null,
    [playlists, detailId],
  );
  const selectedOperator = useMemo(
    () => operators.find((operator) => operator.id === selectedOperatorId) ?? null,
    [operators, selectedOperatorId],
  );
  const confirmPlaylist = useMemo(
    () => playlists.find((p) => p.id === confirmState?.id) ?? null,
    [playlists, confirmState],
  );

  const saveNote = (id: string) => {
    const next = { ...notes, [id]: noteDraft };
    setNotes(next);
    try {
      localStorage.setItem(NOTES_KEY, JSON.stringify(next));
      toast.success("Observações salvas");
    } catch {
      toast.error("Não foi possível salvar as observações");
    }
  };

  const openDetail = (p: Playlist) => {
    setDetailId(p.id);
    setNoteDraft(notes[p.id] ?? "");
  };

  const askApprove = (id: string) => setConfirmState({ id, action: "approve" });
  const askReject = (id: string) => {
    setReason("");
    setConfirmState({ id, action: "reject" });
  };

  return (
    <>
      <PageHeader
        title="Músicas"
        description="Central de aprovação das playlists enviadas pelos operadores."
        action={
          <Button
            variant="outline"
            size="sm"
            onClick={() => {
              refetch();
              libraryQuery.refetch();
            }}
            disabled={isFetching || libraryQuery.isFetching}
          >
            <RefreshCw className={cn("h-4 w-4", (isFetching || libraryQuery.isFetching) && "animate-spin")} />
            Atualizar
          </Button>
        }
      />

      <div className="mb-6 inline-flex flex-wrap items-center gap-1 rounded-lg border border-border bg-muted/50 p-1">
        <AreaButton
          active={activeArea === "requests"}
          icon={<Inbox className="h-4 w-4" />}
          onClick={() => setActiveArea("requests")}
        >
          Solicitações de playlists
        </AreaButton>
        <AreaButton
          active={activeArea === "library"}
          icon={<Library className="h-4 w-4" />}
          onClick={() => setActiveArea("library")}
        >
          Biblioteca dos Operadores
        </AreaButton>
      </div>

      {/* Cards de resumo — 4 principais (clique filtra a lista) */}
      {activeArea === "requests" && (
        <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <StatCard
            icon={<Clock className="h-5 w-5" />}
            iconClassName="bg-warning/20 text-warning-foreground"
            label="Pendentes"
            value={stats.pending}
            hint="Aguardando aprovação"
            active={statusFilter === "pending"}
            onClick={() => toggle(statusFilter, "pending", setStatusFilter)}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<CheckCircle2 className="h-5 w-5" />}
            iconClassName="bg-success/30 text-success-foreground"
            label="Aprovadas"
            value={stats.approved}
            hint={`${stats.today} enviadas hoje`}
            active={statusFilter === "approved"}
            onClick={() => toggle(statusFilter, "approved", setStatusFilter)}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<XCircle className="h-5 w-5" />}
            iconClassName="bg-destructive/10 text-destructive"
            label="Rejeitadas"
            value={stats.rejected}
            active={statusFilter === "rejected"}
            onClick={() => toggle(statusFilter, "rejected", setStatusFilter)}
            loading={statsQuery.isLoading}
          />
          <StatCard
            icon={<AlertTriangle className="h-5 w-5" />}
            iconClassName="bg-destructive/10 text-destructive"
            label="Importações com erro"
            value={stats.importFailed}
            active={statusFilter === "import_failed"}
            onClick={() => toggle(statusFilter, "import_failed", setStatusFilter)}
            loading={statsQuery.isLoading}
          />
        </div>
      )}

      {/* Busca + filtros rápidos */}
      {activeArea === "requests" ? (
        <>
      <div className="mb-5 space-y-3">
        <div className="flex flex-wrap items-center gap-3">
          <div className="relative w-full max-w-md">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
            <Input
              placeholder="Buscar por operador, condomínio, link, status, erro..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="h-10 rounded-lg pl-9"
            />
          </div>
          <span className="ml-auto text-sm text-muted-foreground">
            {filtered.length} de {playlistsTotal}
          </span>
          {requestHasFilters && (
            <Button variant="outline" size="sm" onClick={clearRequestFilters}>
              Limpar filtros
            </Button>
          )}
        </div>

        {/* Status é filtrado pelos cards acima; aqui ficam só tipo, plataforma e período */}
        <div className="flex flex-wrap items-center gap-1.5">
          <FilterChip active={typeFilter === "principal"} onClick={() => toggle(typeFilter, "principal", setTypeFilter)}>
            Principal
          </FilterChip>
          <FilterChip active={typeFilter === "secondary"} onClick={() => toggle(typeFilter, "secondary", setTypeFilter)}>
            Secundária
          </FilterChip>

          <span className="mx-1.5 h-5 w-px bg-border" />

          <FilterChip active={platformFilter === "spotify"} onClick={() => toggle(platformFilter, "spotify", setPlatformFilter)} icon={<SpotifyIcon />}>
            Spotify
          </FilterChip>
          <FilterChip active={platformFilter === "youtube"} onClick={() => toggle(platformFilter, "youtube", setPlatformFilter)} icon={<Music />}>
            YouTube
          </FilterChip>

          <span className="mx-1.5 h-5 w-px bg-border" />

          <FilterChip active={dateFilter === "today"} onClick={() => toggle(dateFilter, "today", setDateFilter)}>
            Hoje
          </FilterChip>
          <FilterChip active={dateFilter === "7d"} onClick={() => toggle(dateFilter, "7d", setDateFilter)}>
            Últimos 7 dias
          </FilterChip>
          <FilterChip active={dateFilter === "30d"} onClick={() => toggle(dateFilter, "30d", setDateFilter)}>
            Últimos 30 dias
          </FilterChip>
        </div>
      </div>

      {/* Lista */}
      {isError ? (
        <Card className="p-6 text-sm text-destructive">
          Erro ao carregar: {(error as Error)?.message}
        </Card>
      ) : isLoading ? (
        <div className="space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <PlaylistCardSkeleton key={i} />
          ))}
        </div>
      ) : filtered.length === 0 ? (
        <EmptyState onRefresh={() => refetch()} refreshing={isFetching} />
      ) : (
        <div className="space-y-3">
          {filtered.map(({ p, platform }) => (
            <PlaylistCard
              key={p.id}
              p={p}
              platform={platform}
              busy={mutation.isPending || retryMutation.isPending}
              onOpen={() => openDetail(p)}
              onApprove={() => askApprove(p.id)}
              onReject={() => askReject(p.id)}
              onRetry={() => retryMutation.mutate({ id: p.id })}
            />
          ))}
        </div>
      )}

      {!isError && (
        <PaginationFooter
          page={requestsPage}
          pageSize={requestsPageSize}
          total={playlistsTotal}
          isLoading={isLoading || isFetching}
          onPageChange={setRequestsPage}
        />
      )}

        </>
      ) : (
        <>
        <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <StatCard
            icon={<Users className="h-5 w-5" />}
            iconClassName="bg-primary/10 text-primary"
            label="Operadores"
            value={libraryStats.operators}
            loading={libraryQuery.isLoading}
          />
          <StatCard
            icon={<Library className="h-5 w-5" />}
            iconClassName="bg-secondary/10 text-secondary"
            label="Com playlists"
            value={libraryStats.withPlaylists}
            loading={libraryQuery.isLoading}
          />
          <StatCard
            icon={<Music className="h-5 w-5" />}
            iconClassName="bg-success/25 text-success-foreground"
            label="Músicas importadas"
            value={libraryStats.totalTracks}
            loading={libraryQuery.isLoading}
          />
          <StatCard
            icon={<AlertTriangle className="h-5 w-5" />}
            iconClassName="bg-destructive/10 text-destructive"
            label="Importações com erro"
            value={libraryStats.failedImports}
            loading={libraryQuery.isLoading}
          />
        </div>
        <MusicLibrarySection
          operators={operators}
          search={librarySearch}
          page={libraryPage}
          pageSize={libraryPageSize}
          total={operatorsTotal}
          loading={libraryQuery.isLoading}
          error={libraryQuery.error as Error | null}
          refreshing={libraryQuery.isFetching}
          busy={
            renameMutation.isPending ||
            removeTrackMutation.isPending ||
            archiveMutation.isPending ||
            retryMutation.isPending
          }
          onSearchChange={setLibrarySearch}
          onPageChange={setLibraryPage}
          onRefresh={() => libraryQuery.refetch()}
          onOpenOperator={(operator) => {
            setSelectedOperatorId(operator.id);
            setSelectedPlaylistId(operator.playlists[0]?.id ?? null);
          }}
          onViewRequests={(operator) => {
            setSearch("");
            setOperatorRequestFilter(operator.id);
            setActiveArea("requests");
          }}
        />
        </>
      )}

      {/* Drawer de detalhes */}
      <Sheet open={Boolean(detailId)} onOpenChange={(o) => !o && setDetailId(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-lg">
          {detail && (
            <DetailPanel
              p={detail}
              platform={detectPlatform(detail.source_url)}
              note={noteDraft}
              onNoteChange={setNoteDraft}
              onSaveNote={() => saveNote(detail.id)}
              busy={mutation.isPending || retryMutation.isPending}
              onApprove={() => askApprove(detail.id)}
              onReject={() => askReject(detail.id)}
              onRetry={() => retryMutation.mutate({ id: detail.id })}
            />
          )}
        </SheetContent>
      </Sheet>

      {/* Modal de confirmação (aprovar / rejeitar) */}
      <Sheet open={Boolean(selectedOperatorId)} onOpenChange={(o) => !o && setSelectedOperatorId(null)}>
        <SheetContent className="w-full overflow-y-auto sm:max-w-4xl">
          {selectedOperator && (
            <OperatorLibraryPanel
              operator={selectedOperator}
              selectedPlaylistId={selectedPlaylistId}
              busy={
                renameMutation.isPending ||
                removeTrackMutation.isPending ||
                archiveMutation.isPending ||
                retryMutation.isPending
              }
              onSelectPlaylist={setSelectedPlaylistId}
              onRename={(playlist) => {
                setRenameTarget(playlist);
                setRenameName(playlist.name);
              }}
              onRetry={(playlist) => retryMutation.mutate({ id: playlist.id })}
              onArchive={setArchiveTarget}
              onRemoveTrack={(playlist, track) => setRemoveTrackTarget({ playlist, track })}
            />
          )}
        </SheetContent>
      </Sheet>

      <Dialog open={Boolean(renameTarget)} onOpenChange={(o) => !o && setRenameTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Renomear playlist</DialogTitle>
            <DialogDescription>O novo nome aparece na biblioteca musical do operador.</DialogDescription>
          </DialogHeader>
          <Input
            value={renameName}
            onChange={(e) => setRenameName(e.target.value)}
            maxLength={80}
            autoFocus
          />
          <DialogFooter>
            <Button variant="outline" onClick={() => setRenameTarget(null)}>
              Cancelar
            </Button>
            <Button
              disabled={renameMutation.isPending || !renameName.trim()}
              onClick={() =>
                renameTarget &&
                renameMutation.mutate({
                  id: renameTarget.id,
                  name: renameName.trim(),
                })
              }
            >
              {renameMutation.isPending ? <RefreshCw className="h-4 w-4 animate-spin" /> : <Pencil className="h-4 w-4" />}
              Salvar nome
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(removeTrackTarget)} onOpenChange={(o) => !o && setRemoveTrackTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Remover música da playlist</DialogTitle>
            <DialogDescription>
              A faixa sai desta playlist, mas o arquivo importado não é apagado do armazenamento.
            </DialogDescription>
          </DialogHeader>
          <div className="rounded-lg border border-border bg-muted/40 p-3 text-sm">
            <p className="font-medium">{removeTrackTarget?.track.title ?? "—"}</p>
            <p className="text-muted-foreground">
              {removeTrackTarget?.playlist.name ?? "Playlist"} · {removeTrackTarget?.track.artist ?? "artista não informado"}
            </p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setRemoveTrackTarget(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={removeTrackMutation.isPending}
              onClick={() =>
                removeTrackTarget &&
                removeTrackMutation.mutate({
                  playlistTrackId: removeTrackTarget.track.playlist_track_id,
                })
              }
            >
              {removeTrackMutation.isPending ? <RefreshCw className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
              Remover
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(archiveTarget)} onOpenChange={(o) => !o && setArchiveTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Arquivar playlist secundária</DialogTitle>
            <DialogDescription>
              A playlist deixa de aparecer na biblioteca ativa. A playlist principal não pode ser arquivada por aqui.
            </DialogDescription>
          </DialogHeader>
          <div className="rounded-lg border border-border bg-muted/40 p-3 text-sm">
            <p className="font-medium">{archiveTarget?.name ?? "—"}</p>
            <p className="text-muted-foreground">{archiveTarget?.track_count ?? 0} músicas</p>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setArchiveTarget(null)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={archiveMutation.isPending || archiveTarget?.type !== "secondary"}
              onClick={() => archiveTarget && archiveMutation.mutate({ id: archiveTarget.id })}
            >
              {archiveMutation.isPending ? <RefreshCw className="h-4 w-4 animate-spin" /> : <Archive className="h-4 w-4" />}
              Arquivar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(confirmState)} onOpenChange={(o) => !o && setConfirmState(null)}>
        <DialogContent>
          {confirmState?.action === "approve" ? (
            <>
              <DialogHeader>
                <DialogTitle>Aprovar playlist</DialogTitle>
                <DialogDescription>
                  A playlist de {confirmPlaylist?.operator_name ?? "—"} ficará ativa para o operador no app.
                </DialogDescription>
              </DialogHeader>
              <div className="rounded-lg border border-border bg-muted/40 p-3 text-sm">
                <p className="mb-1 font-medium">{confirmPlaylist ? playlistTypeLabel(confirmPlaylist.type) : ""} · {unitText(confirmPlaylist ?? ({} as Playlist))}</p>
                <p className="truncate text-muted-foreground">{confirmPlaylist?.source_url ?? "sem link"}</p>
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={() => setConfirmState(null)}>
                  Cancelar
                </Button>
                <Button
                  disabled={mutation.isPending}
                  onClick={() => confirmState && mutation.mutate({ id: confirmState.id, action: "approve" })}
                >
                  {mutation.isPending ? (
                    <RefreshCw className="h-4 w-4 animate-spin" />
                  ) : (
                    <Check className="h-4 w-4" />
                  )}
                  Confirmar aprovação
                </Button>
              </DialogFooter>
            </>
          ) : (
            <>
              <DialogHeader>
                <DialogTitle>Rejeitar playlist</DialogTitle>
                <DialogDescription>
                  Escreva o motivo. O operador verá essa mensagem e poderá enviar um novo link.
                </DialogDescription>
              </DialogHeader>
              <div className="py-1">
                <Textarea
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Ex.: o link não abre / conteúdo não permitido..."
                  rows={3}
                  autoFocus
                />
              </div>
              <DialogFooter>
                <Button variant="outline" onClick={() => setConfirmState(null)}>
                  Cancelar
                </Button>
                <Button
                  variant="destructive"
                  disabled={mutation.isPending || !reason.trim()}
                  onClick={() =>
                    confirmState && mutation.mutate({ id: confirmState.id, action: "reject", reason: reason.trim() })
                  }
                >
                  {mutation.isPending ? (
                    <RefreshCw className="h-4 w-4 animate-spin" />
                  ) : (
                    <X className="h-4 w-4" />
                  )}
                  Confirmar rejeição
                </Button>
              </DialogFooter>
            </>
          )}
        </DialogContent>
      </Dialog>
    </>
  );
}

function AreaButton({
  active,
  icon,
  onClick,
  children,
}: {
  active: boolean;
  icon: React.ReactNode;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "inline-flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors",
        active
          ? "bg-background text-foreground shadow-sm ring-1 ring-border"
          : "text-muted-foreground hover:bg-background/60 hover:text-foreground",
      )}
    >
      {icon}
      {children}
    </button>
  );
}

function MusicLibrarySection({
  operators,
  search,
  page,
  pageSize,
  total,
  loading,
  error,
  refreshing,
  busy,
  onSearchChange,
  onPageChange,
  onRefresh,
  onOpenOperator,
  onViewRequests,
}: {
  operators: OperatorMusicLibrary[];
  search: string;
  page: number;
  pageSize: number;
  total: number;
  loading: boolean;
  error: Error | null;
  refreshing: boolean;
  busy: boolean;
  onSearchChange: (value: string) => void;
  onPageChange: (page: number) => void;
  onRefresh: () => void;
  onOpenOperator: (operator: OperatorMusicLibrary) => void;
  onViewRequests: (operator: OperatorMusicLibrary) => void;
}) {
  return (
    <div className="space-y-4">
      <div className="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
        <div className="relative w-full max-w-md">
          <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" />
          <Input
            placeholder="Buscar operador, usuário, email, condomínio ou playlist..."
            value={search}
            onChange={(e) => onSearchChange(e.target.value)}
            className="h-10 rounded-lg pl-9"
          />
        </div>
        <Button variant="outline" size="sm" onClick={onRefresh} disabled={refreshing}>
          <RefreshCw className={cn("h-4 w-4", refreshing && "animate-spin")} />
          Atualizar biblioteca
        </Button>
      </div>

      {error ? (
        <Card className="p-6 text-sm text-destructive">Erro ao carregar biblioteca: {error.message}</Card>
      ) : loading ? (
        <div className="space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <PlaylistCardSkeleton key={i} />
          ))}
        </div>
      ) : operators.length === 0 ? (
        <Card className="flex flex-col items-center justify-center gap-3 px-6 py-14 text-center">
          <Library className="h-10 w-10 text-muted-foreground" />
          <div>
            <p className="font-display text-lg font-semibold">Nenhum operador encontrado</p>
            <p className="text-sm text-muted-foreground">Ajuste a busca ou atualize a biblioteca.</p>
          </div>
        </Card>
      ) : (
        <div className="space-y-3">
          {operators.map((operator) => (
            <OperatorLibraryCard
              key={operator.id}
              operator={operator}
              busy={busy}
              onOpen={() => onOpenOperator(operator)}
              onViewRequests={() => onViewRequests(operator)}
            />
          ))}
        </div>
      )}
      {!error && (
        <PaginationFooter
          page={page}
          pageSize={pageSize}
          total={total}
          isLoading={loading || refreshing}
          onPageChange={onPageChange}
        />
      )}
    </div>
  );
}

function OperatorLibraryCard({
  operator,
  busy,
  onOpen,
  onViewRequests,
}: {
  operator: OperatorMusicLibrary;
  busy: boolean;
  onOpen: () => void;
  onViewRequests: () => void;
}) {
  const totals = operatorTotals(operator);
  const status = totals.processing
    ? "Importando"
    : totals.failed
      ? "Com falhas"
      : operator.playlists.length
        ? "Biblioteca ok"
        : "Sem playlists";

  return (
    <Card className="flex flex-col gap-4 p-4 shadow-sm md:flex-row md:items-center">
      <div className="flex min-w-0 flex-1 items-center gap-3">
        <OperatorAvatar name={operator.display_name} className="h-12 w-12 text-sm" />
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <p className="truncate text-[15px] font-semibold">{operator.display_name}</p>
            <span className={cn(
              "rounded-full px-2 py-0.5 text-[11px] font-semibold ring-1",
              operator.active
                ? "bg-success/20 text-success-foreground ring-success/30"
                : "bg-muted text-muted-foreground ring-border",
            )}>
              {operator.active ? "Ativo" : "Inativo"}
            </span>
          </div>
          <p className="truncate text-xs text-muted-foreground">
            {operator.username ? `@${operator.username}` : "sem usuário"} · {operatorUnitText(operator)}
          </p>
          <p className="truncate text-xs text-muted-foreground">{operator.email ?? "sem email"}</p>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2 text-sm sm:grid-cols-5 md:w-[560px]">
        <MiniMetric label="Principal" value={totals.principal} />
        <MiniMetric label="Secundárias" value={totals.secondary} />
        <MiniMetric label="Músicas" value={totals.tracks} />
        <MiniMetric label="Atualizado" value={relOrDate(operator.updated_at)} />
        <MiniMetric label="Status" value={status} tone={totals.failed ? "danger" : totals.processing ? "info" : "default"} />
      </div>

      <div className="flex w-full shrink-0 flex-wrap gap-2 sm:w-auto md:flex-col">
        <Button size="sm" onClick={onOpen} disabled={busy}>
          <Eye className="h-4 w-4" />
          Ver biblioteca
        </Button>
        <Button size="sm" variant="outline" onClick={onViewRequests}>
          <History className="h-4 w-4" />
          Ver solicitações
        </Button>
      </div>
    </Card>
  );
}

function MiniMetric({
  label,
  value,
  tone = "default",
}: {
  label: string;
  value: number | string;
  tone?: "default" | "danger" | "info";
}) {
  return (
    <div className="rounded-md border border-border bg-muted/30 px-2.5 py-2">
      <p className="truncate text-[10px] font-medium uppercase tracking-wide text-muted-foreground">{label}</p>
      <p
        className={cn(
          "truncate text-sm font-semibold",
          tone === "danger" && "text-destructive",
          tone === "info" && "text-primary",
        )}
      >
        {value}
      </p>
    </div>
  );
}

function OperatorLibraryPanel({
  operator,
  selectedPlaylistId,
  busy,
  onSelectPlaylist,
  onRename,
  onRetry,
  onArchive,
  onRemoveTrack,
}: {
  operator: OperatorMusicLibrary;
  selectedPlaylistId: string | null;
  busy: boolean;
  onSelectPlaylist: (id: string) => void;
  onRename: (playlist: MusicLibraryPlaylist) => void;
  onRetry: (playlist: MusicLibraryPlaylist) => void;
  onArchive: (playlist: MusicLibraryPlaylist) => void;
  onRemoveTrack: (playlist: MusicLibraryPlaylist, track: MusicTrack) => void;
}) {
  const totals = operatorTotals(operator);
  const selectedPlaylist =
    operator.playlists.find((playlist) => playlist.id === selectedPlaylistId) ?? operator.playlists[0] ?? null;

  return (
    <div className="flex h-full flex-col">
      <SheetHeader className="text-left">
        <div className="flex items-center gap-3">
          <OperatorAvatar name={operator.display_name} className="h-12 w-12 text-sm" />
          <div className="min-w-0">
            <SheetTitle className="truncate">{operator.display_name}</SheetTitle>
            <SheetDescription className="flex flex-wrap items-center gap-1">
              <UserRound className="h-3.5 w-3.5" />
              {operator.username ? `@${operator.username}` : "sem usuário"} · {operatorUnitText(operator)}
            </SheetDescription>
          </div>
        </div>
      </SheetHeader>

      <div className="mt-5 grid grid-cols-2 gap-2 sm:grid-cols-4">
        <MiniMetric label="Playlists" value={operator.playlists.length} />
        <MiniMetric label="Principal" value={totals.principal} />
        <MiniMetric label="Secundárias" value={totals.secondary} />
        <MiniMetric label="Músicas" value={totals.tracks} />
      </div>

      <div className="mt-5 grid gap-4 lg:grid-cols-[280px_1fr]">
        <div className="space-y-3">
          <div className="flex items-center gap-2 text-sm font-semibold">
            <Library className="h-4 w-4" />
            Playlists
          </div>
          {operator.playlists.length === 0 ? (
            <Card className="p-4 text-sm text-muted-foreground">Nenhuma playlist ativa para este operador.</Card>
          ) : (
            <div className="space-y-2">
              {operator.playlists.map((playlist) => (
                <button
                  key={playlist.id}
                  type="button"
                  onClick={() => onSelectPlaylist(playlist.id)}
                  className={cn(
                    "w-full rounded-lg border p-3 text-left transition-colors",
                    selectedPlaylist?.id === playlist.id
                      ? "border-primary bg-primary/5"
                      : "border-border bg-background hover:border-primary/50",
                  )}
                >
                  <div className="flex items-center justify-between gap-2">
                    <span className="truncate text-sm font-semibold">{playlist.name}</span>
                    <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
                      {playlistTypeLabel(playlist.type)}
                    </span>
                  </div>
                  <div className="mt-2 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                    <span>{playlist.track_count} músicas</span>
                    <span>·</span>
                    <ImportStatusText playlist={playlist} />
                  </div>
                </button>
              ))}
            </div>
          )}

          <div className="pt-2">
            <div className="mb-2 flex items-center gap-2 text-sm font-semibold">
              <History className="h-4 w-4" />
              Histórico
            </div>
            <RequestHistoryList history={operator.request_history} />
          </div>
        </div>

        {selectedPlaylist ? (
          <PlaylistLibraryDetail
            playlist={selectedPlaylist}
            busy={busy}
            onRename={() => onRename(selectedPlaylist)}
            onRetry={() => onRetry(selectedPlaylist)}
            onArchive={() => onArchive(selectedPlaylist)}
            onRemoveTrack={(track) => onRemoveTrack(selectedPlaylist, track)}
          />
        ) : (
          <Card className="flex min-h-[320px] items-center justify-center p-6 text-sm text-muted-foreground">
            Selecione uma playlist para ver as músicas.
          </Card>
        )}
      </div>
    </div>
  );
}

function ImportStatusText({ playlist }: { playlist: MusicLibraryPlaylist }) {
  if (playlist.import_status === "processing") return <span className="text-primary">Importando</span>;
  if (playlist.import_status === "failed") return <span className="text-destructive">Importação falhou</span>;
  if (playlist.import_status === "success") return <span className="text-success-foreground">Importada</span>;
  return <span>Importação não iniciada</span>;
}

function RequestHistoryList({ history }: { history: OperatorRequestHistory[] }) {
  if (history.length === 0) {
    return <Card className="p-3 text-xs text-muted-foreground">Sem histórico de solicitações.</Card>;
  }
  return (
    <div className="max-h-64 space-y-2 overflow-y-auto pr-1">
      {history.slice(0, 10).map((item) => (
        <div key={item.id} className="rounded-lg border border-border bg-muted/20 p-2.5 text-xs">
          <div className="flex items-center justify-between gap-2">
            <span className="truncate font-medium">{item.name}</span>
            <StatusPill status={item.approval_status} />
          </div>
          <p className="mt-1 text-muted-foreground">
            {playlistTypeLabel(item.type)} · {relOrDate(item.submitted_at)}
          </p>
          {(item.rejection_reason || item.error_message) && (
            <p className="mt-1 line-clamp-2 text-destructive">
              {item.rejection_reason || item.error_message}
            </p>
          )}
        </div>
      ))}
    </div>
  );
}

function PlaylistLibraryDetail({
  playlist,
  busy,
  onRename,
  onRetry,
  onArchive,
  onRemoveTrack,
}: {
  playlist: MusicLibraryPlaylist;
  busy: boolean;
  onRename: () => void;
  onRetry: () => void;
  onArchive: () => void;
  onRemoveTrack: (track: MusicTrack) => void;
}) {
  const platform = detectPlatform(playlist.source_url);
  const meta = platformMeta(platform);
  const canRetry = playlist.approval_status === "approved";
  const canArchive = playlist.type === "secondary";
  const error = playlistLibraryError(playlist);

  return (
    <Card className="p-4 shadow-sm">
      <div className="flex flex-col gap-3 border-b border-border pb-4 md:flex-row md:items-start md:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="truncate font-display text-lg font-semibold">{playlist.name}</h3>
            <span className="rounded-full bg-muted px-2 py-0.5 text-xs font-medium text-muted-foreground">
              {playlistTypeLabel(playlist.type)}
            </span>
            <ImportStatusText playlist={playlist} />
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span>Revisão {playlist.revision}</span>
            <span>·</span>
            <span>Atualizada {relOrDate(playlist.updated_at)}</span>
            <span>·</span>
            <span>{playlist.track_count} músicas</span>
          </div>
          {playlist.source_url && (
            <div className="mt-2 flex min-w-0 items-center gap-1.5 text-sm">
              <span className={cn("shrink-0", meta.fg)}>{meta.icon({ className: cn("size-4", meta.fg) })}</span>
              <span className="truncate" title={playlist.source_url}>{playlist.source_url}</span>
            </div>
          )}
        </div>

        <div className="flex flex-wrap gap-2">
          {playlist.source_url && (
            <>
              <IconAction title="Abrir link" onClick={() => window.open(playlist.source_url!, "_blank", "noopener,noreferrer")}>
                <ExternalLink className="h-4 w-4" />
              </IconAction>
              <IconAction title="Copiar link" onClick={() => copy(playlist.source_url!)}>
                <Copy className="h-4 w-4" />
              </IconAction>
            </>
          )}
          <Button size="sm" variant="outline" onClick={onRename} disabled={busy}>
            <Pencil className="h-4 w-4" />
            Renomear
          </Button>
          <Button size="sm" variant="outline" onClick={onRetry} disabled={busy || !canRetry}>
            <RefreshCw className="h-4 w-4" />
            Reimportar
          </Button>
          {canArchive && (
            <Button size="sm" variant="outline" className="text-destructive hover:text-destructive" onClick={onArchive} disabled={busy}>
              <Archive className="h-4 w-4" />
              Arquivar
            </Button>
          )}
        </div>
      </div>

      {error && (
        <div className="mt-3 rounded-md bg-destructive/10 px-3 py-2 text-xs text-destructive ring-1 ring-destructive/20">
          <span className="font-semibold">Falha ao importar: </span>
          {error}
        </div>
      )}

      <div className="mt-4">
        <div className="mb-2 flex items-center gap-2 text-sm font-semibold">
          <ListOrdered className="h-4 w-4" />
          Músicas da playlist
        </div>
        {playlist.tracks.length === 0 ? (
          <Card className="p-6 text-center text-sm text-muted-foreground">
            Nenhuma música importada nesta playlist.
          </Card>
        ) : (
          <div className="overflow-hidden rounded-lg border border-border">
            <div className="max-h-[520px] overflow-auto">
              <table className="w-full min-w-[680px] text-sm">
                <thead className="sticky top-0 bg-muted text-xs text-muted-foreground">
                  <tr>
                    <th className="w-16 px-3 py-2 text-left">#</th>
                    <th className="px-3 py-2 text-left">Música</th>
                    <th className="w-28 px-3 py-2 text-left">Duração</th>
                    <th className="w-28 px-3 py-2 text-left">Status</th>
                    <th className="w-28 px-3 py-2 text-right">Ações</th>
                  </tr>
                </thead>
                <tbody>
                  {playlist.tracks.map((track) => (
                    <tr key={track.playlist_track_id} className="border-t border-border">
                      <td className="px-3 py-2 text-muted-foreground">{track.position}</td>
                      <td className="px-3 py-2">
                        <p className="font-medium">{track.title}</p>
                        <p className="text-xs text-muted-foreground">{track.artist ?? "artista não informado"}</p>
                      </td>
                      <td className="px-3 py-2 text-muted-foreground">{durationText(track.duration_ms)}</td>
                      <td className="px-3 py-2 text-muted-foreground">{trackStatusLabel(track.status)}</td>
                      <td className="px-3 py-2">
                        <div className="flex justify-end gap-1">
                          {track.source_url && (
                            <IconAction title="Abrir origem" onClick={() => window.open(track.source_url!, "_blank", "noopener,noreferrer")}>
                              <ExternalLink className="h-4 w-4" />
                            </IconAction>
                          )}
                          {track.public_url && (
                            <IconAction title="Copiar URL" onClick={() => copy(track.public_url!)}>
                              <Copy className="h-4 w-4" />
                            </IconAction>
                          )}
                          <IconAction title="Remover da playlist" onClick={() => onRemoveTrack(track)}>
                            <Trash2 className="h-4 w-4" />
                          </IconAction>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}
      </div>
    </Card>
  );
}

/* ------------------------------ Card horizontal --------------------------- */

function PlaylistCard({
  p,
  platform,
  busy,
  onOpen,
  onApprove,
  onReject,
  onRetry,
}: {
  p: Playlist;
  platform: Platform;
  busy: boolean;
  onOpen: () => void;
  onApprove: () => void;
  onReject: () => void;
  onRetry: () => void;
}) {
  const m = platformMeta(platform);
  // Decisão é definitiva: só uma playlist "pendente" pode ser aprovada/rejeitada.
  const canApprove = p.approval_status === "pending";
  const canReject = p.approval_status === "pending";
  const canRetry = p.approval_status === "approved" && p.import_status === "failed";
  const importError = playlistImportError(p);
  const stop = (fn: () => void) => (e: React.MouseEvent) => {
    e.stopPropagation();
    fn();
  };

  return (
    <Card
      onClick={onOpen}
      className={cn(
        "group flex cursor-pointer flex-col items-start gap-4 p-4 shadow-sm sm:flex-row sm:items-center",
        "transition-all duration-200 hover:-translate-y-0.5 hover:border-primary/60 hover:shadow-md",
      )}
    >
      <PlatformIcon platform={platform} />

      <div className="min-w-0 flex-1">
        {/* topo: operador + tipo + condomínio */}
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span className="min-w-0 break-words text-[15px] font-semibold text-foreground">{p.operator_name ?? "—"}</span>
          <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
            {playlistTypeLabel(p.type)}
          </span>
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            <Building2 className="h-3.5 w-3.5" />
            {unitText(p)}
          </span>
        </div>

        {/* destaque: o link */}
        <div className="mt-1.5">
          {p.source_url ? (
            <div className="flex min-w-0 items-center gap-1.5">
              <span className={cn("shrink-0", m.fg)}>{m.icon({ className: cn("size-4", m.fg) })}</span>
              <span className="truncate text-sm font-medium text-foreground" title={p.source_url}>
                {p.source_url}
              </span>
              {platform === "invalid" && (
                <span className="shrink-0 rounded-full bg-destructive/10 px-2 py-0.5 text-[11px] font-semibold text-destructive ring-1 ring-destructive/20">
                  Link inválido
                </span>
              )}
            </div>
          ) : (
            <span className="inline-flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-0.5 text-xs font-medium text-muted-foreground ring-1 ring-border">
              <Music className="h-3.5 w-3.5" /> Sem link
            </span>
          )}
        </div>

        {/* rodapé: status + data + download */}
        <div className="mt-2 flex flex-wrap items-center gap-2">
          <StatusPill status={p.approval_status} />
          <span className="text-xs text-muted-foreground">· {relOrDate(p.submitted_at)}</span>
          <ImportPill p={p} />
        </div>

        {p.import_status === "failed" && (
          <div className="mt-2 flex items-start gap-1.5 rounded-md bg-destructive/10 px-2.5 py-1.5 text-xs text-destructive ring-1 ring-destructive/20">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>
              <span className="font-semibold">Falha ao importar: </span>
              {importError || "motivo técnico não informado pelo backend"}
            </span>
          </div>
        )}

        {/* Motivo da rejeição — bem visível */}
        {p.approval_status === "rejected" && (
          <div className="mt-2 flex items-start gap-1.5 rounded-md bg-destructive/10 px-2.5 py-1.5 text-xs text-destructive ring-1 ring-destructive/20">
            <X className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>
              <span className="font-semibold">Motivo: </span>
              {p.rejection_reason?.trim() || "não informado"}
            </span>
          </div>
        )}
      </div>

      {/* ações */}
      <div className="flex w-full shrink-0 flex-wrap items-center justify-end gap-1 sm:w-auto">
        {p.source_url && platform !== "invalid" && (
          <IconAction title="Abrir link" onClick={stop(() => window.open(p.source_url!, "_blank", "noopener,noreferrer"))}>
            <ExternalLink className="h-4 w-4" />
          </IconAction>
        )}
        {p.source_url && (
          <IconAction title="Copiar link" onClick={stop(() => copy(p.source_url!))}>
            <Copy className="h-4 w-4" />
          </IconAction>
        )}
        <IconAction title="Detalhes" onClick={stop(onOpen)}>
          <Eye className="h-4 w-4" />
        </IconAction>
        {canReject && (
          <Button
            size="sm"
            variant="ghost"
            className="text-destructive hover:bg-destructive/10 hover:text-destructive"
            disabled={busy}
            onClick={stop(onReject)}
          >
            <X className="h-4 w-4" /> Rejeitar
          </Button>
        )}
        {canApprove && (
          <Button size="sm" disabled={busy} onClick={stop(onApprove)}>
            <Check className="h-4 w-4" /> Aprovar
          </Button>
        )}
        {canRetry && (
          <Button size="sm" variant="outline" disabled={busy} onClick={stop(onRetry)}>
            <RefreshCw className="h-4 w-4" /> Tentar importar novamente
          </Button>
        )}
      </div>
    </Card>
  );
}

function IconAction({
  title,
  onClick,
  children,
}: {
  title: string;
  onClick: (e: React.MouseEvent) => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className={cn(
        "flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground",
        "cursor-pointer transition-colors hover:bg-accent hover:text-foreground",
      )}
    >
      {children}
    </button>
  );
}

/* ----------------------------- Selo de importação ------------------------- */

function ImportPill({ p }: { p: Playlist }) {
  const download = p.download;
  if (!download && p.approval_status !== "approved") return null;
  if (!download) {
    return (
      <span className="inline-flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-0.5 text-xs font-medium text-muted-foreground ring-1 ring-border">
        <Download className="h-3.5 w-3.5" /> Importação não iniciada
      </span>
    );
  }
  const { status, total, completed, failed } = download;

  const base =
    "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium ring-1";

  if (status === "queued") {
    return (
      <span className={cn(base, "bg-muted text-muted-foreground ring-border")}>
        <Download className="h-3.5 w-3.5" /> Importação na fila
      </span>
    );
  }
  if (status === "running") {
    return (
      <span className={cn(base, "bg-primary/10 text-primary ring-primary/25")}>
        <Loader2 className="h-3.5 w-3.5 animate-spin" />
        Importando {completed}
        {total ? `/${total}` : ""}
      </span>
    );
  }
  if (status === "done") {
    return (
      <span className={cn(base, "bg-success/25 text-success-foreground ring-success/40")}>
        <Download className="h-3.5 w-3.5" /> Importação concluída · {completed} músicas
      </span>
    );
  }
  if (status === "partial") {
    return (
      <span className={cn(base, "bg-warning/15 text-warning-foreground ring-warning/40")}>
        <AlertTriangle className="h-3.5 w-3.5" /> {completed} ok · {failed} falharam
      </span>
    );
  }
  // error
  return (
    <span className={cn(base, "bg-destructive/10 text-destructive ring-destructive/25")}>
      <AlertTriangle className="h-3.5 w-3.5" /> Importação falhou
    </span>
  );
}

/* ------------------------------- Drawer detalhe --------------------------- */

function DetailPanel({
  p,
  platform,
  note,
  onNoteChange,
  onSaveNote,
  busy,
  onApprove,
  onReject,
  onRetry,
}: {
  p: Playlist;
  platform: Platform;
  note: string;
  onNoteChange: (v: string) => void;
  onSaveNote: () => void;
  busy: boolean;
  onApprove: () => void;
  onReject: () => void;
  onRetry: () => void;
}) {
  const embed = buildEmbed(p.source_url, platform);
  const m = platformMeta(platform);
  // Decisão é definitiva: só uma playlist "pendente" pode ser aprovada/rejeitada.
  const canApprove = p.approval_status === "pending";
  const canReject = p.approval_status === "pending";
  const canRetry = p.approval_status === "approved" && p.import_status === "failed";
  const importError = playlistImportError(p);
  const technicalError = technicalErrorText(p);

  return (
    <div className="flex h-full flex-col">
      <SheetHeader className="text-left">
        <div className="flex items-center gap-3">
          <OperatorAvatar name={p.operator_name} className="h-12 w-12 text-sm" />
          <div className="min-w-0">
            <SheetTitle className="truncate">{p.operator_name ?? "—"}</SheetTitle>
            <SheetDescription className="flex items-center gap-1">
              <Building2 className="h-3.5 w-3.5" /> {unitText(p)}
            </SheetDescription>
          </div>
        </div>
      </SheetHeader>

      <div className="mt-4 flex flex-wrap items-center gap-2">
        <span className="rounded-full bg-muted px-2.5 py-0.5 text-xs font-medium text-muted-foreground">
          {playlistTypeLabel(p.type)}
        </span>
        <span className={cn("inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-medium ring-1", m.bg, m.fg, m.ring)}>
          {m.icon({ className: cn("size-3.5", m.fg) })} {m.label}
        </span>
        <StatusPill status={p.approval_status} />
        <ImportPill p={p} />
      </div>

      {/* Link completo */}
      <div className="mt-5">
        <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Link enviado</p>
        {p.source_url ? (
          <div className="flex items-center gap-2 rounded-lg border border-border bg-muted/40 p-2.5">
            <span className={cn("shrink-0", m.fg)}>{m.icon({ className: cn("size-4", m.fg) })}</span>
            <span className="min-w-0 flex-1 break-all text-sm">{p.source_url}</span>
            <button
              type="button"
              title="Copiar"
              onClick={() => copy(p.source_url!)}
              className="shrink-0 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
            >
              <Copy className="h-4 w-4" />
            </button>
            {platform !== "invalid" && (
              <a
                href={p.source_url}
                target="_blank"
                rel="noreferrer noopener"
                title="Abrir"
                className="shrink-0 rounded-md p-1.5 text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
              >
                <ExternalLink className="h-4 w-4" />
              </a>
            )}
          </div>
        ) : (
          <p className="text-sm text-muted-foreground">O operador ainda não enviou um link.</p>
        )}
      </div>

      {(p.import_status === "failed" || p.approval_status === "rejected") && (
        <div className="mt-5 rounded-lg border border-border bg-muted/30 p-3">
          <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            Motivo
          </p>
          {p.approval_status === "rejected" ? (
            <p className="text-sm text-destructive">
              {p.rejection_reason?.trim() || "Motivo da rejeição não informado."}
            </p>
          ) : (
            <>
              <p className="text-sm text-destructive">
                Falha ao importar: {importError || "motivo técnico não informado pelo backend"}
              </p>
              {technicalError && (
                <pre className="mt-2 max-h-28 overflow-auto whitespace-pre-wrap rounded-md bg-background p-2 text-xs text-muted-foreground">
                  {technicalError}
                </pre>
              )}
            </>
          )}
        </div>
      )}

      {/* Preview */}
      {embed && (
        <div className="mt-5">
          <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Prévia</p>
          <div className="overflow-hidden rounded-lg border border-border">
            <iframe
              src={embed}
              title="Prévia da playlist"
              className="h-[152px] w-full"
              loading="lazy"
              allow="encrypted-media"
              referrerPolicy="no-referrer"
            />
          </div>
        </div>
      )}

      {/* Histórico */}
      <div className="mt-5">
        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Histórico</p>
        <ol className="space-y-3 border-l border-border pl-4">
          <TimelineItem color="bg-primary" label="Link enviado" date={p.submitted_at} empty="Ainda não enviado" />
          {p.approval_status === "approved" && (
            <TimelineItem color="bg-success" label="Aprovada" date={p.reviewed_at} />
          )}
          {p.approval_status === "rejected" && (
            <TimelineItem
              color="bg-destructive"
              label="Rejeitada"
              date={p.reviewed_at}
              note={p.rejection_reason}
            />
          )}
        </ol>
      </div>

      <div className="mt-5">
        <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Auditoria</p>
        <div className="grid gap-2 text-sm">
          <InfoRow label="Solicitada em" value={fmtDate(p.submitted_at)} />
          <InfoRow label="Revisada em" value={fmtDate(p.reviewed_at)} />
          <InfoRow label="Revisada por" value={p.reviewed_by_name ?? "—"} />
          <InfoRow label="Importação iniciada" value={fmtDate(p.import_started_at ?? p.download?.started_at ?? null)} />
          <InfoRow label="Importação finalizada" value={fmtDate(p.import_finished_at ?? p.download?.finished_at ?? null)} />
          <InfoRow label="Último erro" value={fmtDate(p.last_error_at ?? p.download?.last_error_at ?? null)} />
        </div>
      </div>

      {/* Observações internas (local) */}
      <div className="mt-5">
        <p className="mb-1.5 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          Observações internas
        </p>
        <Textarea
          value={note}
          onChange={(e) => onNoteChange(e.target.value)}
          placeholder="Anotações visíveis só para a moderação..."
          rows={3}
        />
        <div className="mt-2 flex justify-end">
          <Button size="sm" variant="outline" onClick={onSaveNote}>
            <Save className="h-4 w-4" /> Salvar observações
          </Button>
        </div>
      </div>

      {/* Ações */}
      {(canApprove || canReject || canRetry) && (
        <div className="mt-auto flex gap-2 pt-6">
          {canReject && (
            <Button variant="outline" className="flex-1 text-destructive hover:bg-destructive/10 hover:text-destructive" disabled={busy} onClick={onReject}>
              <X className="h-4 w-4" /> Rejeitar
            </Button>
          )}
          {canApprove && (
            <Button className="flex-1" disabled={busy} onClick={onApprove}>
              <Check className="h-4 w-4" /> Aprovar
            </Button>
          )}
          {canRetry && (
            <Button className="flex-1" variant="outline" disabled={busy} onClick={onRetry}>
              <RefreshCw className="h-4 w-4" /> Tentar importar novamente
            </Button>
          )}
        </div>
      )}
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 border-b border-border/60 pb-1 last:border-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="text-right font-medium text-foreground">{value}</span>
    </div>
  );
}

function TimelineItem({
  color,
  label,
  date,
  note,
  empty,
}: {
  color: string;
  label: string;
  date: string | null;
  note?: string | null;
  empty?: string;
}) {
  return (
    <li className="relative">
      <span className={cn("absolute -left-[21px] top-1 h-2.5 w-2.5 rounded-full ring-4 ring-background", color)} />
      <p className="text-sm font-medium text-foreground">{label}</p>
      <p className="text-xs text-muted-foreground">{date ? fmtDate(date) : empty ?? "—"}</p>
      {note && <p className="mt-0.5 text-xs italic text-muted-foreground">“{note}”</p>}
    </li>
  );
}

/* ------------------------------ Skeleton / vazio -------------------------- */

function PlaylistCardSkeleton() {
  return (
    <Card className="flex items-center gap-4 p-4 shadow-sm">
      <Skeleton className="h-11 w-11 rounded-xl" />
      <div className="flex-1 space-y-2.5">
        <Skeleton className="h-4 w-48" />
        <Skeleton className="h-4 w-72" />
        <Skeleton className="h-5 w-32 rounded-full" />
      </div>
      <Skeleton className="h-8 w-24 rounded-md" />
    </Card>
  );
}

function EmptyState({ onRefresh, refreshing }: { onRefresh: () => void; refreshing: boolean }) {
  return (
    <Card className="flex flex-col items-center justify-center gap-4 px-6 py-16 text-center">
      <div className="relative">
        <div className="flex h-20 w-20 items-center justify-center rounded-2xl bg-primary/10 ring-1 ring-primary/20">
          <ListMusic className="h-9 w-9 text-primary" />
        </div>
        <div className="absolute -bottom-1.5 -right-1.5 flex h-8 w-8 items-center justify-center rounded-full bg-background ring-1 ring-border">
          <Inbox className="h-4 w-4 text-muted-foreground" />
        </div>
      </div>
      <div className="max-w-sm space-y-1">
        <p className="font-display text-lg font-semibold">Nenhuma playlist aguardando aprovação</p>
        <p className="text-sm text-muted-foreground">
          Quando um operador enviar uma playlist pelo app, ela aparecerá aqui.
        </p>
      </div>
      <Button variant="outline" onClick={onRefresh} disabled={refreshing}>
        <RefreshCw className={cn("h-4 w-4", refreshing && "animate-spin")} /> Atualizar lista
      </Button>
    </Card>
  );
}
