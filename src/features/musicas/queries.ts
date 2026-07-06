import { supabase } from "@/lib/supabase";

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
  import_started_at: string | null;
  import_finished_at: string | null;
  operator_name: string | null;
  unit_name: string | null;
  unit_city: string | null;
  unit_state: string | null;
  download: DownloadJob | null;
};

function importStatusFromDownload(download: DownloadJob | null): PlaylistImportStatus {
  if (!download) return "not_started";
  if (download.status === "queued" || download.status === "running") return "processing";
  if (download.status === "done") return "success";
  if (download.status === "partial" || download.status === "error") return "failed";
  return "not_started";
}

export async function listPlaylists(): Promise<Playlist[]> {
  const { data, error } = await supabase
    .from("playlists")
    .select(
      "id, name, type, approval_status, import_status, source_url, submitted_at, reviewed_at, reviewed_by_admin_id, rejection_reason, error_message, error_code, error_details, last_error_at, import_started_at, import_finished_at, created_at, operators(display_name), units(name, city, state), reviewed_by:admin_users!playlists_reviewed_by_admin_id_fkey(display_name), download_jobs(status, total, completed, failed, error, error_code, error_message, error_details, last_error_at, started_at, finished_at, created_at)",
    )
    .order("submitted_at", { ascending: false, nullsFirst: false })
    .order("created_at", { ascending: false });
  if (error) throw error;

  return (data ?? []).map((p: any) => {
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
  name: string;
  type: PlaylistType;
  approval_status: PlaylistApproval;
  import_status: PlaylistImportStatus;
  source_url: string | null;
  submitted_at: string | null;
  reviewed_at: string | null;
  rejection_reason: string | null;
  error_message: string | null;
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

export async function listOperatorMusicLibrary(): Promise<OperatorMusicLibrary[]> {
  const { data, error } = await supabase.rpc("admin_music_library");
  if (error) throw error;
  return (Array.isArray(data) ? data : []) as OperatorMusicLibrary[];
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
