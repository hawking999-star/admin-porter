import { supabase } from "@/lib/supabase";

export type PaginatedResult<T> = {
  rows: T[];
  total: number;
};

export type PageParams = {
  page: number;
  pageSize: number;
};

/* -------------------------------- Rótulos -------------------------------- */

export const PLAYLIST_STATUSES = [
  { value: "draft", label: "Aguardando link" },
  { value: "pending", label: "Pendente" },
  { value: "approved", label: "Aprovada" },
  { value: "rejected", label: "Rejeitada" },
] as const;

export const PLAYLIST_TYPES = [
  { value: "principal", label: "Principal" },
  { value: "secondary", label: "Secundária" },
] as const;

export type PlaylistApproval = "draft" | "pending" | "approved" | "rejected";
export type PlaylistImportStatus = "not_started" | "processing" | "success" | "failed";
export type PlaylistType = "principal" | "secondary";

export function playlistStatusLabel(v: string) {
  return PLAYLIST_STATUSES.find((s) => s.value === v)?.label ?? v;
}
export function playlistTypeLabel(v: string) {
  return PLAYLIST_TYPES.find((t) => t.value === v)?.label ?? v;
}

/* --------------------------------- Dados --------------------------------- */

export type DownloadStatus = "queued" | "running" | "done" | "partial" | "error";

export type DownloadJob = {
  status: DownloadStatus;
  total: number;
  completed: number;
  failed: number;
  error: string | null;
  error_code: string | null;
  error_message: string | null;
  error_details: Record<string, unknown> | null;
  last_error_at: string | null;
  started_at: string | null;
  finished_at: string | null;
};

export type Playlist = {
  id: string;
  name: string;
  type: PlaylistType;
  approval_status: PlaylistApproval;
  import_status: PlaylistImportStatus;
  source_url: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  reviewed_by_name: string | null;
  rejection_reason: string | null;
  error_message: string | null;
  error_code: string | null;
  error_details: Record<string, unknown> | null;
  last_error_at: string | null;
  import_error_acknowledged_at: string | null;
  import_started_at: string | null;
  import_finished_at: string | null;
  operator_name: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  download: DownloadJob | null;
};

export type PlaylistFilters = PageParams & {
  search?: string;
  operatorId?: string | null;
  status?: "all" | string;
  type?: "all" | string;
  platform?: "all" | string;
  startAt?: string;
  endAt?: string;
};

export type PlaylistStats = {
  pending: number;
  approved: number;
  rejected: number;
  importFailed: number;
  today: number;
  week: number;
};

function pageRange(page: number, pageSize: number) {
  const from = Math.max(0, page - 1) * pageSize;
  return { from, to: from + pageSize - 1 };
}

function importStatusFromDownload(download: DownloadJob | null): PlaylistImportStatus {
  if (!download) return "not_started";
  if (download.status === "queued" || download.status === "running") return "processing";
  if (download.status === "done") return "success";
  if (download.status === "partial" || download.status === "error") return "failed";
  return "not_started";
}

