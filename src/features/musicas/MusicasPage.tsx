import { useEffect, useMemo, useState } from "react";
import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
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
  ChevronDown,
  HardDrive,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { unitLabel } from "@/lib/unit-label";
import { errorMessage } from "@/lib/errors";
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
  acknowledgePlaylistImportError,
  countPlaylistStats,
  dismissSkippedTrack,
  enqueueTrackReplacement,
  getMusicStorageOverview,
  getPlaylistRequestDetail,
  listMusicStorageDeletionJobs,
  listOrphanedMusicTracks,
  listOperatorMusicLibraryPage,
  listPlaylists,
  managePlaylistRequestItem,
  removePlaylistTrack,
  renameMusicPlaylist,
  queueOrphanedMusicDeletions,
  retryMusicStorageDeletionJobs,
  reimportPlaylistRequest,
  retryPlaylistImport,
  reviewPlaylist,
  playlistTypeLabel,
  type MusicLibraryPlaylist,
  type MusicTrack,
  type OperatorMusicLibrary,
  type OperatorRequestHistory,
  type MusicStorageOverview,
  type MusicStorageDeletionJob,
  type OrphanedMusicTrack,
  type Playlist,
  type PlaylistRequestDetailItem,
} from "./queries";
import { PaginationFooter, PeriodFilter, StatCard, ErrorState, RetryButton } from "@/components/shared";
import { buildPeriodRange, todayInput, type PeriodPreset } from "@/lib/period";
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
  return unitLabel({ name: p.unit_name, city: p.unit_city, state: p.unit_state });
}