export async function listPlaylists(filters: PlaylistFilters): Promise<PaginatedResult<Playlist>> {
  const { from, to } = pageRange(filters.page, filters.pageSize);
  const term = filters.search?.trim();

  let query = supabase
    .from("playlists")
    .select(
      "id, name, type, approval_status, import_status, source_url, submitted_at, reviewed_at, reviewed_by_admin_id, rejection_reason, error_message, error_code, error_details, last_error_at, import_error_acknowledged_at, import_started_at, import_finished_at, created_at, operators(display_name), units(name, city, state), reviewed_by:admin_users!playlists_reviewed_by_admin_id_fkey(display_name), download_jobs(status, total, completed, failed, error, error_code, error_message, error_details, last_error_at, started_at, finished_at, created_at)",
      { count: "exact" },
    )
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false });

  if (filters.status === "import_failed") query = query.eq("import_status", "failed").is("import_error_acknowledged_at", null);
  if (filters.operatorId) query = query.eq("created_by_operator_id", filters.operatorId);
  if (filters.status && filters.status !== "all" && filters.status !== "import_failed") {
    query = query.eq("approval_status", filters.status);
  }
  if (filters.type && filters.type !== "all") query = query.eq("type", filters.type);
  if (filters.platform === "spotify") query = query.ilike("source_url", "%spotify%");
  if (filters.platform === "youtube") query = query.or("source_url.ilike.%youtube%,source_url.ilike.%youtu.be%");
  if (filters.startAt) query = query.gte("submitted_at", filters.startAt);
  if (filters.endAt) query = query.lte("submitted_at", filters.endAt);
  if (term) {
    const clean = term.replace(/[%,()]/g, "");
    if (clean) {
      const pattern = `%${clean}%`;
      query = query.or(
        `source_url.ilike.${pattern},approval_status.ilike.${pattern},import_status.ilike.${pattern},rejection_reason.ilike.${pattern},error_message.ilike.${pattern},error_code.ilike.${pattern}`,
      );
    }
  }

  const { data, error, count } = await query.range(from, to);
  if (error) throw error;

  const rows = (data ?? []).map((p: any) => {
    // pega o job de download mais recente da playlist (se houver)
    const jobs = Array.isArray(p.download_jobs) ? p.download_jobs : [];
    const latest = jobs
      .slice()
      .sort((a: any, b: any) => (a.created_at < b.created_at ? 1 : -1))[0];
    return {
      id: p.id,
      name: p.name,
      type: p.type,
      approval_status: p.approval_status,
      source_url: p.source_url ?? null,
      submitted_at: p.submitted_at ?? null,
      reviewed_at: p.reviewed_at ?? null,
      reviewed_by_name: p.reviewed_by?.display_name ?? null,
      rejection_reason: p.rejection_reason ?? null,
      error_message: p.error_message ?? null,
      error_code: p.error_code ?? null,
      error_details: p.error_details ?? null,
      last_error_at: p.last_error_at ?? null,
      import_error_acknowledged_at: p.import_error_acknowledged_at ?? null,
      import_started_at: p.import_started_at ?? null,
      import_finished_at: p.import_finished_at ?? null,
      operator_name: p.operators?.display_name ?? null,
      unit_name: p.units?.name ?? null,
      unit_city: p.units?.city ?? null,
      unit_state: p.units?.state ?? null,
      download: latest
        ? {
            status: latest.status,
            total: latest.total ?? 0,
            completed: latest.completed ?? 0,
            failed: latest.failed ?? 0,
            error: latest.error ?? null,
            error_code: latest.error_code ?? null,
            error_message: latest.error_message ?? null,
            error_details: latest.error_details ?? null,
            last_error_at: latest.last_error_at ?? null,
            started_at: latest.started_at ?? null,
            finished_at: latest.finished_at ?? null,
          }
        : null,
      import_status: p.import_status ?? importStatusFromDownload(
        latest
          ? {
              status: latest.status,
              total: latest.total ?? 0,
              completed: latest.completed ?? 0,
              failed: latest.failed ?? 0,
              error: latest.error ?? null,
              error_code: latest.error_code ?? null,
              error_message: latest.error_message ?? null,
              error_details: latest.error_details ?? null,
              last_error_at: latest.last_error_at ?? null,
              started_at: latest.started_at ?? null,
              finished_at: latest.finished_at ?? null,
            }
          : null,
      ),
    };
  });

  return { rows, total: count ?? 0 };
}

export async function countPlaylistStats(): Promise<PlaylistStats> {
  const startToday = new Date();
  startToday.setHours(0, 0, 0, 0);
  const startWeek = new Date();
  startWeek.setDate(startWeek.getDate() - 7);

  const [pending, approved, rejected, importFailed, today, week] = await Promise.all([
    supabase.from("playlists").select("id", { count: "exact", head: true }).eq("approval_status", "pending"),
    supabase.from("playlists").select("id", { count: "exact", head: true }).eq("approval_status", "approved"),
    supabase.from("playlists").select("id", { count: "exact", head: true }).eq("approval_status", "rejected"),
    supabase.from("playlists").select("id", { count: "exact", head: true }).eq("import_status", "failed").is("import_error_acknowledged_at", null),
    supabase.from("playlists").select("id", { count: "exact", head: true }).gte("submitted_at", startToday.toISOString()),
    supabase.from("playlists").select("id", { count: "exact", head: true }).gte("submitted_at", startWeek.toISOString()),
  ]);

  const error = pending.error ?? approved.error ?? rejected.error ?? importFailed.error ?? today.error ?? week.error;
  if (error) throw error;

  return {
    pending: pending.count ?? 0,
    approved: approved.count ?? 0,
    rejected: rejected.count ?? 0,
    importFailed: importFailed.count ?? 0,
    today: today.count ?? 0,
    week: week.count ?? 0,
  };
}

export async function reviewPlaylist(
  id: string,
  action: "approve" | "reject",
  reason?: string,
): Promise<void> {
  const { error } = await supabase.rpc("admin_review_playlist", {
    p_playlist: id,
    p_action: action,
    p_reason: action === "reject" ? reason ?? null : null,
  });
  if (error) throw error;
}

export async function retryPlaylistImport(id: string): Promise<void> {
  const { error } = await supabase.rpc("admin_retry_playlist_import", {
    p_playlist: id,
  });
  if (error) throw error;
}

/** Enfileira a reimportação de UMA faixa (troca manual por outra URL do YouTube). */
export async function enqueueTrackReplacement(
  playlistId: string,
  sourceUrl: string,
  replaceYoutubeId?: string | null,
): Promise<string | null> {
  const { data, error } = await supabase.rpc("admin_enqueue_track_replacement", {
    p_playlist_id: playlistId,
    p_source_url: sourceUrl,
    p_replace_youtube_id: replaceYoutubeId ?? null,
  });
  if (error) throw error;
  return (data as string | null) ?? null;
}

/** Dispensa uma faixa indisponível: tira ela do relatório de importação. */
export async function dismissSkippedTrack(playlistId: string, youtubeId: string): Promise<void> {
  const { error } = await supabase.rpc("admin_dismiss_skipped_track", {
    p_playlist_id: playlistId,
    p_youtube_id: youtubeId,
  });
  if (error) throw error;
}

export async function acknowledgePlaylistImportError(playlistId: string): Promise<void> {
  const { error } = await supabase.rpc("admin_acknowledge_playlist_import_error", {
    p_playlist_id: playlistId,
  });
  if (error) throw error;
}

export type MusicStorageOverview = {
  total_tracks: number;
  linked_tracks: number;
  orphaned_tracks: number;
  queued_deletions: number;
  measured_tracks: number;
  used_bytes: number;
  last_measured_at: string | null;
};

export type OrphanedMusicTrack = {
  id: string;
  title: string;
  artist: string | null;
  storage_object_key: string;
  size_bytes: number | null;
  created_at: string;
};

export async function getMusicStorageOverview(): Promise<MusicStorageOverview> {
  const { data, error } = await supabase.rpc("admin_music_storage_overview");
  if (error) throw error;
  const row = (data ?? {}) as Partial<MusicStorageOverview>;
  return {
    total_tracks: Number(row.total_tracks ?? 0),
    linked_tracks: Number(row.linked_tracks ?? 0),
    orphaned_tracks: Number(row.orphaned_tracks ?? 0),
    queued_deletions: Number(row.queued_deletions ?? 0),
    measured_tracks: Number(row.measured_tracks ?? 0),
    used_bytes: Number(row.used_bytes ?? 0),
    last_measured_at: row.last_measured_at ?? null,
  };
}

export async function listOrphanedMusicTracks(): Promise<OrphanedMusicTrack[]> {
  const { data, error } = await supabase.rpc("admin_list_orphaned_music_tracks", { p_limit: 50 });
  if (error) throw error;
  return (data ?? []) as OrphanedMusicTrack[];
}