function operatorUnitText(operator: OperatorMusicLibrary) {
  return unitLabel({ name: operator.unit_name, city: operator.unit_city, state: operator.unit_state });
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

function fmtDuration(ms: number | null) {
  if (ms == null || !Number.isFinite(ms)) return "—";
  const total = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

function sourceResourceLabel(url: string | null) {
  try {
    const path = new URL(url ?? "").pathname.toLowerCase();
    if (path.includes("/playlist")) return "Playlist";
    if (path.includes("/album")) return "Álbum";
    if (path.includes("/track")) return "Música";
    if (path.includes("/watch") || path.includes("youtu.be")) return "Vídeo";
  } catch {
    // A fila também exibe links históricos que podem não obedecer ao parser novo.
  }
  return null;
}

function generalStatusLabel(status: string | null | undefined) {
  return {
    pending: "Pendente",
    analyzing: "Analisando",
    waiting_review: "Aguardando revisão",
    approved: "Aprovada",
    processing: "Processando",
    partially_completed: "Parcialmente concluída",
    completed: "Concluída",
    rejected: "Rejeitada",
    failed: "Falha geral",
  }[status ?? ""] ?? status ?? "—";
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
  const code = typeof p.latest_job?.error_code === "string" ? p.latest_job.error_code : null;
  const jobMessage = typeof p.latest_job?.error_message === "string" ? p.latest_job.error_message : null;
  return p.error_message?.trim() || friendlyImportMessage(code, jobMessage);
}

function operatorTotals(operator: OperatorMusicLibrary) {
  const principal = operator.playlists.filter((p) => p.type === "principal").length;
  const secondary = operator.playlists.filter((p) => p.type === "secondary").length;
  const tracks = operator.playlists.reduce((sum, p) => sum + (p.track_count ?? p.tracks.length), 0);
  const failed = operator.playlists.filter((p) => p.import_status === "failed").length;
  const processing = operator.playlists.filter((p) => p.import_status === "processing").length;
  return { principal, secondary, tracks, failed, processing };
}

const FRIENDLY_IMPORT_MESSAGES: Record<string, string> = {
  SPOTIFY_PLAYLIST_EMPTY: "A playlist do Spotify não possui músicas disponíveis.",
  PLAYLIST_EMPTY: "A playlist não possui músicas disponíveis.",
  SPOTIFY_LINK_UNAVAILABLE: "O link do Spotify não está mais disponível.",
  SPOTIFY_MATCH_NOT_FOUND: "Não foi possível localizar esta música no YouTube.",
  IMPORTED_WITH_UNAVAILABLE: "Não foi possível localizar algumas músicas no YouTube.",
  REVIEW_RECOMMENDED: "Esta música parece ser uma versão diferente e precisa de revisão.",
  TRACK_DURATION_LIMIT_EXCEEDED: "A música ultrapassa a duração máxima de 16 minutos.",
  PLAYLIST_LIMIT_EXCEEDED: "A playlist ultrapassa o limite de 170 músicas.",
  SPOTIFY_RESOLVER_UNAVAILABLE: "O serviço de importação está temporariamente indisponível.",
  SPOTIFY_RESOLVE_TIMEOUT: "O serviço de importação está temporariamente indisponível.",
  IMPORT_TIMEOUT: "O serviço de importação está temporariamente indisponível.",
  REQUEST_TIMEOUT: "O serviço de importação está temporariamente indisponível.",
  WORKER_STALE_TIMEOUT: "O serviço de importação está temporariamente indisponível.",
  WORKER_ENV_MISSING: "O serviço de importação está temporariamente indisponível.",
  SUPABASE_PERMISSION_DENIED: "O serviço de importação está temporariamente indisponível.",
  SUPABASE_ERROR: "O serviço de importação está temporariamente indisponível.",
  R2_ACCESS_DENIED: "O serviço de importação está temporariamente indisponível.",
  R2_ERROR: "O serviço de importação está temporariamente indisponível.",
  YOUTUBE_COOKIES_MISSING: "O importador do YouTube está se recuperando automaticamente.",
  YOUTUBE_COOKIES_INVALID: "O importador do YouTube está se recuperando automaticamente.",
  YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE: "O importador do YouTube está se recuperando automaticamente.",
  IMPORTER_ERROR: "O serviço de importação está temporariamente indisponível.",
};

const YOUTUBE_PAUSE_CODES = new Set([
  "YOUTUBE_COOKIES_MISSING",
  "YOUTUBE_COOKIES_INVALID",
  "YOUTUBE_TOKEN_PROVIDER_UNAVAILABLE",
]);

function friendlyImportMessage(code?: string | null, fallback?: string | null): string | null {
  if (code) {
    return FRIENDLY_IMPORT_MESSAGES[code] ?? "O serviço de importação está temporariamente indisponível.";
  }
  return fallback?.trim() || null;
}

function playlistImportError(p: Playlist): string | null {
  return friendlyImportMessage(
    p.error_code || p.download?.error_code,
    p.error_message || p.download?.error_message || null,
  );
}

function playlistImportPauseMessage(p: Playlist): string | null {
  const code = p.download?.error_code || p.error_code;
  if (p.download?.status !== "queued" || !code || !YOUTUBE_PAUSE_CODES.has(code)) return null;
  return "Importação pausada automaticamente. O sistema tentará novamente quando o YouTube responder.";
}

function isImportErrorAcknowledged(p: Playlist) {
  if (!p.import_error_acknowledged_at) return false;
  if (!p.last_error_at) return true;
  return new Date(p.import_error_acknowledged_at).getTime() >= new Date(p.last_error_at).getTime();
}

function technicalErrorText(p: Playlist): string | null {
  const code = p.error_code || p.download?.error_code;
  const details = p.error_details || p.download?.error_details;
  const rawError = p.download?.error?.trim();
  const parts = [
    code ? `Código: ${code}` : null,
    rawError ? `Resumo técnico: ${rawError}` : null,
    details ? `Detalhes: ${JSON.stringify(details)}` : null,
  ].filter(Boolean);
  return parts.length ? parts.join("\n") : null;
}

type SkippedTrack = {
  title?: string;
  reason?: string;
  code?: string;
  youtube_id?: string;
  duration_seconds?: number | null;
};

function importReport(p: Playlist): {
  summary?: { total?: number; completed?: number; failed?: number; excluded_by_limit?: number };
  skipped: SkippedTrack[];
} {
  const d = (p.error_details || p.download?.error_details) as
    | { summary?: { total?: number; completed?: number; failed?: number; excluded_by_limit?: number }; skipped?: SkippedTrack[] }
    | null
    | undefined;
  const skipped = Array.isArray(d?.skipped) ? (d!.skipped as SkippedTrack[]) : [];
  return { summary: d?.summary, skipped };
}

function fmtDur(s?: number | null): string | null {
  if (s == null || Number.isNaN(s)) return null;
  const m = Math.floor(s / 60);
  const sec = Math.round(s % 60);
  return `${m}:${String(sec).padStart(2, "0")}`;
}

// Motivos permanentes = "indisponível" (não é erro de sistema): mostra neutro.
const PERMANENT_SKIP_CODES = new Set([
  "YOUTUBE_GEO_BLOCKED",
  "YOUTUBE_FORMAT_UNAVAILABLE",
  "PLAYLIST_PRIVATE_OR_UNAVAILABLE",
  "TRACK_SIZE_LIMIT_EXCEEDED",
  "TRACK_DURATION_LIMIT_EXCEEDED",
  "TRACK_DURATION_UNKNOWN",
  "SPOTIFY_MATCH_NOT_FOUND",
  "PLAYLIST_LIMIT_EXCEEDED",
]);
const isUnavailableCode = (code?: string) => !!code && PERMANENT_SKIP_CODES.has(code);

/** Diálogo p/ trocar UMA faixa indisponível colando outra URL do YouTube. */
function ReplaceTrackDialog({
  playlistId,
  target,
  onClose,
}: {
  playlistId: string;
  target: SkippedTrack | null;
  onClose: () => void;
}) {
  const qc = useQueryClient();
  const [url, setUrl] = useState("");
  useEffect(() => {
    if (target) setUrl("");
  }, [target]);

  const mutation = useMutation({
    mutationFn: () => enqueueTrackReplacement(playlistId, url.trim(), target?.youtube_id ?? null),
    onSuccess: () => {
      toast.success("Troca enfileirada", {
        description: "O worker vai baixar a nova versão em instantes.",
      });
      qc.invalidateQueries();
      onClose();
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível enfileirar", { description: errorMessage(err) });
    },
  });

  return (
    <Dialog open={!!target} onOpenChange={(o) => !o && onClose()}>
      <DialogContent>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            if (url.trim()) mutation.mutate();
          }}
        >
          <DialogHeader>
            <DialogTitle>Trocar faixa</DialogTitle>
            <DialogDescription>
              {target?.title ? `Substituir "${target.title}". ` : ""}
              Cole a URL do YouTube da versão que deve entrar no lugar. Ela é baixada e ligada à
              playlist, sem mexer nas outras faixas.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2 py-4">
            <label htmlFor="replace_url" className="text-xs font-medium text-muted-foreground">
              URL do YouTube
            </label>
            <Input
              id="replace_url"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder="https://www.youtube.com/watch?v=..."
              autoComplete="off"
              required
            />
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={onClose}>
              Cancelar
            </Button>
            <Button type="submit" disabled={mutation.isPending || !url.trim()}>
              {mutation.isPending ? "Enfileirando..." : "Trocar faixa"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}

/** Relatório por-música: separa "indisponível" (neutro) de "falha" real (vermelho). */
function ImportReport({ playlist }: { playlist: Playlist }) {
  const qc = useQueryClient();
  const { summary, skipped } = importReport(playlist);
  const [replaceTarget, setReplaceTarget] = useState<SkippedTrack | null>(null);
  const [dismissedIds, setDismissedIds] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    setDismissedIds(new Set());
  }, [playlist.id]);

  const dismiss = useMutation({
    mutationFn: (youtubeId: string) => dismissSkippedTrack(playlist.id, youtubeId),
    onMutate: (youtubeId) => {
      setDismissedIds((current) => new Set(current).add(youtubeId));
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["playlists"] });
      qc.invalidateQueries({ queryKey: ["playlist-stats"] });
      toast.success("Faixa dispensada");
    },
    onError: (err: unknown, youtubeId) => {
      setDismissedIds((current) => {
        const next = new Set(current);
        next.delete(youtubeId);
        return next;
      });
      toast.error("Não foi possível dispensar", { description: errorMessage(err) });
    },
  });
  const visibleSkipped = skipped.filter((t) => !t.youtube_id || !dismissedIds.has(t.youtube_id));
  if (!visibleSkipped.length) return null;
  const unavailable = visibleSkipped.filter((t) => isUnavailableCode(t.code));
  const errors = visibleSkipped.filter((t) => !isUnavailableCode(t.code));
  const hasErrors = errors.length > 0;
  return (
    <div
      className={`mt-2 rounded-md border p-2.5 text-xs ${
        hasErrors ? "border-destructive/20 bg-destructive/5" : "border-warning/25 bg-warning/10"
      }`}
    >
      <p className={`mb-1.5 font-semibold ${hasErrors ? "text-destructive" : "text-warning-foreground"}`}>
        Relatório de importação
        {summary ? ` — ${summary.completed ?? 0} de ${summary.total ?? "?"} importadas` : ""}
        {summary?.excluded_by_limit ? ` · ${summary.excluded_by_limit} fora do limite de 170` : ""}
        {unavailable.length ? ` · ${unavailable.length} indisponível(is)` : ""}
        {errors.length ? ` · ${errors.length} com falha` : ""}
      </p>
      <ul className="space-y-1">
        {visibleSkipped.map((t, i) => {
          const permanent = isUnavailableCode(t.code);
          return (
            <li key={t.youtube_id ?? i} className="flex items-start gap-1.5">
              <AlertTriangle
                className={`mt-0.5 h-3 w-3 shrink-0 ${permanent ? "text-warning-foreground" : "text-destructive"}`}
              />
              <span className="min-w-0 flex-1">
                <span className="font-medium text-foreground">{t.title || t.youtube_id || "faixa"}</span>
                {fmtDur(t.duration_seconds) && (
                  <span className="text-muted-foreground"> · {fmtDur(t.duration_seconds)}</span>
                )}
                <span className={permanent ? "text-muted-foreground" : "text-destructive"}>
                  {" "}
                  — {friendlyImportMessage(t.code, t.reason) || "Motivo não informado."}
                </span>
              </span>
              {permanent && (
                <span className="ml-1 flex shrink-0 items-start gap-1">
                  <button
                    type="button"
                    onClick={(event) => {
                      event.stopPropagation();
                      setReplaceTarget(t);
                    }}
                    className="rounded border border-border px-1.5 py-0.5 text-[11px] font-medium text-primary hover:bg-muted"
                  >
                    Trocar
                  </button>
                  <button
                    type="button"
                    disabled={dismiss.isPending || !t.youtube_id}
                    onClick={(event) => {
                      event.stopPropagation();
                      if (t.youtube_id) dismiss.mutate(t.youtube_id);
                    }}
                    className="rounded border border-border px-1.5 py-0.5 text-[11px] font-medium text-muted-foreground hover:bg-muted disabled:opacity-50"
                    title="Dispensar: tira a faixa do relatório"
                  >
                    OK
                  </button>
                </span>
              )}
            </li>
          );
        })}
      </ul>
      <ReplaceTrackDialog
        playlistId={playlist.id}
        target={replaceTarget}
        onClose={() => setReplaceTarget(null)}
      />
    </div>
  );
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
  const [activeArea, setActiveArea] = useState<"requests" | "library" | "storage">("requests");
  const [search, setSearch] = useState("");
  const [librarySearch, setLibrarySearch] = useState("");
  const [requestsPage, setRequestsPage] = useState(1);
  const [libraryPage, setLibraryPage] = useState(1);
  const [requestsPageSize, setRequestsPageSize] = useState(25);
  const [libraryPageSize, setLibraryPageSize] = useState(25);
  const [statusFilter, setStatusFilter] = useState("all");
  const [typeFilter, setTypeFilter] = useState("all");
  const [platformFilter, setPlatformFilter] = useState("all");
  const [dateFilter, setDateFilter] = useState<PeriodPreset>("7d");
  const [customFrom, setCustomFrom] = useState(todayInput());
  const [customTo, setCustomTo] = useState(todayInput());
  const [operatorRequestFilter, setOperatorRequestFilter] = useState<string | null>(null);
  const debouncedSearch = useDebounce(search, 350);
  const debouncedLibrarySearch = useDebounce(librarySearch, 350);
  const requestPeriodRange = useMemo(
    () => {
      const range = buildPeriodRange(dateFilter, customFrom, customTo);
      // Presets ficam abertos até o momento de cada consulta. Fixar o fim no
      // mount fazia solicitações novas só aparecerem depois de recarregar/login.
      return dateFilter === "custom" ? range : { ...range, endAt: null };
    },
    [dateFilter, customFrom, customTo],
  );

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
  const [reimportRequestTarget, setReimportRequestTarget] = useState<OperatorRequestHistory | null>(null);
  const [confirmState, setConfirmState] = useState<{ id: string; action: "approve" | "reject" } | null>(
    null,
  );
  const [reason, setReason] = useState("");
  const [notes, setNotes] = useState<Record<string, string>>(() => loadNotes());
  const [noteDraft, setNoteDraft] = useState("");
  const [storageCleanupOpen, setStorageCleanupOpen] = useState(false);

  useEffect(() => {
    setRequestsPage(1);
  }, [debouncedSearch, statusFilter, typeFilter, platformFilter, dateFilter, customFrom, customTo, operatorRequestFilter]);

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
      requestPeriodRange.startAt,
      requestPeriodRange.endAt,
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
        startAt: requestPeriodRange.startAt,
        endAt: requestPeriodRange.endAt,
    }),
    staleTime: 30_000,
    placeholderData: keepPreviousData,
    enabled: activeArea === "requests",
    refetchOnWindowFocus: true,
    refetchOnReconnect: true,
    refetchInterval: (query) => {
      const rows = query.state.data?.rows;
      const active = rows?.some(
        (p) =>
          p.import_status === "processing" ||
          p.download?.status === "queued" ||
          p.download?.status === "running",
      );
      return active ? 5000 : 15000;
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
    placeholderData: keepPreviousData,
    enabled: activeArea === "library",
    refetchInterval: (query) => {
      const rows = query.state.data?.rows;
      const active = rows?.some((operator) =>
        operator.playlists.some((p) => p.import_status === "processing"),
      );
      return active ? 5000 : false;
    },
  });
  const storageOverviewQuery = useQuery({
    queryKey: ["music-storage-overview"],
    queryFn: getMusicStorageOverview,
    staleTime: 30_000,
    enabled: activeArea === "storage",
    refetchInterval: (query) => Number(query.state.data?.queued_deletions ?? 0) > 0 ? 5000 : false,
  });
  const orphanedTracksQuery = useQuery({
    queryKey: ["orphaned-music-tracks"],
    queryFn: listOrphanedMusicTracks,
    staleTime: 30_000,
    enabled: activeArea === "storage",
  });
  const storageDeletionJobsQuery = useQuery({
    queryKey: ["music-storage-deletion-jobs"],
    queryFn: listMusicStorageDeletionJobs,
    staleTime: 10_000,
    enabled: activeArea === "storage",
    refetchInterval: (query) => (query.state.data?.length ?? 0) > 0 ? 5000 : false,
  });

  const toggle = (cur: string, val: string, set: (v: string) => void) =>
    set(cur === val ? "all" : val);
  const requestHasFilters =
    Boolean(debouncedSearch.trim()) ||
    statusFilter !== "all" ||
    typeFilter !== "all" ||
    platformFilter !== "all" ||
    dateFilter !== "7d" ||
    Boolean(operatorRequestFilter);
  const clearRequestFilters = () => {
    setSearch("");
    setStatusFilter("all");
    setTypeFilter("all");
    setPlatformFilter("all");
    setDateFilter("7d");
    setOperatorRequestFilter(null);
  };

  const invalidateMusic = () => {
    qc.invalidateQueries({ queryKey: ["playlists"] });
    qc.invalidateQueries({ queryKey: ["playlist-stats"] });
    qc.invalidateQueries({ queryKey: ["music-library"] });
    qc.invalidateQueries({ queryKey: ["music-storage-overview"] });
    qc.invalidateQueries({ queryKey: ["orphaned-music-tracks"] });
    qc.invalidateQueries({ queryKey: ["music-storage-deletion-jobs"] });
  };

  const storageCleanupMutation = useMutation({
    mutationFn: queueOrphanedMusicDeletions,
    onSuccess: (queued) => {
      invalidateMusic();
      setStorageCleanupOpen(false);
      toast.success(queued ? `${queued} faixa(s) enviada(s) para limpeza` : "Nenhuma faixa sem playlist para limpar");
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível agendar a limpeza", { description: errorMessage(err) });
    },
  });

  const storageRetryMutation = useMutation({
    mutationFn: retryMusicStorageDeletionJobs,
    onSuccess: (requeued) => {
      invalidateMusic();
      toast.success(requeued ? `${requeued} exclusão(ões) reenfileirada(s)` : "Nenhuma exclusão com erro para reenfileirar");
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível reenfileirar as exclusões", { description: errorMessage(err) });
    },
  });

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

  const reimportRequestMutation = useMutation({
    mutationFn: (id: string) => reimportPlaylistRequest(id),
    onSuccess: () => {
      invalidateMusic();
      setReimportRequestTarget(null);
      toast.success("Envio reenfileirado para importação");
    },
    onError: (err: unknown) => {
      const msg = err instanceof Error ? err.message : "Erro ao reimportar envio";
      toast.error("Não foi possível reimportar este envio", { description: msg });
      invalidateMusic();
    },
  });

  const acknowledgeImportErrorMutation = useMutation({
    mutationFn: (id: string) => acknowledgePlaylistImportError(id),
    onSuccess: () => {
      invalidateMusic();
      toast.success("Erro de importação confirmado");
    },
    onError: (err: unknown) => {
      toast.error("Não foi possível confirmar o erro", { description: errorMessage(err) });
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
  const activeRefreshing = activeArea === "requests"
    ? isFetching
    : activeArea === "library"
      ? libraryQuery.isFetching
      : storageOverviewQuery.isFetching || orphanedTracksQuery.isFetching || storageDeletionJobsQuery.isFetching;
  const refreshActiveArea = () => {
    if (activeArea === "requests") {
      void refetch();
      return;
    }
    if (activeArea === "library") {
      void libraryQuery.refetch();
      return;
    }
    void storageOverviewQuery.refetch();
    void orphanedTracksQuery.refetch();
    void storageDeletionJobsQuery.refetch();
  };

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
            onClick={refreshActiveArea}
            disabled={activeRefreshing}
          >
            <RefreshCw className={cn("h-4 w-4", activeRefreshing && "animate-spin")} />
            Atualizar
          </Button>
        }
      />

      <div className="mb-5 inline-flex flex-wrap items-center gap-1 rounded-xl border border-border bg-card p-1 shadow-sm">
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
        <AreaButton
          active={activeArea === "storage"}
          icon={<HardDrive className="h-4 w-4" />}
          onClick={() => setActiveArea("storage")}
        >
          Armazenamento
        </AreaButton>
      </div>

      {/* Cards de resumo — 4 principais (clique filtra a lista) */}
      {activeArea === "requests" && (
        <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
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
      <div className="sticky top-3 z-20 mb-4 space-y-3 rounded-xl border border-border/80 bg-card/95 p-3 shadow-sm backdrop-blur-sm">
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

          <FilterChip active={platformFilter === "youtube"} onClick={() => toggle(platformFilter, "youtube", setPlatformFilter)} icon={<Music />}>
            YouTube
          </FilterChip>
          <FilterChip active={platformFilter === "spotify"} onClick={() => toggle(platformFilter, "spotify", setPlatformFilter)} icon={<SpotifyIcon />}>
            Spotify
          </FilterChip>

          <span className="mx-1.5 h-5 w-px bg-border" />

          <PeriodFilter
            value={dateFilter}
            customFrom={customFrom}
            customTo={customTo}
            onValueChange={setDateFilter}
            onCustomFromChange={setCustomFrom}
            onCustomToChange={setCustomTo}
            className="min-w-48"
          />
        </div>
      </div>

      {/* Lista */}
      {isError ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar as solicitações."
            description={(error as Error)?.message}
            action={<RetryButton onClick={() => refetch()} disabled={isFetching} />}
          />
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
        <PlaylistList
          items={filtered}
          busy={mutation.isPending || retryMutation.isPending}
          onOpen={openDetail}
          onApprove={askApprove}
          onReject={askReject}
          onRetry={(id) => retryMutation.mutate({ id })}
          onAcknowledgeError={(id) => acknowledgeImportErrorMutation.mutate(id)}
        />
      )}

      {!isError && (
        <PaginationFooter
          page={requestsPage}
          pageSize={requestsPageSize}
          total={playlistsTotal}
          isLoading={isLoading || isFetching}
          onPageChange={setRequestsPage}
          onPageSizeChange={(value) => {
            setRequestsPageSize(value);
            setRequestsPage(1);
          }}
        />
      )}

        </>
      ) : activeArea === "library" ? (
        <>
        <div className="mb-5 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
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
            retryMutation.isPending ||
            reimportRequestMutation.isPending
          }
          onSearchChange={setLibrarySearch}
          onPageChange={setLibraryPage}
          onPageSizeChange={(value) => {
            setLibraryPageSize(value);
            setLibraryPage(1);
          }}
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
      ) : (
        <MusicStorageSection
          overview={storageOverviewQuery.data ?? null}
          tracks={orphanedTracksQuery.data ?? []}
          deletionJobs={storageDeletionJobsQuery.data ?? []}
          loading={storageOverviewQuery.isLoading || orphanedTracksQuery.isLoading || storageDeletionJobsQuery.isLoading}
          error={(storageOverviewQuery.error ?? orphanedTracksQuery.error ?? storageDeletionJobsQuery.error) as Error | null}
          refreshing={storageOverviewQuery.isFetching || orphanedTracksQuery.isFetching || storageDeletionJobsQuery.isFetching}
          retrying={storageRetryMutation.isPending}
          onRefresh={refreshActiveArea}
          onCleanup={() => setStorageCleanupOpen(true)}
          onRetryFailed={() => storageRetryMutation.mutate()}
        />
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
              onAcknowledgeError={() => acknowledgeImportErrorMutation.mutate(detail.id)}
            />
          )}
        </SheetContent>
      </Sheet>

      {/* Modal de confirmação (aprovar / rejeitar) */}
      <Sheet open={Boolean(selectedOperatorId)} onOpenChange={(o) => !o && setSelectedOperatorId(null)}>
        <SheetContent className="w-[calc(100vw-1rem)] overflow-x-hidden overflow-y-auto p-4 sm:max-w-6xl sm:p-6">
          {selectedOperator && (
            <OperatorLibraryPanel
              operator={selectedOperator}
              selectedPlaylistId={selectedPlaylistId}
              busy={
                renameMutation.isPending ||
                removeTrackMutation.isPending ||
                archiveMutation.isPending ||
                retryMutation.isPending ||
                reimportRequestMutation.isPending
              }
              onSelectPlaylist={setSelectedPlaylistId}
              onRename={(playlist) => {
                setRenameTarget(playlist);
                setRenameName(playlist.name);
              }}
              onRetry={(playlist) => retryMutation.mutate({ id: playlist.id })}
              onReimportRequest={setReimportRequestTarget}
              onArchive={setArchiveTarget}
              onRemoveTrack={(playlist, track) => setRemoveTrackTarget({ playlist, track })}
            />
          )}
        </SheetContent>
      </Sheet>

      <Dialog open={Boolean(reimportRequestTarget)} onOpenChange={(open) => !open && setReimportRequestTarget(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Reupar este envio?</DialogTitle>
            <DialogDescription>
              A Playlist principal ativa será importada novamente a partir deste link histórico. Os demais envios e suas músicas preservadas continuarão salvos.
            </DialogDescription>
          </DialogHeader>
          {reimportRequestTarget?.source_url && (
            <p className="break-all rounded-md bg-muted p-3 text-xs text-muted-foreground">
              {reimportRequestTarget.source_url}
            </p>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setReimportRequestTarget(null)} disabled={reimportRequestMutation.isPending}>
              Cancelar
            </Button>
            <Button
              onClick={() => reimportRequestTarget && reimportRequestMutation.mutate(reimportRequestTarget.id)}
              disabled={!reimportRequestTarget || reimportRequestMutation.isPending}
            >
              {reimportRequestMutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />}
              Confirmar reupload
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

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

      <Dialog open={storageCleanupOpen} onOpenChange={setStorageCleanupOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Limpar faixas sem playlist</DialogTitle>
            <DialogDescription>
              As faixas listadas serão desativadas e enviadas para a fila protegida de exclusão no R2. Cada exclusão é verificada novamente pelo Worker antes de remover o arquivo.
            </DialogDescription>
          </DialogHeader>
          <div className="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning-foreground">
            Essa ação não remove músicas vinculadas a playlists. A execução depende do Worker de importação estar ativo.
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setStorageCleanupOpen(false)}>
              Cancelar
            </Button>
            <Button
              variant="destructive"
              disabled={storageCleanupMutation.isPending}
              onClick={() => storageCleanupMutation.mutate()}
            >
              {storageCleanupMutation.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <Trash2 className="h-4 w-4" />}
              Enviar para limpeza
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
              <div className="min-w-0 max-w-full rounded-lg border border-border bg-muted/40 p-3 text-sm">
                <p className="mb-1 truncate font-medium">{confirmPlaylist ? playlistTypeLabel(confirmPlaylist.type) : ""} · {unitText(confirmPlaylist ?? ({} as Playlist))}</p>
                <p className="min-w-0 truncate text-muted-foreground" title={confirmPlaylist?.source_url ?? undefined}>{confirmPlaylist?.source_url ?? "sem link"}</p>
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

function formatBytes(value: number) {
  if (value < 1024) return `${value} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let size = value / 1024;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toLocaleString("pt-BR", { maximumFractionDigits: 1 })} ${units[index]}`;
}

function MusicStorageSection({
  overview,
  tracks,
  deletionJobs,
  loading,
  error,
  refreshing,
  retrying,
  onRefresh,
  onCleanup,
  onRetryFailed,
}: {
  overview: MusicStorageOverview | null;
  tracks: OrphanedMusicTrack[];
  deletionJobs: MusicStorageDeletionJob[];
  loading: boolean;
  error: Error | null;
  refreshing: boolean;
  retrying: boolean;
  onRefresh: () => void;
  onCleanup: () => void;
  onRetryFailed: () => void;
}) {
  const waitingMeasurement = Boolean(overview && overview.measured_tracks < overview.total_tracks);
  const failedJobs = deletionJobs.filter((job) => job.status === "error");

  return (
    <div className="space-y-5">
      <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
        <div>
          <h2 className="font-display text-lg font-semibold">Armazenamento de músicas</h2>
          <p className="text-sm text-muted-foreground">
            Uso do bucket R2 e faixas que não pertencem mais a nenhuma playlist.
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" size="sm" onClick={onRefresh} disabled={refreshing}>
            <RefreshCw className={cn("h-4 w-4", refreshing && "animate-spin")} /> Atualizar
          </Button>
          {failedJobs.length > 0 && (
            <Button variant="outline" size="sm" onClick={onRetryFailed} disabled={retrying}>
              <RefreshCw className={cn("h-4 w-4", retrying && "animate-spin")} /> Reprocessar falhas
            </Button>
          )}
          <Button size="sm" variant="destructive" onClick={onCleanup} disabled={!overview?.orphaned_tracks}>
            <Trash2 className="h-4 w-4" /> Limpar sem playlist
          </Button>
        </div>
      </div>

      {error ? (
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar o armazenamento."
            description={error.message}
            action={<RetryButton onClick={onRefresh} disabled={refreshing} />}
          />
        </Card>
      ) : (
        <>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <StatCard
              icon={<HardDrive className="h-5 w-5" />}
              iconClassName="bg-primary/10 text-primary"
              label="Uso medido no R2"
              value={overview ? formatBytes(overview.used_bytes) : ""}
              hint={waitingMeasurement ? `${overview?.measured_tracks ?? 0} de ${overview?.total_tracks ?? 0} faixas medidas` : "Todos os arquivos medidos"}
              loading={loading}
            />
            <StatCard
              icon={<Music className="h-5 w-5" />}
              iconClassName="bg-success/25 text-success-foreground"
              label="Faixas vinculadas"
              value={overview?.linked_tracks ?? 0}
              hint="Em pelo menos uma playlist"
              loading={loading}
            />
            <StatCard
              icon={<AlertTriangle className="h-5 w-5" />}
              iconClassName="bg-warning/20 text-warning-foreground"
              label="Sem playlist"
              value={overview?.orphaned_tracks ?? 0}
              hint="Disponíveis para limpeza segura"
              loading={loading}
            />
            <StatCard
              icon={<Trash2 className="h-5 w-5" />}
              iconClassName="bg-muted text-muted-foreground"
              label="Na fila de limpeza"
              value={overview?.queued_deletions ?? 0}
              hint={failedJobs.length ? `${failedJobs.length} com erro — veja abaixo` : "Aguardando o Worker R2"}
              loading={loading}
            />
          </div>

          {deletionJobs.length > 0 && (
            <Card className="overflow-hidden border-border shadow-sm">
              <div className="flex flex-col gap-2 border-b border-border px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div>
                  <h3 className="font-semibold">Fila de limpeza R2</h3>
                  <p className="text-xs text-muted-foreground">Acompanhe tentativas e reenvie falhas sem apagar o histórico das solicitações.</p>
                </div>
                {failedJobs.length > 0 && <span className="text-sm font-medium text-destructive">{failedJobs.length} com erro</span>}
              </div>
              <div className="divide-y divide-border">
                {deletionJobs.map((job) => (
                  <div key={job.id} className="grid gap-2 px-4 py-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <p className="truncate text-sm font-medium">{job.title}</p>
                        <span className={cn(
                          "rounded-full px-2 py-0.5 text-[11px] font-medium",
                          job.status === "error" ? "bg-destructive/10 text-destructive" : "bg-muted text-muted-foreground",
                        )}>
                          {job.status === "error" ? "Falha" : job.status === "running" ? "Processando" : "Na fila"}
                        </span>
                      </div>
                      <p className="truncate text-xs text-muted-foreground">{job.artist ?? "Artista não informado"} · tentativa {job.attempts}</p>
                      {job.last_error && (
                        <p className="mt-1 line-clamp-2 text-xs text-destructive" title={job.last_error}>
                          {job.last_error.includes("playlist_request_tracks")
                            ? "O histórico da solicitação ainda referencia esta faixa. A recuperação preservará o histórico."
                            : job.last_error}
                        </p>
                      )}
                    </div>
                    <span className="text-xs text-muted-foreground">Atualizado {relOrDate(job.updated_at)}</span>
                  </div>
                ))}
              </div>
            </Card>
          )}

          {waitingMeasurement && (
            <div className="rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning-foreground">
              O Worker está medindo os arquivos existentes no R2. O total exibido acima soma apenas os objetos já confirmados.
            </div>
          )}

          <Card className="overflow-hidden shadow-sm">
            <div className="flex items-center justify-between gap-3 border-b border-border px-4 py-3">
              <div>
                <h3 className="font-semibold">Faixas sem playlist</h3>
                <p className="text-xs text-muted-foreground">Amostra de até 50 faixas que podem ser enviadas para a fila de limpeza.</p>
              </div>
              <span className="text-sm text-muted-foreground">{overview?.orphaned_tracks ?? 0} encontradas</span>
            </div>
            {loading ? (
              <div className="space-y-3 p-4">
                {Array.from({ length: 3 }).map((_, index) => <Skeleton key={index} className="h-12 w-full" />)}
              </div>
            ) : tracks.length ? (
              <div className="divide-y divide-border">
                {tracks.map((track) => (
                  <div key={track.id} className="flex flex-col gap-1 px-4 py-3 sm:flex-row sm:items-center sm:justify-between">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-medium">{track.title}</p>
                      <p className="truncate text-xs text-muted-foreground">{track.artist ?? "Artista não informado"} · {track.storage_object_key}</p>
                    </div>
                    <span className="shrink-0 text-sm text-muted-foreground">
                      {track.size_bytes == null ? "Aguardando medição" : formatBytes(track.size_bytes)}
                    </span>
                  </div>
                ))}
              </div>
            ) : (
              <div className="px-6 py-12 text-center">
                <CheckCircle2 className="mx-auto h-8 w-8 text-success-foreground" />
                <p className="mt-3 font-medium">Nenhuma faixa sem playlist</p>
                <p className="mt-1 text-sm text-muted-foreground">O acervo atual está todo alocado em playlists.</p>
              </div>
            )}
          </Card>
        </>
      )}
    </div>
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
  onPageSizeChange,
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
  onPageSizeChange: (pageSize: number) => void;
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
        <Card className="shadow-sm">
          <ErrorState
            title="Não foi possível carregar a biblioteca."
            description={error.message}
            action={<RetryButton onClick={onRefresh} disabled={refreshing} />}
          />
        </Card>
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
          onPageSizeChange={onPageSizeChange}
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
  onReimportRequest,
  onArchive,
  onRemoveTrack,
}: {
  operator: OperatorMusicLibrary;
  selectedPlaylistId: string | null;
  busy: boolean;
  onSelectPlaylist: (id: string) => void;
  onRename: (playlist: MusicLibraryPlaylist) => void;
  onRetry: (playlist: MusicLibraryPlaylist) => void;
  onReimportRequest: (request: OperatorRequestHistory) => void;
  onArchive: (playlist: MusicLibraryPlaylist) => void;
  onRemoveTrack: (playlist: MusicLibraryPlaylist, track: MusicTrack) => void;
}) {
  const totals = operatorTotals(operator);
  const principalRequestHistory = operator.request_history.filter((item) => item.type === "principal");
  const [selectedRequestId, setSelectedRequestId] = useState<string | null>(null);
  const selectedPlaylist =
    operator.playlists.find((playlist) => playlist.id === selectedPlaylistId) ?? operator.playlists[0] ?? null;
  const selectedRequest =
    operator.request_history.find((request) => request.id === selectedRequestId) ?? null;

  useEffect(() => {
    setSelectedRequestId(null);
  }, [operator.id]);

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

      <div className="mt-5 grid min-w-0 gap-4 lg:grid-cols-[260px_minmax(0,1fr)]">
        <div className="min-w-0 space-y-3">
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
                  onClick={() => {
                    setSelectedRequestId(null);
                    onSelectPlaylist(playlist.id);
                  }}
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
              Solicitações da Principal
            </div>
            <RequestHistoryList
              history={principalRequestHistory}
              selectedRequestId={selectedRequestId}
              busy={busy}
              onSelect={setSelectedRequestId}
              onReimport={onReimportRequest}
            />
          </div>
        </div>

        {selectedRequest ? (
          <RequestHistoryDetail
            request={selectedRequest}
            busy={busy}
            onReimport={() => onReimportRequest(selectedRequest)}
          />
        ) : selectedPlaylist ? (
          <PlaylistLibraryDetail
            playlist={selectedPlaylist}
            busy={busy}
            onRename={() => onRename(selectedPlaylist)}
            onRetry={() => onRetry(selectedPlaylist)}
            onArchive={() => onArchive(selectedPlaylist)}
            onRemoveTrack={(track) => onRemoveTrack(selectedPlaylist, track)}
          />
        ) : (
          <Card className="flex min-h-[240px] min-w-0 items-center justify-center p-6 text-sm text-muted-foreground">
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

function RequestHistoryList({
  history,
  selectedRequestId,
  busy,
  onSelect,
  onReimport,
}: {
  history: OperatorRequestHistory[];
  selectedRequestId: string | null;
  busy: boolean;
  onSelect: (id: string) => void;
  onReimport: (request: OperatorRequestHistory) => void;
}) {
  if (history.length === 0) {
    return <Card className="p-3 text-xs text-muted-foreground">Nenhuma solicitação da Principal.</Card>;
  }
  return (
    <div className="max-h-64 space-y-2 overflow-y-auto pr-1">
      {history.map((item) => (
        <div
          key={item.id}
          className={cn(
            "rounded-lg border p-2.5 text-xs transition-colors",
            selectedRequestId === item.id ? "border-primary bg-primary/5" : "border-border bg-muted/20",
          )}
        >
          <button type="button" className="w-full text-left" onClick={() => onSelect(item.id)}>
            <div className="flex items-center justify-between gap-2">
              <span className="truncate font-medium">{item.name}</span>
              <StatusPill status={item.approval_status} />
            </div>
            <p className="mt-1 text-muted-foreground">
              {item.track_count} músicas · {relOrDate(item.submitted_at)}
            </p>
            {(item.rejection_reason || item.error_message) && (
              <p className="mt-1 line-clamp-2 text-destructive">
                {item.rejection_reason || item.error_message}
              </p>
            )}
          </button>
          <div className="mt-2 flex items-center justify-between gap-2 border-t border-border/70 pt-2">
            <button
              type="button"
              className="min-w-0 truncate text-left text-primary hover:underline"
              onClick={() => onSelect(item.id)}
            >
              Ver músicas deste envio
            </button>
            {item.approval_status === "approved" && (
              <Button
                type="button"
                size="sm"
                variant="ghost"
                className="h-7 shrink-0 px-2 text-xs"
                disabled={busy}
                onClick={() => onReimport(item)}
              >
                <RefreshCw className="h-3.5 w-3.5" />
                Reupar
              </Button>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

function RequestHistoryDetail({
  request,
  busy,
  onReimport,
}: {
  request: OperatorRequestHistory;
  busy: boolean;
  onReimport: () => void;
}) {
  return (
    <Card className="min-w-0 overflow-hidden p-4 shadow-sm">
      <div className="flex flex-col gap-3 border-b border-border pb-4 md:flex-row md:items-start md:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="font-display text-lg font-semibold">Envio da Playlist principal</h3>
            <StatusPill status={request.approval_status} />
          </div>
          <p className="mt-1 text-xs text-muted-foreground">
            Enviado {relOrDate(request.submitted_at)} · {request.track_count} músicas preservadas
          </p>
          {request.source_url && (
            <p className="mt-2 break-all text-sm text-muted-foreground">{request.source_url}</p>
          )}
        </div>
        <div className="flex flex-wrap gap-2">
          {request.source_url && (
            <>
              <IconAction title="Abrir link do envio" onClick={() => window.open(request.source_url!, "_blank", "noopener,noreferrer")}>
                <ExternalLink className="h-4 w-4" />
              </IconAction>
              <IconAction title="Copiar link do envio" onClick={() => copy(request.source_url!)}>
                <Copy className="h-4 w-4" />
              </IconAction>
            </>
          )}
          {request.approval_status === "approved" && (
            <Button size="sm" variant="outline" onClick={onReimport} disabled={busy}>
              <RefreshCw className="h-4 w-4" />
              Reupar este envio
            </Button>
          )}
        </div>
      </div>

      {(request.rejection_reason || request.error_message) && (
        <div className="mt-3 rounded-md bg-destructive/10 px-3 py-2 text-xs text-destructive ring-1 ring-destructive/20">
          {request.rejection_reason || request.error_message}
        </div>
      )}

      <div className="mt-4">
        <div className="mb-2 flex items-center gap-2 text-sm font-semibold">
          <ListOrdered className="h-4 w-4" />
          Músicas preservadas neste envio
        </div>
        {request.tracks.length === 0 ? (
          <Card className="p-6 text-center text-sm text-muted-foreground">
            Nenhuma música foi preservada para este envio.
          </Card>
        ) : (
          <div className="overflow-hidden rounded-lg border border-border">
            <div className="max-h-[min(520px,55vh)] overflow-y-auto">
              <table className="w-full table-fixed text-sm">
                <thead className="sticky top-0 bg-muted text-xs text-muted-foreground">
                  <tr>
                    <th className="w-12 px-3 py-2 text-left">#</th>
                    <th className="px-3 py-2 text-left">Música</th>
                    <th className="hidden w-24 px-3 py-2 text-left sm:table-cell">Duração</th>
                    <th className="w-20 px-3 py-2 text-right">Ações</th>
                  </tr>
                </thead>
                <tbody>
                  {request.tracks.map((track) => (
                    <tr key={track.playlist_track_id} className="border-t border-border">
                      <td className="px-3 py-2 text-muted-foreground">{track.position}</td>
                      <td className="min-w-0 px-3 py-2">
                        <p className="line-clamp-2 break-words font-medium" title={track.title}>{track.title}</p>
                        <p className="truncate text-xs text-muted-foreground" title={track.artist ?? undefined}>
                          {track.artist ?? "artista não informado"}
                        </p>
                      </td>
                      <td className="hidden px-3 py-2 text-muted-foreground sm:table-cell">{durationText(track.duration_ms)}</td>
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
    <Card className="min-w-0 overflow-hidden p-4 shadow-sm">
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
            <div className="max-h-[min(520px,55vh)] overflow-y-auto">
              <table className="w-full table-fixed text-sm">
                <thead className="sticky top-0 bg-muted text-xs text-muted-foreground">
                  <tr>
                    <th className="w-12 px-3 py-2 text-left">#</th>
                    <th className="px-3 py-2 text-left">Música</th>
                    <th className="hidden w-24 px-3 py-2 text-left sm:table-cell">Duração</th>
                    <th className="hidden w-24 px-3 py-2 text-left xl:table-cell">Status</th>
                    <th className="w-28 px-3 py-2 text-right">Ações</th>
                  </tr>
                </thead>
                <tbody>
                  {playlist.tracks.map((track) => (
                    <tr key={track.playlist_track_id} className="border-t border-border">
                      <td className="px-3 py-2 text-muted-foreground">{track.position}</td>
                      <td className="min-w-0 px-3 py-2">
                        <p className="line-clamp-2 break-words font-medium" title={track.title}>{track.title}</p>
                        <p className="truncate text-xs text-muted-foreground" title={track.artist ?? undefined}>
                          {track.artist ?? "artista não informado"}
                          <span className="sm:hidden"> · {durationText(track.duration_ms)}</span>
                        </p>
                      </td>
                      <td className="hidden px-3 py-2 text-muted-foreground sm:table-cell">{durationText(track.duration_ms)}</td>
                      <td className="hidden px-3 py-2 text-muted-foreground xl:table-cell">{trackStatusLabel(track.status)}</td>
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

/* --------------------------- Lista agrupada ------------------------------- */

type PlaylistListItem = { p: Playlist; platform: Platform };

/**
 * Lista otimizada para não "lotar": agrupa por condomínio e recolhe num único
 * bloco as playlists que ainda aguardam o operador enviar o link (sem link),
 * que antes ocupavam um card inteiro cada.
 */
function PlaylistList({
  items,
  busy,
  onOpen,
  onApprove,
  onReject,
  onRetry,
  onAcknowledgeError,
}: {
  items: PlaylistListItem[];
  busy: boolean;
  onOpen: (p: Playlist) => void;
  onApprove: (id: string) => void;
  onReject: (id: string) => void;
  onRetry: (id: string) => void;
  onAcknowledgeError: (id: string) => void;
}) {
  const [showAwaiting, setShowAwaiting] = useState(false);
  const [collapsedUnits, setCollapsedUnits] = useState<Set<string>>(() => new Set());
  // Secundárias não recebem link (o operador monta com músicas da principal),
  // então não entram na fila de "aguardando o operador enviar o link".
  const awaiting = useMemo(
    () => items.filter((x) => !x.p.source_url && x.p.type !== "secondary"),
    [items],
  );
  const groups = useMemo(() => {
    const map = new Map<string, PlaylistListItem[]>();
    for (const it of items) {
      if (!it.p.source_url) continue;
      const key = unitText(it.p) || "Sem condomínio";
      const arr = map.get(key);
      if (arr) arr.push(it);
      else map.set(key, [it]);
    }
    return Array.from(map.entries());
  }, [items]);

  return (
    <div className="space-y-6">
      {groups.map(([unit, list]) => {
        const collapsed = collapsedUnits.has(unit);
        return (
          <section key={unit} className="space-y-3">
            <button
              type="button"
              aria-expanded={!collapsed}
              onClick={() => setCollapsedUnits((current) => {
                const next = new Set(current);
                if (next.has(unit)) next.delete(unit);
                else next.add(unit);
                return next;
              })}
              className="flex w-full items-center gap-2 rounded-md px-1 py-1 text-left text-xs font-semibold uppercase tracking-wide text-muted-foreground transition-colors hover:bg-muted/40"
            >
              <Building2 className="h-3.5 w-3.5 shrink-0" />
              <span className="truncate">{unit}</span>
              <span className="rounded-full bg-muted px-1.5 py-0.5 text-[11px] font-normal normal-case">
                {list.length}
              </span>
              <ChevronDown className={cn("ml-auto h-4 w-4 shrink-0 transition-transform", !collapsed && "rotate-180")} />
            </button>
            {!collapsed && (
              <div className="space-y-3">
                {list.map(({ p, platform }) => (
                  <PlaylistCard
                    key={p.id}
                    p={p}
                    platform={platform}
                    busy={busy}
                    onOpen={() => onOpen(p)}
                    onApprove={() => onApprove(p.id)}
                    onReject={() => onReject(p.id)}
                    onRetry={() => onRetry(p.id)}
                    onAcknowledgeError={() => onAcknowledgeError(p.id)}
                  />
                ))}
              </div>
            )}
          </section>
        );
      })}

      {awaiting.length > 0 && (
        <section className="space-y-2">
          <button
            type="button"
            onClick={() => setShowAwaiting((v) => !v)}
            className="flex w-full items-center gap-2 rounded-lg border border-dashed border-border bg-muted/20 px-3 py-2 text-left text-xs font-medium text-muted-foreground transition-colors hover:bg-muted/40"
          >
            <Music className="h-3.5 w-3.5 shrink-0" />
            {awaiting.length} playlist(s) aguardando o operador enviar o link
            <ChevronDown className={cn("ml-auto h-4 w-4 transition-transform", showAwaiting && "rotate-180")} />
          </button>
          {showAwaiting && (
            <div className="space-y-2">
              {awaiting.map(({ p }) => (
                <CompactAwaitingRow key={p.id} p={p} onOpen={() => onOpen(p)} />
              ))}
            </div>
          )}
        </section>
      )}
    </div>
  );
}

function CompactAwaitingRow({ p, onOpen }: { p: Playlist; onOpen: () => void }) {
  return (
    <button
      type="button"
      onClick={onOpen}
      className="flex w-full items-center gap-3 rounded-lg border border-border bg-background px-3 py-2 text-left text-sm transition-colors hover:border-primary/50"
    >
      <Music className="h-4 w-4 shrink-0 text-muted-foreground" />
      <span className="min-w-0 flex-1 truncate">
        <span className="font-medium">{p.operator_name ?? "—"}</span>
        <span className="text-muted-foreground">
          {" · "}
          {playlistTypeLabel(p.type)}
          {" · "}
          {unitText(p)}
        </span>
      </span>
      <span className="shrink-0 rounded-full bg-muted px-2 py-0.5 text-[11px] text-muted-foreground">
        Aguardando envio
      </span>
    </button>
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
  onAcknowledgeError,
}: {
  p: Playlist;
  platform: Platform;
  busy: boolean;
  onOpen: () => void;
  onApprove: () => void;
  onReject: () => void;
  onRetry: () => void;
  onAcknowledgeError: () => void;
}) {
  const m = platformMeta(platform);
  // Decisão é definitiva: só uma playlist "pendente" pode ser aprovada/rejeitada.
  const canApprove = p.approval_status === "pending";
  const canReject = p.approval_status === "pending";
  const canRetry = p.approval_status === "approved" && p.import_status === "failed";
  const canAcknowledgeError = p.import_status === "failed" && !isImportErrorAcknowledged(p);
  const importError = playlistImportError(p);
  const pauseMessage = playlistImportPauseMessage(p);
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
          {platform !== "invalid" && (
            <>
              <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
                Origem: {platformMeta(platform).label}
              </span>
              {sourceResourceLabel(p.source_url) && (
                <span className="rounded-full bg-muted px-2 py-0.5 text-[11px] font-medium text-muted-foreground">
                  Tipo: {sourceResourceLabel(p.source_url)}
                </span>
              )}
            </>
          )}
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

        {canAcknowledgeError && (
          <div className="mt-2 flex items-start gap-1.5 rounded-md bg-destructive/10 px-2.5 py-1.5 text-xs text-destructive ring-1 ring-destructive/20">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>
              <span className="font-semibold">Falha ao importar: </span>
              {importError || "motivo técnico não informado pelo backend"}
            </span>
          </div>
        )}

        {pauseMessage && (
          <div className="mt-2 flex items-start gap-1.5 rounded-md bg-warning/10 px-2.5 py-1.5 text-xs text-warning-foreground ring-1 ring-warning/20">
            <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" />
            <span>{pauseMessage}</span>
          </div>
        )}

        {/* Relatório: null quando não há faixas puladas; neutro p/ indisponíveis */}
        {!isImportErrorAcknowledged(p) && <ImportReport playlist={p} />}

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
        {canAcknowledgeError && (
          <Button size="sm" variant="outline" disabled={busy} onClick={stop(onAcknowledgeError)}>
            <Check className="h-4 w-4" /> OK
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
  if (p.import_status === "failed" && isImportErrorAcknowledged(p)) {
    return (
      <span className="inline-flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-0.5 text-xs font-medium text-muted-foreground ring-1 ring-border">
        <Check className="h-3.5 w-3.5" /> Erro confirmado
      </span>
    );
  }
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

function SpotifyRequestDetail({ p, onApprove }: { p: Playlist; onApprove: () => void }) {
  const qc = useQueryClient();
  const [reviewOnly, setReviewOnly] = useState(false);
  const [replacement, setReplacement] = useState<PlaylistRequestDetailItem | null>(null);
  const [youtubeUrl, setYoutubeUrl] = useState("");
  const detailQuery = useQuery({
    queryKey: ["playlist-request-detail", p.id],
    queryFn: () => getPlaylistRequestDetail(p.id),
    enabled: detectPlatform(p.source_url) === "spotify",
    staleTime: 10_000,
  });

  const itemMutation = useMutation({
    mutationFn: ({ action, item, url }: { action: "ignore" | "replace_youtube" | "retry"; item: PlaylistRequestDetailItem; url?: string }) =>
      managePlaylistRequestItem(detailQuery.data!.request.id, action, item.id, url),
    onSuccess: (_data, variables) => {
      qc.invalidateQueries({ queryKey: ["playlist-request-detail", p.id] });
      qc.invalidateQueries({ queryKey: ["playlists"] });
      if (variables.action === "replace_youtube") setReplacement(null);
      toast.success(variables.action === "ignore" ? "Faixa ignorada" : "Faixa reenfileirada");
    },
    onError: (error: unknown) => toast.error("Não foi possível atualizar a faixa", { description: errorMessage(error) }),
  });

  if (detectPlatform(p.source_url) !== "spotify") return null;
  if (detailQuery.isLoading) return <Skeleton className="mt-5 h-36 w-full" />;
  if (detailQuery.isError || !detailQuery.data) {
    return <p className="mt-5 text-sm text-muted-foreground">Não foi possível carregar os itens desta solicitação.</p>;
  }

  const detail = detailQuery.data;
  const items = reviewOnly ? detail.items.filter((item) => item.status === "review_recommended") : detail.items;
  const summary = detail.summary;
  const metric = (label: string, value: number) => (
    <div key={label} className="rounded-md border border-border bg-muted/30 px-2 py-1.5 text-center">
      <p className="text-base font-semibold">{value}</p><p className="text-[10px] text-muted-foreground">{label}</p>
    </div>
  );

  return (
    <section className="mt-5 space-y-4 border-t border-border pt-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Solicitação Spotify</p>
          <p className="text-sm font-medium">Origem: Spotify · Tipo: {detail.request.source_resource_type ?? "—"}</p>
        </div>
        {p.approval_status === "pending" && (
          <Button size="sm" onClick={onApprove}>
            <Check className="h-4 w-4" /> Aprovar todas as resolvidas
          </Button>
        )}
      </div>

      <div className="grid grid-cols-2 gap-2 text-sm">
        <InfoRow label="Operador" value={detail.operator.name ?? p.operator_name ?? "—"} />
        <InfoRow label="Condomínio" value={unitLabel(detail.unit)} />
        <InfoRow label="Playlist de destino" value={detail.playlist.name} />
        <InfoRow label="Status geral" value={generalStatusLabel(detail.request.general_status)} />
      </div>
      <div>
        <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground">Link original</p>
        <p className="break-all text-xs text-muted-foreground">{detail.request.original_url ?? "—"}</p>
      </div>
      <div className="grid grid-cols-4 gap-2">
        {metric("Total", summary.total)}
        {metric("Resolvidas", summary.resolved)}
        {metric("Revisar", summary.review_recommended)}
        {metric("Não encontradas", summary.not_found)}
        {metric("Duplicadas", summary.duplicate)}
        {metric("> 16 min", summary.duration_exceeded)}
        {metric("> 170", summary.playlist_limit_exceeded)}
        {metric("Falhas", summary.failed)}
      </div>

      {(detail.request.operator_messages ?? []).length > 0 && (
        <div className="rounded-lg border border-warning/30 bg-warning/10 p-3">
          <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-warning-foreground">
            Atenção
          </p>
          <ul className="space-y-1 text-sm text-warning-foreground">
            {(detail.request.operator_messages ?? []).map((message) => <li key={message}>{message}</li>)}
          </ul>
        </div>
      )}

      {detail.request.technical_error && (
        <details className="rounded-lg border border-border bg-muted/30 p-3 text-xs text-muted-foreground">
          <summary className="cursor-pointer font-semibold uppercase tracking-wide">
            Diagnóstico técnico do Admin
          </summary>
          <pre className="mt-2 max-h-32 overflow-auto whitespace-pre-wrap">
            {JSON.stringify(detail.request.technical_error, null, 2)}
          </pre>
        </details>
      )}

      <div className="flex items-center justify-between gap-2">
        <p className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Faixas ({items.length})</p>
        <Button size="sm" variant={reviewOnly ? "default" : "outline"} onClick={() => setReviewOnly((value) => !value)}>
          <AlertTriangle className="h-4 w-4" /> Revisar sinalizadas
        </Button>
      </div>
      <div className="space-y-2">
        {items.map((item) => {
          const review = item.status === "review_recommended";
          const canRetry = Boolean(item.youtube_url) && !itemMutation.isPending;
          return (
            <div key={item.id} className={cn("rounded-lg border p-3", review ? "border-warning/40 bg-warning/5" : "border-border bg-muted/20")}>
              <div className="flex flex-wrap items-start justify-between gap-2">
                <div className="min-w-0">
                  <p className="font-medium">{item.position}. {item.title ?? "Faixa sem título"}</p>
                  <p className="text-xs text-muted-foreground">{item.artists.join(", ") || "Artista não informado"} · {fmtDuration(item.duration_ms)}</p>
                </div>
                <span className={cn("rounded-full px-2 py-0.5 text-[11px] font-medium", review ? "bg-warning/15 text-warning-foreground" : "bg-muted text-muted-foreground")}>
                  {review ? "Revisão recomendada" : item.status}
                </span>
              </div>
              <div className="mt-2 grid gap-1 text-xs text-muted-foreground">
                <p>Resultado no YouTube: <span className="text-foreground">{item.youtube_title ?? item.youtube_video_id ?? "não encontrado"}</span></p>
                <p>Canal: {item.youtube_channel ?? "não informado"} · Diferença: {item.duration_difference_ms == null ? "—" : `${Math.round(item.duration_difference_ms / 1000)}s`}</p>
                {item.operator_message && <p className="text-warning-foreground">{item.operator_message}</p>}
                {item.review_reason && (
                  <p className="text-muted-foreground">Detalhe da divergência: {item.review_reason}</p>
                )}
              </div>
              <div className="mt-3 flex flex-wrap gap-2">
                {item.youtube_url && <Button size="sm" variant="outline" asChild><a href={item.youtube_url} target="_blank" rel="noreferrer noopener"><ExternalLink className="h-3.5 w-3.5" /> YouTube</a></Button>}
                <Button size="sm" variant="outline" onClick={() => { setReplacement(item); setYoutubeUrl(item.youtube_url ?? ""); }} disabled={itemMutation.isPending}>
                  <Pencil className="h-3.5 w-3.5" /> Substituir resultado
                </Button>
                <Button size="sm" variant="outline" onClick={() => itemMutation.mutate({ action: "retry", item })} disabled={!canRetry}>
                  <RefreshCw className="h-3.5 w-3.5" /> Tentar novamente
                </Button>
                <Button size="sm" variant="ghost" className="text-destructive" onClick={() => itemMutation.mutate({ action: "ignore", item })} disabled={itemMutation.isPending}>
                  <X className="h-3.5 w-3.5" /> Ignorar faixa
                </Button>
              </div>
            </div>
          );
        })}
        {items.length === 0 && <p className="text-sm text-muted-foreground">Nenhuma faixa sinalizada para revisão.</p>}
      </div>

      <Dialog open={Boolean(replacement)} onOpenChange={(open) => !open && setReplacement(null)}>
        <DialogContent>
          <DialogHeader><DialogTitle>Substituir resultado do YouTube</DialogTitle><DialogDescription>Informe um link de vídeo do YouTube. A validação é feita no backend antes de reenfileirar a faixa.</DialogDescription></DialogHeader>
          <Input value={youtubeUrl} onChange={(event) => setYoutubeUrl(event.target.value)} placeholder="https://www.youtube.com/watch?v=..." />
          <DialogFooter>
            <Button variant="outline" onClick={() => setReplacement(null)}>Cancelar</Button>
            <Button disabled={!replacement || !youtubeUrl.trim() || itemMutation.isPending} onClick={() => replacement && itemMutation.mutate({ action: "replace_youtube", item: replacement, url: youtubeUrl })}>
              {itemMutation.isPending && <Loader2 className="h-4 w-4 animate-spin" />} Validar e reenfileirar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}

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
  onAcknowledgeError,
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
  onAcknowledgeError: () => void;
}) {
  const embed = buildEmbed(p.source_url, platform);
  const m = platformMeta(platform);
  // Decisão é definitiva: só uma playlist "pendente" pode ser aprovada/rejeitada.
  const canApprove = p.approval_status === "pending";
  const canReject = p.approval_status === "pending";
  const canRetry = p.approval_status === "approved" && p.import_status === "failed";
  const canAcknowledgeError = p.import_status === "failed" && !isImportErrorAcknowledged(p);
  const importError = playlistImportError(p);
  const technicalError = technicalErrorText(p);
  const pauseMessage = playlistImportPauseMessage(p);

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

      <SpotifyRequestDetail p={p} onApprove={onApprove} />

      {pauseMessage && (
        <div className="mt-5 flex items-start gap-2 rounded-lg border border-warning/30 bg-warning/10 p-3 text-sm text-warning-foreground">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <span>{pauseMessage}</span>
        </div>
      )}

      {(canAcknowledgeError || p.approval_status === "rejected") && (
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
              <Button size="sm" variant="outline" className="mt-3" onClick={onAcknowledgeError} disabled={busy}>
                <Check className="h-4 w-4" /> OK, marcar como resolvido
              </Button>
              {!isImportErrorAcknowledged(p) && <ImportReport playlist={p} />}
              {technicalError && (
                <pre className="mt-2 max-h-28 overflow-auto whitespace-pre-wrap rounded-md bg-background p-2 text-xs text-muted-foreground">
                  {technicalError}
                </pre>
              )}
            </>
          )}
        </div>
      )}

      {p.import_status === "success" && (
        <div className="mt-5">
          <ImportReport playlist={p} />
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