export async function queueOrphanedMusicDeletions(): Promise<number> {
  const { data, error } = await supabase.rpc("admin_queue_orphaned_music_deletions");
  if (error) throw error;
  const result = (data ?? {}) as { queued?: unknown };
  return Number(result.queued ?? 0);
}

export type MusicTrack = {
  playlist_track_id: string;
  track_id: string;
  position: number;
  title: string;
  artist: string | null;
  duration_ms: number | null;
  source_url: string | null;
  public_url: string | null;
  status: string;
  added_by_type: string | null;
  created_at: string | null;
  updated_at: string | null;
};

export type MusicLibraryPlaylist = {
  id: string;
  name: string;
  type: PlaylistType;
  status: string;
  approval_status: PlaylistApproval;
  import_status: PlaylistImportStatus;
  source_url: string | null;
  platform: string | null;
  revision: number;
  created_at: string;
  updated_at: string;
  submitted_at: string | null;
  reviewed_at: string | null;
  import_started_at: string | null;
  import_finished_at: string | null;
  error_code: string | null;
  error_message: string | null;
  last_error_at: string | null;
  track_count: number;
  latest_job: Record<string, unknown> | null;
  tracks: MusicTrack[];
};

export type OperatorRequestHistory = {
  id: string;
  playlist_id: string;
  name: string;
  type: PlaylistType;
  approval_status: PlaylistApproval;
  import_status: PlaylistImportStatus;
  source_url: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  rejection_reason: string | null;
  error_message: string | null;
  track_count: number;
  latest_job: Record<string, unknown> | null;
  tracks: MusicTrack[];
};

export type OperatorMusicLibrary = {
  id: string;
  display_name: string;
  username: string | null;
  email: string | null;
  active: boolean;
  role: string;
  unit_id: string;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  updated_at: string;
  playlists: MusicLibraryPlaylist[];
  request_history: OperatorRequestHistory[];
};

export type MusicLibraryFilters = PageParams & {
  search?: string;
};

export async function listOperatorMusicLibrary(): Promise<OperatorMusicLibrary[]> {
  const { data, error } = await supabase.rpc("admin_music_library_page", {
    p_limit: 100,
    p_offset: 0,
    p_search: null,
  });
  if (error) throw error;
  const payload = (data ?? {}) as { rows?: unknown };
  return (Array.isArray(payload.rows) ? payload.rows : []) as OperatorMusicLibrary[];
}

export async function listOperatorMusicLibraryPage(
  filters: MusicLibraryFilters,
): Promise<PaginatedResult<OperatorMusicLibrary>> {
  const { data, error } = await supabase.rpc("admin_music_library_page", {
    p_limit: filters.pageSize,
    p_offset: Math.max(0, filters.page - 1) * filters.pageSize,
    p_search: filters.search?.trim() || null,
  });
  if (error) throw error;

  const payload = (data ?? {}) as { rows?: unknown; total?: unknown };
  return {
    rows: (Array.isArray(payload.rows) ? payload.rows : []) as OperatorMusicLibrary[],
    total: typeof payload.total === "number" ? payload.total : 0,
  };
}

export async function renameMusicPlaylist(id: string, name: string): Promise<void> {
  const { error } = await supabase.rpc("admin_rename_music_playlist", {
    p_playlist: id,
    p_name: name,
  });
  if (error) throw error;
}

export async function removePlaylistTrack(playlistTrackId: string): Promise<void> {
  const { error } = await supabase.rpc("admin_remove_playlist_track", {
    p_playlist_track: playlistTrackId,
  });
  if (error) throw error;
}

export async function archiveSecondaryPlaylist(id: string): Promise<void> {
  const { error } = await supabase.rpc("admin_archive_secondary_playlist", {
    p_playlist: id,
  });
  if (error) throw error;
}

export async function reimportPlaylistRequest(id: string): Promise<void> {
  const { error } = await supabase.rpc("admin_reimport_playlist_request", {
    p_request: id,
  });
  if (error) throw error;
}
